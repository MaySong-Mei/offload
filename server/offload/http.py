from __future__ import annotations

import base64
import hashlib
import json
import os
import pty
import queue
import select
import socket
import struct
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Optional
from urllib.parse import parse_qs, urlparse

from .projects import ProjectScanner
from .repo_offload import InitRunner, RepoOffload
from .service import GateTimeoutError, HarnessService, NotFoundError, ValidationError


class AuthConfig:
    def __init__(self, token: Optional[str] = None):
        self.token = token

    def authorize(self, headers: Dict[str, str]) -> bool:
        if not self.token:
            return True
        value = headers.get("Authorization", "")
        return value == f"Bearer {self.token}"


class HarnessHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True

    def server_bind(self):
        import socket as _socket
        self.socket.setsockopt(_socket.SOL_SOCKET, _socket.SO_REUSEADDR, 1)
        self.socket.bind(self.server_address)
        self.server_address = self.socket.getsockname()

    def __init__(self, server_address, RequestHandlerClass, service: HarnessService, auth: AuthConfig, scanner: Optional[ProjectScanner] = None, init_runner: Optional[InitRunner] = None, tunnel_manager=None):
        super().__init__(server_address, RequestHandlerClass)
        self.service = service
        self.auth = auth
        self.scanner = scanner or ProjectScanner(None)
        self.init_runner = init_runner or InitRunner()
        self.tunnel_manager = tunnel_manager


def create_http_server(host: str, port: int, service: HarnessService, scanner: Optional[ProjectScanner] = None, init_runner: Optional[InitRunner] = None, auth_token: Optional[str] = None, tunnel_manager=None) -> HarnessHTTPServer:
    auth = AuthConfig(auth_token)
    handler = make_handler()
    return HarnessHTTPServer((host, port), handler, service, auth, scanner=scanner, init_runner=init_runner, tunnel_manager=tunnel_manager)


