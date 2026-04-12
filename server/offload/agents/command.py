"""Shell command executor — runs arbitrary commands on the server."""
from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional

from ._base import AgentStatus, ExecutionResult


class CommandExecutor:
    name = "command"

    def check_status(self) -> AgentStatus:
        return AgentStatus(
            name="command",
            display_name="Shell Command",
            available=True,
            auth_status="authenticated",
            detail="Runs arbitrary shell commands on the server.",
        )

    def execute(
        self,
        topic_path: Path,
        command: Optional[List[str]] = None,
        context: Optional[Dict[str, Any]] = None,
    ) -> ExecutionResult:
        resolved_command = list(command or ["/usr/bin/printf", "No command provided. Topic workspace is ready.\n"])
        completed = subprocess.run(
            resolved_command,
            cwd=topic_path,
            capture_output=True,
            text=True,
            check=False,
        )
        success = completed.returncode == 0
        return ExecutionResult(
            summary="Command executor finished successfully." if success else "Command executor failed.",
            exit_code=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
            artifacts={
                "artifacts/latest/stdout.log": completed.stdout,
                "artifacts/latest/stderr.log": completed.stderr,
            },
            error=None if success else f"Command exited with status {completed.returncode}.",
        )
