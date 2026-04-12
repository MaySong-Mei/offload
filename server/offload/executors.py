"""Backward-compatibility shim — all executor code now lives in agents/."""
from .agents import (  # noqa: F401
    ALL_EXECUTORS,
    AgentStatus,
    ClaudeExecutor,
    CodexExecutor,
    CommandExecutor,
    ExecutionResult,
    Executor,
)