def make_handler():
    class Handler(BaseHTTPRequestHandler):
        server: HarnessHTTPServer
        protocol_version = "HTTP/1.1"  # Enable keep-alive

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path == "/health":
                self._write_json(HTTPStatus.OK, {"status": "ok"})
                return
            if parsed.path == "/ws":
                if not self._authorize():
                    return
                self._handle_websocket()
                return
            if parsed.path == "/pty":
                # Accept auth via header OR query param (JS WebSocket can't set headers)
                query = parse_qs(parsed.query)
                token_from_query = query.get("token", [None])[0]
                if token_from_query:
                    self.headers["Authorization"] = f"Bearer {token_from_query}"
                if not self._authorize():
                    return
                cwd = query.get("cwd", [None])[0]
                cols = int(query.get("cols", ["80"])[0])
                rows = int(query.get("rows", ["24"])[0])
                self._handle_websocket_pty(cwd=cwd, cols=cols, rows=rows)
                return
            if not self._authorize():
                return
            if parsed.path == "/topics":
                self._write_json(HTTPStatus.OK, {"topics": self.server.service.list_topics()})
                return
            if parsed.path == "/feedback-queue":
                self._write_json(HTTPStatus.OK, {"feedback_requests": self.server.service.list_feedback_queue()})
                return
            if parsed.path == "/projects":
                projects = [p.to_json_dict() for p in self.server.scanner.list_projects()]
                self._write_json(HTTPStatus.OK, {"projects": projects})
                return
            if parsed.path == "/projects/activity":
                query = parse_qs(parsed.query)
                project_path = query.get("path", [""])[0]
                activity = self.server.scanner.get_project_activity(project_path, service=self.server.service)
                self._write_json(HTTPStatus.OK, activity)
                return
            if parsed.path == "/projects/init-log":
                query = parse_qs(parsed.query)
                project_path = query.get("path", [""])[0]
                log_lines = self.server.init_runner.get_log(project_path)
                status = self.server.init_runner.status(project_path)
                self._write_json(HTTPStatus.OK, {"log": log_lines, "status": status})
                return
            if parsed.path == "/projects/readme":
                query = parse_qs(parsed.query)
                project_path = query.get("path", [""])[0]
                content = self.server.scanner.read_readme(project_path)
                if content is None:
                    self._write_json(HTTPStatus.NOT_FOUND, {"error": "README not found or path not allowed"})
                    return
                self._write_json(HTTPStatus.OK, {"content": content})
                return
            if parsed.path == "/projects/architecture":
                query = parse_qs(parsed.query)
                project_path = query.get("path", [""])[0]
                tree = self.server.scanner.get_architecture_tree(project_path)
                if tree is None:
                    self._write_json(HTTPStatus.NOT_FOUND, {"error": "No architecture data"})
                    return
                self._write_json(HTTPStatus.OK, {"tree": tree})
                return
            if parsed.path == "/projects/files":
                query = parse_qs(parsed.query)
                project_path = query.get("path", [""])[0]
                rel = query.get("rel", [""])[0]  # relative path within project
                if not project_path:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": "Missing 'path'"})
                    return
                result = self.server.scanner.list_files(project_path, rel)
                if result is None:
                    self._write_json(HTTPStatus.FORBIDDEN, {"error": "Path not allowed"})
                    return
                self._write_json(HTTPStatus.OK, result)
                return
            if parsed.path == "/projects/file-content":
                query = parse_qs(parsed.query)
                project_path = query.get("path", [""])[0]
                rel = query.get("rel", [""])[0]
                if not project_path or not rel:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": "Missing 'path' or 'rel'"})
                    return
                result = self.server.scanner.read_file(project_path, rel)
                if result is None:
                    self._write_json(HTTPStatus.FORBIDDEN, {"error": "Path not allowed or file not found"})
                    return
                self._write_json(HTTPStatus.OK, result)
                return
            if parsed.path == "/sensors":
                query = parse_qs(parsed.query)
                project = query.get("project", [None])[0]
                self._write_json(HTTPStatus.OK, {
                    "sensors": self.server.service.sensor_runner.list_sensors(project),
                })
                return
            if parsed.path == "/signals":
                query = parse_qs(parsed.query)
                project = query.get("project", [None])[0]
                sensor_id = query.get("sensor_id", [None])[0]
                limit = int(query.get("limit", ["50"])[0])
                self._write_json(HTTPStatus.OK, {
                    "signals": self.server.service.sensor_runner.list_signals(project, sensor_id, limit),
                })
                return
            if parsed.path == "/remote":
                tunnels = self.server.tunnel_manager.get_all_tunnels() if self.server.tunnel_manager else []
                active = self.server.tunnel_manager.get_active_tunnel() if self.server.tunnel_manager else None
                self._write_json(HTTPStatus.OK, {
                    "tunnels": tunnels,
                    "active": active.to_dict() if active else None,
                })
                return
            if parsed.path == "/agents/status":
                agents = []
                for executor in self.server.service.executors.values():
                    if hasattr(executor, "check_status"):
                        agents.append(executor.check_status().to_dict())
                self._write_json(HTTPStatus.OK, {"agents": agents})
                return
            if parsed.path == "/chat/config":
                has_key = self.server.service.chat_manager.has_api_key()
                self._write_json(HTTPStatus.OK, {
                    "has_api_key": has_key,
                    "api_key_preview": self.server.service.chat_manager.get_api_key()[:8] + "…" if has_key else "",
                })
                return
            if parsed.path == "/chat/sessions":
                sessions = self.server.service.list_chat_sessions()
                self._write_json(HTTPStatus.OK, {"sessions": sessions})
                return
            # GET /chat/sessions/<id>/messages
            if parsed.path.startswith("/chat/sessions/") and parsed.path.endswith("/messages"):
                parts = parsed.path.split("/")
                if len(parts) == 5:
                    session_id = parts[3]
                    messages = self.server.service.chat_manager.get_messages(session_id)
                    self._write_json(HTTPStatus.OK, {"messages": messages})
                return
            if parsed.path == "/events":
                query = parse_qs(parsed.query)
                after = int(query.get("after", ["0"])[0])
                self._write_json(HTTPStatus.OK, {"events": self.server.service.events_since(after)})
                return
            topic_id = self._extract_topic_id(parsed.path)
            if topic_id and parsed.path == f"/topics/{topic_id}":
                self._write_json(HTTPStatus.OK, self.server.service.get_topic_detail(topic_id))
                return
            if topic_id and parsed.path == f"/topics/{topic_id}/runs":
                self._write_json(HTTPStatus.OK, {"runs": self.server.service.list_runs(topic_id)})
                return
            if topic_id and parsed.path == f"/topics/{topic_id}/artifacts":
                self._write_json(HTTPStatus.OK, {"artifacts": self.server.service.list_artifacts(topic_id)})
                return
            if topic_id and parsed.path == f"/topics/{topic_id}/stream":
                self._handle_sse_stream(topic_id, parsed)
                return
            self._write_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})

        def do_POST(self) -> None:
            if not self._authorize():
                return
            parsed = urlparse(self.path)
            payload = self._read_json_body()
            try:
                if parsed.path == "/chat/config":
                    api_key = payload.get("anthropic_api_key", "")
                    if api_key:
                        self.server.service.chat_manager.set_api_key(api_key)
                        self._write_json(HTTPStatus.OK, {"status": "saved"})
                    else:
                        self._write_json(HTTPStatus.BAD_REQUEST, {"error": "Missing 'anthropic_api_key'"})
                    return
                if parsed.path == "/chat/sessions":
                    project = payload.get("project")  # None for free-floating
                    adapter_type = payload.get("adapter_type", "claude_code")
                    session = self.server.service.create_chat_session(project=project, adapter_type=adapter_type)
                    self._write_json(HTTPStatus.CREATED, session)
                    return
                # Match /chat/sessions/<id>/messages
                if parsed.path.startswith("/chat/sessions/") and parsed.path.endswith("/messages"):
                    parts = parsed.path.split("/")
                    # /chat/sessions/<id>/messages → parts = ['', 'chat', 'sessions', '<id>', 'messages']
                    if len(parts) == 5:
                        session_id = parts[3]
                        message = payload.get("message", "")
                        if not message:
                            self._write_json(HTTPStatus.BAD_REQUEST, {"error": "Missing 'message'"})
                            return
                        started = self.server.service.send_chat_message(session_id, message)
                        if started:
                            self._write_json(HTTPStatus.ACCEPTED, {"status": "streaming"})
                        else:
                            self._write_json(HTTPStatus.CONFLICT, {"error": "Session busy or not found"})
                        return
                if parsed.path == "/sensors/construct":
                    # Create a topic that builds a sensor
                    project = payload.get("project", "")
                    description = payload.get("description", "")
                    if not project or not description:
                        self._write_json(HTTPStatus.BAD_REQUEST, {"error": "Missing 'project' or 'description'"})
                        return
                    detail = self.server.service.create_topic(
                        title=f"Build sensor: {description[:60]}",
                        raw_input=description,
                        tags=["sensor", "infrastructure"],
                        project=project,
                    )
                    self._write_json(HTTPStatus.CREATED, detail)
                    return
                if parsed.path == "/sensors/ingest":
                    # Webhook-style signal ingestion
                    sensor_id = payload.get("sensor_id", "")
                    signals = payload.get("signals", [])
                    if not sensor_id or not signals:
                        self._write_json(HTTPStatus.BAD_REQUEST, {"error": "Missing 'sensor_id' or 'signals'"})
                        return
                    count = self.server.service.sensor_runner.ingest_signals(sensor_id, signals)
                    self._write_json(HTTPStatus.OK, {"ingested": count})
                    return
                if parsed.path == "/projects/cancel-init":
                    project_path = payload.get("path", "")
                    if not project_path:
                        self._write_json(HTTPStatus.BAD_REQUEST, {"error": "Missing 'path'"})
                        return
                    cancelled = self.server.init_runner.cancel(project_path)
                    if cancelled:
                        self._write_json(HTTPStatus.OK, {"status": "cancelled", "path": project_path})
                    else:
                        self._write_json(HTTPStatus.NOT_FOUND, {"error": "No running init for this project"})
                    return
                if parsed.path == "/projects/uninitialize":
                    project_path = payload.get("path", "")
                    if not project_path:
                        self._write_json(HTTPStatus.BAD_REQUEST, {"error": "Missing 'path'"})
                        return
                    scanner_root = self.server.scanner.root
                    if scanner_root is None:
                        self._write_json(HTTPStatus.BAD_REQUEST, {"error": "Server has no projects root configured"})
                        return
                    target = Path(project_path).resolve()
                    try:
                        target.relative_to(scanner_root)
                    except ValueError:
                        self._write_json(HTTPStatus.FORBIDDEN, {"error": "Path is not under projects root"})
                        return
                    if not target.is_dir():
                        self._write_json(HTTPStatus.NOT_FOUND, {"error": "Project directory not found"})
                        return
                    # Don't allow uninstall while an init is running
                    if self.server.init_runner.is_running(str(target)):
                        self._write_json(HTTPStatus.CONFLICT, {"error": "Init is currently running for this project"})
                        return
                    repo = RepoOffload(target)
                    try:
                        repo.uninstall(remove_gitignore_entry=True)
                    except OSError as e:
                        self._write_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": f"Uninstall failed: {e}"})
                        return
                    self.server.init_runner.forget(str(target))
                    self._write_json(HTTPStatus.OK, {"status": "uninstalled", "path": str(target)})
                    return
                if parsed.path == "/projects/initialize":
                    project_path = payload.get("path", "")
                    if not project_path:
                        self._write_json(HTTPStatus.BAD_REQUEST, {"error": "Missing 'path'"})
                        return
                    # Verify the path is a real directory inside the scanner root (security)
                    scanner_root = self.server.scanner.root
                    if scanner_root is None:
                        self._write_json(HTTPStatus.BAD_REQUEST, {"error": "Server has no projects root configured"})
                        return
                    target = Path(project_path).resolve()
                    try:
                        target.relative_to(scanner_root)
                    except ValueError:
                        self._write_json(HTTPStatus.FORBIDDEN, {"error": "Path is not under projects root"})
                        return
                    if not target.is_dir():
                        self._write_json(HTTPStatus.NOT_FOUND, {"error": "Project directory not found"})
                        return
                    started = self.server.init_runner.trigger(str(target))
                    self._write_json(
                        HTTPStatus.ACCEPTED if started else HTTPStatus.CONFLICT,
                        {"status": "initializing" if started else "already_running", "path": str(target)},
                    )
                    return
                if parsed.path == "/topics":
                    detail = self.server.service.create_topic(
                        title=payload.get("title", ""),
                        raw_input=payload.get("raw_input", ""),
                        tags=payload.get("tags", []),
                        priority=payload.get("priority", "normal"),
                        project=payload.get("project"),
                        parent_topic_id=payload.get("parent_topic_id"),
                    )
                    self._write_json(HTTPStatus.CREATED, detail)
                    return
                topic_id = self._extract_topic_id(parsed.path)
                if topic_id and parsed.path == f"/topics/{topic_id}/subtopics":
                    detail = self.server.service.create_topic(
                        title=payload.get("title", ""),
                        raw_input=payload.get("raw_input", ""),
                        tags=payload.get("tags", []),
                        priority=payload.get("priority", "normal"),
                        project=payload.get("project"),
                        parent_topic_id=topic_id,
                    )
                    self._write_json(HTTPStatus.CREATED, detail)
                    return
                if topic_id and parsed.path == f"/topics/{topic_id}/refresh-requirement":
                    self._write_json(HTTPStatus.OK, self.server.service.refresh_requirement(topic_id, note=payload.get("note", "")))
                    return
                if topic_id and parsed.path == f"/topics/{topic_id}/refresh-plan":
                    self._write_json(HTTPStatus.OK, self.server.service.refresh_plan(topic_id, note=payload.get("note", "")))
                    return
                if topic_id and parsed.path == f"/topics/{topic_id}/feedback-requests":
                    request = self.server.service.create_feedback_request(
                        topic_id=topic_id,
                        request_type=payload["request_type"],
                        title=payload["title"],
                        prompt=payload["prompt"],
                        options=payload.get("options", []),
                        allow_note=payload.get("allow_note", True),
                        metadata=payload.get("metadata", {}),
                    )
                    self._write_json(HTTPStatus.CREATED, request)
                    return
                if topic_id and parsed.path == f"/topics/{topic_id}/feedback-responses":
                    detail = self.server.service.respond_to_feedback(
                        topic_id=topic_id,
                        request_id=payload["request_id"],
                        selected_options=payload.get("selected_options", []),
                        note=payload.get("note", ""),
                        actor=payload.get("actor", "human"),
                    )
                    self._write_json(HTTPStatus.OK, detail)
                    return
                if topic_id and parsed.path == f"/topics/{topic_id}/approve-requirement":
                    self._write_json(HTTPStatus.OK, self.server.service.approve_requirement(topic_id, actor=payload.get("actor", "human")))
                    return
                if topic_id and parsed.path == f"/topics/{topic_id}/approve-plan":
                    self._write_json(HTTPStatus.OK, self.server.service.approve_plan(topic_id, actor=payload.get("actor", "human")))
                    return
                if topic_id and parsed.path == f"/topics/{topic_id}/runs":
                    run = self.server.service.trigger_run(
                        topic_id=topic_id,
                        executor_name=payload.get("executor", "command"),
                        command=payload.get("command", []),
                    )
                    self._write_json(HTTPStatus.ACCEPTED, run)
                    return
                if topic_id and parsed.path == f"/topics/{topic_id}/mark-human-testing":
                    self._write_json(HTTPStatus.OK, self.server.service.mark_human_testing(topic_id))
                    return
                if topic_id and parsed.path == f"/topics/{topic_id}/mark-passed":
                    self._write_json(HTTPStatus.OK, self.server.service.mark_passed(topic_id))
                    return
                if topic_id and parsed.path == f"/topics/{topic_id}/archive":
                    self._write_json(HTTPStatus.OK, self.server.service.archive_topic(topic_id))
                    return
                if topic_id and parsed.path == f"/topics/{topic_id}/run-to-gate":
                    gate = payload.get("gate", "")
                    if not gate:
                        self._write_json(HTTPStatus.BAD_REQUEST, {"error": "Missing 'gate' field"})
                        return
                    timeout = float(payload.get("timeout", 600))
                    detail = self.server.service.wait_for_gate(topic_id, gate, timeout)
                    self._write_json(HTTPStatus.OK, detail)
                    return
                if topic_id and parsed.path == f"/topics/{topic_id}/execute-and-wait":
                    executor = payload.get("executor", "claude")
                    command = payload.get("command", [])
                    timeout = float(payload.get("timeout", 600))
                    detail = self.server.service.execute_and_wait(topic_id, executor, command, timeout)
                    self._write_json(HTTPStatus.OK, detail)
                    return
                self._write_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})
            except NotFoundError as error:
                self._write_json(HTTPStatus.NOT_FOUND, {"error": str(error)})
            except ValidationError as error:
                self._write_json(HTTPStatus.UNPROCESSABLE_ENTITY, {"error": str(error)})
            except GateTimeoutError as error:
                self._write_json(HTTPStatus.REQUEST_TIMEOUT, {"error": str(error)})
            except KeyError as error:
                self._write_json(HTTPStatus.BAD_REQUEST, {"error": f"Missing field: {error.args[0]}"})

        def log_message(self, format: str, *args: Any) -> None:
            import sys
            from datetime import datetime
            ts = datetime.now().strftime("%H:%M:%S")
            sys.stderr.write(f"[{ts}] {self.address_string()} - {format % args}\n")
            sys.stderr.flush()

        def _authorize(self) -> bool:
            headers = {key: value for key, value in self.headers.items()}
            if self.server.auth.authorize(headers):
                return True
            self._write_json(HTTPStatus.UNAUTHORIZED, {"error": "Unauthorized"})
            return False

        def _read_json_body(self) -> Dict[str, Any]:
            length = int(self.headers.get("Content-Length", "0"))
            if length == 0:
                return {}
            raw = self.rfile.read(length)
            return json.loads(raw.decode("utf-8"))

        def _write_json(self, status: HTTPStatus, payload: Dict[str, Any]) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status.value)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)

        def _extract_topic_id(self, path: str) -> Optional[str]:
            parts = [part for part in path.split("/") if part]
            if len(parts) >= 2 and parts[0] == "topics":
                return parts[1]
            return None

        def _handle_sse_stream(self, topic_id: str, parsed) -> None:
            """Server-Sent Events stream filtered to a single topic."""
            topic = self.server.service.store.get_topic(topic_id)
            if topic is None:
                self._write_json(HTTPStatus.NOT_FOUND, {"error": f"Topic {topic_id} not found"})
                return

            # Determine replay point from Last-Event-ID header or ?after= query param
            query = parse_qs(parsed.query)
            after_header = 0
            last_event_id = self.headers.get("Last-Event-ID")
            if last_event_id:
                try:
                    after_header = int(last_event_id)
                except ValueError:
                    pass
            after_query = int(query.get("after", ["0"])[0])
            after_sequence = max(after_header, after_query)

            # Subscribe to EventBus BEFORE replaying to avoid missing events
            subscriber_id, subscription = self.server.service.event_bus.subscribe()

            try:
                # Send SSE response headers
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "keep-alive")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("X-Accel-Buffering", "no")
                self.end_headers()

                # Replay phase: send stored events after the given sequence
                replayed = self.server.service.store.list_events_for_topic(topic_id, after_sequence)
                last_seq = after_sequence
                for event in replayed:
                    self.wfile.write(_format_sse(event))
                    self.wfile.flush()
                    if event.sequence and event.sequence > last_seq:
                        last_seq = event.sequence

                # Live phase: stream new events from EventBus
                while True:
                    try:
                        event = subscription.get(timeout=15.0)
                    except queue.Empty:
                        # Send keepalive comment
                        self.wfile.write(b": keepalive\n\n")
                        self.wfile.flush()
                        continue

                    # Skip events for other topics
                    if event.topic_id != topic_id:
                        continue
                    # Skip events already sent during replay
                    if event.sequence is not None and event.sequence <= last_seq:
                        continue

                    self.wfile.write(_format_sse(event))
                    self.wfile.flush()
                    if event.sequence and event.sequence > last_seq:
                        last_seq = event.sequence

            except (BrokenPipeError, ConnectionError, OSError):
                pass
            finally:
                self.server.service.event_bus.unsubscribe(subscriber_id)

        def _handle_websocket_pty(self, cwd: str | None = None, cols: int = 80, rows: int = 24) -> None:
            """WebSocket endpoint that spawns a pty and bridges I/O."""
            self.log_message("PTY WebSocket upgrade from %s", self.address_string())
            key = self.headers.get("Sec-WebSocket-Key")
            if not key:
                self._write_json(HTTPStatus.BAD_REQUEST, {"error": "Missing Sec-WebSocket-Key"})
                return
            accept = base64.b64encode(
                hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("utf-8")).digest()
            ).decode("utf-8")
            response = (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
            ).encode("utf-8")
            self.request.sendall(response)

            # Determine working directory
            work_dir = cwd or os.path.expanduser("~")
            if not os.path.isdir(work_dir):
                work_dir = os.path.expanduser("~")

            # Spawn pty with fork
            import fcntl
            import termios
            child_pid, master_fd = pty.fork()
            if child_pid == 0:
                # Child process: exec shell
                os.chdir(work_dir)
                shell = os.environ.get("SHELL", "/bin/zsh")
                os.execvpe(shell, [shell, "-l"], os.environ)
                # Never reached
                os._exit(1)

            # Parent: set terminal size
            winsize = struct.pack("HHHH", rows, cols, 0, 0)
            fcntl.ioctl(master_fd, termios.TIOCSWINSZ, winsize)

            # Make master_fd non-blocking
            flags = fcntl.fcntl(master_fd, fcntl.F_GETFL)
            fcntl.fcntl(master_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

            stop_event = threading.Event()
            self.connection.settimeout(1.0)

            def ws_reader() -> None:
                """Read WebSocket frames and write to pty master."""
                while not stop_event.is_set():
                    try:
                        frame = _read_frame(self.connection)
                    except (ConnectionError, OSError):
                        stop_event.set()
                        return
                    if frame is None:
                        continue
                    opcode, payload = frame
                    if opcode == 0x8:  # close
                        stop_event.set()
                        return
                    if opcode == 0x9:  # ping → pong
                        try:
                            self.connection.sendall(_encode_frame(payload.decode("utf-8", errors="replace"), opcode=0xA))
                        except OSError:
                            stop_event.set()
                            return
                        continue
                    if opcode == 0x1:  # text
                        text = payload.decode("utf-8", errors="replace")
                        # Handle resize messages: {"type":"resize","cols":N,"rows":N}
                        if text.startswith("{"):
                            try:
                                msg = json.loads(text)
                                if msg.get("type") == "resize":
                                    new_cols = int(msg.get("cols", cols))
                                    new_rows = int(msg.get("rows", rows))
                                    winsize = struct.pack("HHHH", new_rows, new_cols, 0, 0)
                                    fcntl.ioctl(master_fd, termios.TIOCSWINSZ, winsize)
                                    continue
                            except (json.JSONDecodeError, ValueError):
                                pass
                        # Regular input: write to pty
                        try:
                            os.write(master_fd, payload)
                        except OSError:
                            stop_event.set()
                            return
                    elif opcode == 0x2:  # binary
                        try:
                            os.write(master_fd, payload)
                        except OSError:
                            stop_event.set()
                            return

            reader_thread = threading.Thread(target=ws_reader, daemon=True)
            reader_thread.start()

            # Main thread: read pty output and send over WebSocket
            try:
                while not stop_event.is_set():
                    readable, _, _ = select.select([master_fd], [], [], 0.1)
                    if master_fd in readable:
                        try:
                            data = os.read(master_fd, 4096)
                        except OSError:
                            break
                        if not data:
                            break
                        # Send as binary WebSocket frame
                        frame_bytes = _encode_binary_frame(data)
                        self.request.sendall(frame_bytes)
            except OSError:
                pass
            finally:
                stop_event.set()
                os.close(master_fd)
                try:
                    os.kill(child_pid, 9)
                    os.waitpid(child_pid, 0)
                except OSError:
                    pass
                try:
                    self.request.close()
                except OSError:
                    pass

        def _handle_websocket(self) -> None:
            self.log_message("WebSocket upgrade from %s", self.address_string())
            key = self.headers.get("Sec-WebSocket-Key")
            if not key:
                self._write_json(HTTPStatus.BAD_REQUEST, {"error": "Missing Sec-WebSocket-Key"})
                return
            accept = base64.b64encode(
                hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("utf-8")).digest()
            ).decode("utf-8")
            response = (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
            ).encode("utf-8")
            self.request.sendall(response)
            subscriber_id, subscription = self.server.service.event_bus.subscribe()
            stop_event = threading.Event()
            self.connection.settimeout(1.0)

            def reader() -> None:
                while not stop_event.is_set():
                    try:
                        frame = _read_frame(self.connection)
                    except (ConnectionError, OSError):
                        stop_event.set()
                        return
                    if frame is None:
                        continue
                    opcode, payload = frame
                    if opcode == 0x8:
                        stop_event.set()
                        return
                    if opcode == 0x9:
                        try:
                            self.connection.sendall(_encode_frame(payload.decode("utf-8"), opcode=0xA))
                        except OSError:
                            stop_event.set()
                            return

            reader_thread = threading.Thread(target=reader, daemon=True)
            reader_thread.start()
            hello = json.dumps({"event_type": "hello", "payload": {"server": "offload"}})
            self.request.sendall(_encode_frame(hello))
            try:
                while not stop_event.is_set():
                    try:
                        event = subscription.get(timeout=10.0)
                        message = json.dumps(event.to_json_dict())
                    except queue.Empty:
                        message = json.dumps({"event_type": "heartbeat"})
                    self.request.sendall(_encode_frame(message))
            except OSError:
                stop_event.set()
            finally:
                self.server.service.event_bus.unsubscribe(subscriber_id)
                try:
                    self.request.close()
                except OSError:
                    pass

    return Handler


