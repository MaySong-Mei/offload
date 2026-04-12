"""Agent executors registry.

Each agent lives in its own module. To add a new agent:
1. Create a new file in this directory (e.g. `my_agent.py`)
2. Implement a class with `name`, `check_status()`, and `execute()` (see _base.py for the protocol)
3. Import and add it to ALL_EXECUTORS below
"""
from ._base import AgentStatus, ExecutionResult, Executor
from .claude import ClaudeExecutor
from .codex import CodexExecutor
from .command import CommandExecutor

# Canonical list of all available executors.
# The service registers these at startup.
ALL_EXECUTORS = [
    CommandExecutor,
    ClaudeExecutor,
    CodexExecutor,
]

__all__ = [
    "AgentStatus",
    "ExecutionResult",
    "Executor",
    "CommandExecutor",
    "ClaudeExecutor",
    "CodexExecutor",
    "ALL_EXECUTORS",
]
