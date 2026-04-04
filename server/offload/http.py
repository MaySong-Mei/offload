from __future__ import annotations

import base64
import hashlib
import json
import queue
import socket
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Optional
from urllib.parse import parse_qs, urlparse

from .service import HarnessService, NotFoundError, ValidationError


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

    def __init__(self, server_address, RequestHandlerClass, service: HarnessService, auth: AuthConfig):
        super().__init__(server_address, RequestHandlerClass)
        self.service = service
        self.auth = auth


def create_http_server(host: str, port: int, service: HarnessService, auth_token: Optional[str] = None) -> HarnessHTTPServer:
    auth = AuthConfig(auth_token)
    handler = make_handler()
    return HarnessHTTPServer((host, port), handler, service, auth)


def make_handler():
    class Handler(BaseHTTPRequestHandler):
        server: HarnessHTTPServer

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
            if not self._authorize():
                return
            if parsed.path == "/topics":
                self._write_json(HTTPStatus.OK, {"topics": self.server.service.list_topics()})
                return
            if parsed.path == "/feedback-queue":
                self._write_json(HTTPStatus.OK, {"feedback_requests": self.server.service.list_feedback_queue()})
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
            self._write_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})

        def do_POST(self) -> None:
            if not self._authorize():
                return
            parsed = urlparse(self.path)
            payload = self._read_json_body()
            try:
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
                    self._write_json(HTTPStatus.OK, self.server.service.refresh_plan(topic_id))
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
                self._write_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})
            except NotFoundError as error:
                self._write_json(HTTPStatus.NOT_FOUND, {"error": str(error)})
            except ValidationError as error:
                self._write_json(HTTPStatus.UNPROCESSABLE_ENTITY, {"error": str(error)})
            except KeyError as error:
                self._write_json(HTTPStatus.BAD_REQUEST, {"error": f"Missing field: {error.args[0]}"})

        def log_message(self, format: str, *args: Any) -> None:
            return

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

        def _handle_websocket(self) -> None:
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
