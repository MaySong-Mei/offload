"""Chat session manager — intent capture via Claude API.

Sessions and messages are stored server-side. The iOS client is a thin
streaming display. ANTHROPIC_API_KEY lives on the server.
"""
from __future__ import annotations

import json
import os
import sys
import threading
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional

from .event_bus import EventBus
from .models import EventRecord, utc_now

_CHAT_SYSTEM_PROMPT_PATH = Path(__file__).parent / "templates" / "chat_system.md"


class ChatSession:
    """A single chat session with full message history."""

    def __init__(
        self,
        session_id: str,
        title: str = "New Chat",
        project: Optional[str] = None,
    ):
        self.session_id = session_id
        self.title = title
        self.project = project
        self.messages: List[Dict[str, str]] = []  # [{"role": "user/assistant", "content": "..."}]
        self.created_at = utc_now()
        self.last_message_at = utc_now()

    def to_dict(self) -> Dict[str, Any]:
        return {
            "session_id": self.session_id,
            "title": self.title,
            "project": self.project,
            "messages": self.messages,
            "created_at": self.created_at,
            "last_message_at": self.last_message_at,
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
    def from_dict(cls, data: Dict[str, Any]) -> "ChatSession":
        session = cls(
            session_id=data["session_id"],
            title=data.get("title", "New Chat"),
            project=data.get("project"),
        )
        session.messages = data.get("messages", [])
        session.created_at = data.get("created_at", utc_now())
        session.last_message_at = data.get("last_message_at", utc_now())
        return session


class ChatManager:
    """Manages chat sessions via Claude API. All data lives server-side."""

    def __init__(self, event_bus: EventBus, workspace_root: Path):
        self.event_bus = event_bus
        self.workspace_root = workspace_root
        self._sessions_dir = workspace_root / "chat" / "sessions"
        self._sessions_dir.mkdir(parents=True, exist_ok=True)
        self._config_path = workspace_root / "chat" / "config.json"
        self._lock = threading.Lock()
        self._active: Dict[str, threading.Thread] = {}
        self._system_prompt: Optional[str] = None

    # ---- API Key management --------------------------------------------------

    def get_api_key(self) -> str:
        """Get API key: env var takes precedence, then config file."""
        env_key = os.environ.get("ANTHROPIC_API_KEY", "")
        if env_key:
            return env_key
        config = self._load_config()
        return config.get("anthropic_api_key", "")

    def set_api_key(self, key: str) -> None:
        """Persist API key to config file."""
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

    @property
    def system_prompt_template(self) -> str:
        if self._system_prompt is None:
            if _CHAT_SYSTEM_PROMPT_PATH.is_file():
                self._system_prompt = _CHAT_SYSTEM_PROMPT_PATH.read_text()
            else:
                self._system_prompt = "You are an Offload chat agent."
        return self._system_prompt

    # ---- Session CRUD -------------------------------------------------------

    def _session_path(self, session_id: str) -> Path:
        return self._sessions_dir / f"{session_id}.json"

    def _save_session(self, session: ChatSession) -> None:
        path = self._session_path(session.session_id)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(session.to_dict(), indent=2))
        tmp.rename(path)

    def _load_session(self, session_id: str) -> Optional[ChatSession]:
        path = self._session_path(session_id)
        if not path.is_file():
            return None
        try:
            return ChatSession.from_dict(json.loads(path.read_text()))
        except (json.JSONDecodeError, KeyError):
            return None

    def list_sessions(self) -> List[Dict[str, Any]]:
        sessions = []
        for f in self._sessions_dir.iterdir():
            if f.suffix != ".json":
                continue
            try:
                data = json.loads(f.read_text())
                session = ChatSession.from_dict(data)
                sessions.append(session.to_summary())
            except (json.JSONDecodeError, KeyError):
                continue
        sessions.sort(key=lambda s: s.get("last_message_at", ""), reverse=True)
        return sessions

    def create_session(self, project: Optional[str] = None) -> ChatSession:
        session_id = f"sess-{uuid.uuid4().hex[:10]}"
        session = ChatSession(session_id=session_id, project=project)
        self._save_session(session)
        return session

    def get_session(self, session_id: str) -> Optional[ChatSession]:
        return self._load_session(session_id)

    def get_messages(self, session_id: str) -> List[Dict[str, str]]:
        session = self._load_session(session_id)
        if not session:
            return []
        return session.messages

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

        system_prompt = self._build_system_prompt(project_context, topics_summary)

        thread = threading.Thread(
            target=self._run_api_call,
            args=(session, system_prompt),
            daemon=True,
        )
        with self._lock:
            self._active[session_id] = thread
        thread.start()
        return True

    def _build_system_prompt(
        self,
        project_context: Optional[Dict[str, str]] = None,
        topics_summary: Optional[str] = None,
    ) -> str:
        ctx_parts = []
        if project_context:
            for name in ["summary.md", "architecture.md", "conventions.md"]:
                content = project_context.get(name, "").strip()
                if content:
                    ctx_parts.append(f"### {name}\n{content[:2000]}")
        ctx_str = "\n\n".join(ctx_parts) if ctx_parts else "No project context loaded."
        topics_str = topics_summary or "No active topics."

        system = self.system_prompt_template.replace("{project_context}", ctx_str)
        system = system.replace("{topics_summary}", topics_str)
        return system

    def _run_api_call(self, session: ChatSession, system_prompt: str) -> None:
        sid = session.session_id
        try:
            import anthropic

            api_key = self.get_api_key()
            if not api_key:
                self._publish_event(sid, "chat.error", {
                    "error": "API key not configured. Set it in Settings."
                })
                return

            self._publish_event(sid, "chat.status", {"message": "Connecting…"})

            client = anthropic.Anthropic(api_key=api_key)

            full_response = ""
            with client.messages.stream(
                model="claude-sonnet-4-20250514",
                max_tokens=4096,
                system=system_prompt,
                messages=session.messages,
            ) as stream:
                for text in stream.text_stream:
                    full_response += text
                    self._publish_event(sid, "chat.stream", {
                        "claude_event_type": "assistant",
                        "text": text,
                    })

            # Save assistant response to session
            session.messages.append({"role": "assistant", "content": full_response})
            session.last_message_at = utc_now()
            self._save_session(session)

            self._publish_event(sid, "chat.stream", {
                "claude_event_type": "result",
                "result": full_response[:1000],
            })

        except ImportError:
            self._publish_event(sid, "chat.error", {
                "error": "anthropic package not installed on server"
            })
        except Exception as e:
            print(f"[chat] session={sid} error: {e}", file=sys.stderr)
            self._publish_event(sid, "chat.error", {"error": str(e)})
        finally:
            with self._lock:
                self._active.pop(sid, None)
            self._publish_event(sid, "chat.done", {})

    def _publish_event(self, session_id: str, event_type: str, payload: Dict[str, Any]) -> None:
        event = EventRecord(
            event_id=f"evt-{uuid.uuid4().hex[:12]}",
            event_type=event_type,
            topic_id="",
            payload={**payload, "chat_session_id": session_id},
        )
        self.event_bus.publish(event)
