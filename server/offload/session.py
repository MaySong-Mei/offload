"""Offload session manager — Claude Code driven sessions.

Each session is backed by a Claude Code process running in the project
directory.  User messages are sent as prompts; CC output is streamed back
to the iOS client via the event bus.  No Anthropic SDK needed — CC handles
its own auth and tool use natively.
"""
from __future__ import annotations

import json
import os
import sys
import threading
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional

from .adapters import AgentEvent, ClaudeCodeAdapter, PTYAdapter
from .event_bus import EventBus
from .models import EventRecord, utc_now

_SESSION_SYSTEM_PROMPT_PATH = Path(__file__).parent / "templates" / "session_system.md"


class OffloadSession:
    """A single offload session backed by a Claude Code process."""

    def __init__(
        self,
        session_id: str,
        title: str = "New Chat",
        project: Optional[str] = None,
        adapter_type: str = "claude_code",
    ):
        self.session_id = session_id
        self.title = title
        self.project = project
        self.adapter_type = adapter_type
        self.messages: List[Dict[str, Any]] = []
        self.created_at = utc_now()
        self.last_message_at = utc_now()
        self._adapter_session_id: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "session_id": self.session_id,
            "title": self.title,
            "project": self.project,
            "adapter_type": self.adapter_type,
            "messages": self.messages,
            "created_at": self.created_at,
            "last_message_at": self.last_message_at,
            "version": 2,
            "adapter_session_id": self._adapter_session_id,
        }

    def to_summary(self) -> Dict[str, Any]:
        return {
            "session_id": self.session_id,
            "title": self.title,
            "project": self.project,
            "last_message_at": self.last_message_at,
            "created_at": self.created_at,
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "OffloadSession":
        session = cls(
            session_id=data["session_id"],
            title=data.get("title", "New Chat"),
            project=data.get("project"),
            adapter_type=data.get("adapter_type", "claude_code"),
        )
        session.messages = data.get("messages", [])
        session.created_at = data.get("created_at", utc_now())
        session.last_message_at = data.get("last_message_at", utc_now())
        session._adapter_session_id = data.get("adapter_session_id")
        return session


class OffloadSessionManager:
    """Manages offload sessions.  Drop-in evolution of ChatManager.

    Each session drives a Claude Code (or other agent) process directly.
    No Anthropic API key required — CC manages its own authentication.
    """

    def __init__(self, event_bus: EventBus, workspace_root: Path):
        self.event_bus = event_bus
        self.workspace_root = workspace_root
        self._sessions_dir = workspace_root / "chat" / "sessions"
        self._sessions_dir.mkdir(parents=True, exist_ok=True)
        self._config_path = workspace_root / "chat" / "config.json"
        self._lock = threading.Lock()
        self._active: Dict[str, threading.Thread] = {}

    # ---- API Key (kept for backward compat with iOS settings) ----------------

    def get_api_key(self) -> str:
        env_key = os.environ.get("ANTHROPIC_API_KEY", "")
        if env_key:
            return env_key
        config = self._load_config()
        return config.get("anthropic_api_key", "")

    def set_api_key(self, key: str) -> None:
        config = self._load_config()
        config["anthropic_api_key"] = key
        self._save_config(config)

    def has_api_key(self) -> bool:
        return bool(self.get_api_key())

    def _load_config(self) -> Dict[str, Any]:
        if not self._config_path.is_file():
            return {}
        try:
            return json.loads(self._config_path.read_text())
        except (json.JSONDecodeError, OSError):
            return {}

    def _save_config(self, config: Dict[str, Any]) -> None:
        self._config_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self._config_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(config, indent=2))
        tmp.rename(self._config_path)

    # ---- Session CRUD -------------------------------------------------------

    def _session_path(self, session_id: str) -> Path:
        return self._sessions_dir / f"{session_id}.json"

    def _save_session(self, session: OffloadSession) -> None:
        path = self._session_path(session.session_id)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(session.to_dict(), indent=2))
        tmp.rename(path)

    def _load_session(self, session_id: str) -> Optional[OffloadSession]:
        path = self._session_path(session_id)
        if not path.is_file():
            return None
        try:
            data = json.loads(path.read_text())
            return OffloadSession.from_dict(data)
        except (json.JSONDecodeError, KeyError):
            return None

    def list_sessions(self) -> List[Dict[str, Any]]:
        sessions = []
        for f in self._sessions_dir.iterdir():
            if f.suffix != ".json":
                continue
            try:
                data = json.loads(f.read_text())
                session = OffloadSession.from_dict(data)
                sessions.append(session.to_summary())
            except (json.JSONDecodeError, KeyError):
                continue
        sessions.sort(key=lambda s: s.get("last_message_at", ""), reverse=True)
        return sessions

    def create_session(
        self,
        project: Optional[str] = None,
        adapter_type: str = "claude_code",
    ) -> OffloadSession:
        session_id = f"sess-{uuid.uuid4().hex[:10]}"
        session = OffloadSession(
            session_id=session_id,
            project=project,
            adapter_type=adapter_type,
        )
        self._save_session(session)
        return session

    def get_session(self, session_id: str) -> Optional[OffloadSession]:
        return self._load_session(session_id)

    def get_messages(self, session_id: str) -> List[Dict[str, Any]]:
        session = self._load_session(session_id)
        if not session:
            return []
        return [
            {"role": m["role"], "content": m["content"]}
            for m in session.messages
            if m.get("role") in ("user", "assistant") and isinstance(m.get("content"), str)
        ]

    # ---- Messaging -----------------------------------------------------------

    def is_busy(self, session_id: str) -> bool:
        with self._lock:
            thread = self._active.get(session_id)
            return thread is not None and thread.is_alive()

    def send_message(
        self,
        session_id: str,
        message: str,
        project_context: Optional[Dict[str, str]] = None,
        topics_summary: Optional[str] = None,
    ) -> bool:
        session = self._load_session(session_id)
        if not session:
            return False
        if self.is_busy(session_id):
            return False

        session.last_message_at = utc_now()
        session.messages.append({"role": "user", "content": message})

        if session.title == "New Chat":
            session.title = message[:60].strip()

        self._save_session(session)

        # Build a prompt that includes context
        prompt = self._build_prompt(message, project_context, topics_summary)

        thread = threading.Thread(
            target=self._run_session_turn,
            args=(session, prompt),
            daemon=True,
        )
        with self._lock:
            self._active[session_id] = thread
        thread.start()
        return True

    def _build_prompt(
        self,
        user_message: str,
        project_context: Optional[Dict[str, str]] = None,
        topics_summary: Optional[str] = None,
    ) -> str:
        """Build prompt for the CC adapter.

        For the first message we include system context.  For follow-ups
        (via --resume) the context is already in the CC session.
        """
        parts: List[str] = []

        if project_context:
            ctx_parts = []
            for name in ["summary.md", "architecture.md", "conventions.md"]:
                content = project_context.get(name, "").strip()
                if content:
                    ctx_parts.append(f"### {name}\n{content[:2000]}")
            if ctx_parts:
                parts.append("## Project Context\n" + "\n\n".join(ctx_parts))

        if topics_summary:
            parts.append(f"## Active Topics\n{topics_summary}")

        parts.append(user_message)
        return "\n\n---\n\n".join(parts)

    # ---- CC-driven session turn ---------------------------------------------

    def _run_session_turn(self, session: OffloadSession, prompt: str) -> None:
        """Send prompt to Claude Code and stream events to iOS."""
        sid = session.session_id
        try:
            self._publish(sid, "chat.status", {"message": "Connecting…"})

            # Create adapter
            adapter = self._create_adapter(session)
            if adapter is None:
                self._publish(sid, "chat.error", {
                    "error": f"Unknown adapter type: {session.adapter_type}",
                })
                return

            # Start adapter in project directory (or home)
            cwd = Path(session.project) if session.project else Path.home()
            if not cwd.is_dir():
                cwd = Path.home()
            adapter.start(cwd)

            self._publish(sid, "chat.stream", {
                "claude_event_type": "agent_activity",
                "instruction": prompt[:200],
            })

            # Collected text for the assistant message
            collected_text: List[str] = []

            def _on_event(evt: AgentEvent) -> None:
                if evt.event_type == "text_output":
                    text = evt.data.get("text", "")
                    if text:
                        collected_text.append(text)
                        self._publish(sid, "chat.stream", {
                            "claude_event_type": "assistant",
                            "text": text,
                        })
                elif evt.event_type == "tool_use":
                    self._publish(sid, "chat.stream", {
                        "claude_event_type": "agent_output",
                        "agent_event_type": "tool_use",
                        "data": evt.data,
                    })
                elif evt.event_type == "done":
                    result = evt.data.get("result", "")
                    if result and not collected_text:
                        collected_text.append(result)
                        self._publish(sid, "chat.stream", {
                            "claude_event_type": "assistant",
                            "text": result,
                        })

            # Run — blocks until CC finishes
            result_text = adapter.send(prompt, on_event=_on_event)

            # If no text was streamed but we got a result, use it
            assistant_content = "".join(collected_text) or result_text or "(no output)"

            # Save assistant message
            session.messages.append({"role": "assistant", "content": assistant_content})
            session.last_message_at = utc_now()

            # Persist CC session_id for resume
            if adapter.session_id:
                session._adapter_session_id = adapter.session_id
            self._save_session(session)

            self._publish(sid, "chat.stream", {
                "claude_event_type": "agent_done",
                "result_preview": assistant_content[:500],
            })

            self._publish(sid, "chat.stream", {
                "claude_event_type": "result",
                "result": assistant_content[:1000],
            })

        except Exception as e:
            print(f"[session] session={sid} error: {e}", file=sys.stderr)
            import traceback
            traceback.print_exc(file=sys.stderr)
            self._publish(sid, "chat.error", {"error": str(e)})
        finally:
            with self._lock:
                self._active.pop(sid, None)
            self._publish(sid, "chat.done", {})

    def _create_adapter(self, session: OffloadSession):
        """Create an adapter instance based on session config."""
        if session.adapter_type == "claude_code":
            adapter = ClaudeCodeAdapter()
            if session._adapter_session_id:
                adapter._session_id = session._adapter_session_id
            return adapter
        elif session.adapter_type == "pty":
            return PTYAdapter()
        return None

    def _publish(self, session_id: str, event_type: str, payload: Dict[str, Any]) -> None:
        event = EventRecord(
            event_id=f"evt-{uuid.uuid4().hex[:12]}",
            event_type=event_type,
            topic_id="",
            payload={**payload, "chat_session_id": session_id},
        )
        self.event_bus.publish(event)
