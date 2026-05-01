"""Agent adapter protocol — abstraction for coding agents."""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, Optional, Protocol

from ..models import utc_now


@dataclass
class AgentEvent:
    """Unified event emitted by any agent adapter."""
    event_type: str  # text_output, tool_use, file_change, status_change, done, error
    data: Dict[str, Any] = field(default_factory=dict)
    timestamp: str = field(default_factory=utc_now)


EventCallback = Callable[[AgentEvent], None]


class AgentAdapter(Protocol):
    """Interface for coding agent adapters.

    Adapters are long-lived: start once, send multiple instructions, stop when done.
    ``send()`` blocks until the agent finishes the current instruction and returns
    collected output text.
    """

    def start(self, cwd: Path, env: Optional[Dict[str, str]] = None) -> None:
        """Prepare the adapter. May be lazy (defer process spawn to first send)."""
        ...

    def send(
        self,
        message: str,
        on_event: Optional[EventCallback] = None,
    ) -> str:
        """Send an instruction and block until the agent completes it.

        *on_event* is called (from the current thread) for each intermediate
        event so callers can stream progress.  Returns the collected result text.
        """
        ...

    def stop(self) -> None:
        """Terminate the underlying agent process, if any."""
        ...

    @property
    def is_running(self) -> bool:
        """True while an agent process is alive."""
        ...

    @property
    def session_id(self) -> Optional[str]:
        """Resumable session id (adapter-specific, may be None)."""
        ...