def _recv_exact(sock: socket.socket, size: int) -> bytes:
    buffer = bytearray()
    while len(buffer) < size:
        chunk = sock.recv(size - len(buffer))
        if not chunk:
            raise ConnectionError("Socket closed.")
        buffer.extend(chunk)
    return bytes(buffer)


def _read_frame(sock: socket.socket):
    try:
        header = _recv_exact(sock, 2)
    except socket.timeout:
        return None
    first_byte, second_byte = header[0], header[1]
    opcode = first_byte & 0x0F
    masked = (second_byte & 0x80) != 0
    length = second_byte & 0x7F
    if length == 126:
        length = int.from_bytes(_recv_exact(sock, 2), "big")
    elif length == 127:
        length = int.from_bytes(_recv_exact(sock, 8), "big")
    mask = _recv_exact(sock, 4) if masked else b""
    payload = _recv_exact(sock, length) if length else b""
    if masked and payload:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return opcode, payload


def _encode_binary_frame(data: bytes) -> bytes:
    """Encode a binary WebSocket frame (opcode 0x2)."""
    header = bytearray()
    header.append(0x80 | 0x2)
    length = len(data)
    if length < 126:
        header.append(length)
    elif length < 2**16:
        header.append(126)
        header.extend(length.to_bytes(2, "big"))
    else:
        header.append(127)
        header.extend(length.to_bytes(8, "big"))
    return bytes(header) + data


def _encode_frame(text: str, opcode: int = 0x1) -> bytes:
    payload = text.encode("utf-8")
    header = bytearray()
    header.append(0x80 | opcode)
    length = len(payload)
    if length < 126:
        header.append(length)
    elif length < 2**16:
        header.append(126)
        header.extend(length.to_bytes(2, "big"))
    else:
        header.append(127)
        header.extend(length.to_bytes(8, "big"))
    return bytes(header) + payload


def _format_sse(event) -> bytes:
    """Format an EventRecord as an SSE message."""
    lines = []
    if event.sequence is not None:
        lines.append(f"id: {event.sequence}")
    lines.append(f"event: {event.event_type}")
    lines.append(f"data: {json.dumps(event.to_json_dict())}")
    lines.append("")
    lines.append("")
    return "\n".join(lines).encode("utf-8")
