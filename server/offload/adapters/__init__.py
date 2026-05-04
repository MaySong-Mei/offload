"""Agent adapters — pluggable coding agent drivers."""

from ._base import AgentAdapter, AgentEvent, EventCallback
from .claude_code import ClaudeCodeAdapter
from .pty_adapter import PTYAdapter

__all__ = [
    "AgentAdapter",
    "AgentEvent",
    "EventCallback",
    "ClaudeCodeAdapter",
    "PTYAdapter",
]
