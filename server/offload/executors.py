from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Protocol


@dataclass
class ExecutionResult:
    summary: str
    exit_code: int
    stdout: str
    stderr: str
    artifacts: Dict[str, str]
    error: Optional[str] = None


class Executor(Protocol):
    name: str

    def execute(self, topic_path: Path, command: Optional[List[str]] = None) -> ExecutionResult:
        ...


class CommandExecutor:
    name = "command"

    def execute(self, topic_path: Path, command: Optional[List[str]] = None) -> ExecutionResult:
        resolved_command = list(command or ["/usr/bin/printf", "No command provided. Topic workspace is ready.\n"])
        completed = subprocess.run(
            resolved_command,
            cwd=topic_path,
            capture_output=True,
            text=True,
            check=False,
        )
        success = completed.returncode == 0
        artifacts = {
            "artifacts/latest/stdout.log": completed.stdout,
            "artifacts/latest/stderr.log": completed.stderr,
        }
        summary = "Command executor finished successfully." if success else "Command executor failed."
        error = None if success else f"Command exited with status {completed.returncode}."
        return ExecutionResult(
            summary=summary,
            exit_code=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
            artifacts=artifacts,
            error=error,
        )

