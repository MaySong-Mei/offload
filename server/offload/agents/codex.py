"""OpenAI Codex executor — runs the Codex CLI agent."""
from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List, Optional

from ._base import (
    AgentStatus,
    ExecutionResult,
    build_prompt_from_docs,
    check_cli_available,
    resolve_workspace,
    run_cli,
)


class CodexExecutor:
    name = "codex"
    timeout = 600

    def check_status(self) -> AgentStatus:
        return check_cli_available(
            version_args=["codex", "--version"],
            name="codex",
            display_name="OpenAI Codex",
            install_hint="npm i -g @openai/codex",
        )

    def execute(
        self,
        topic_path: Path,
        command: Optional[List[str]] = None,
        context: Optional[Dict[str, Any]] = None,
    ) -> ExecutionResult:
        context = context or {}

        if command:
            prompt = " ".join(command)
        else:
            prompt = build_prompt_from_docs(topic_path)

        workspace_dir = resolve_workspace(topic_path, context)

        return run_cli(
            args=["codex", "--quiet", "--full-auto", prompt],
            cwd=workspace_dir,
            timeout=self.timeout,
            cli_name="Codex agent",
        )
