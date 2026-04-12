"""Claude Code executor — runs Anthropic's Claude CLI agent."""
from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List, Optional

from ._base import (
    AgentStatus,
    ExecutionResult,
    append_reporting_instructions,
    build_prompt_from_docs,
    check_cli_available,
    prepend_project_context,
    resolve_workspace,
    run_cli,
)


class ClaudeExecutor:
    name = "claude"
    timeout = 600

    def check_status(self) -> AgentStatus:
        def _check_auth() -> str:
            config_dir = Path.home() / ".claude"
            return "authenticated" if config_dir.is_dir() else "needs_login"

        return check_cli_available(
            version_args=["claude", "--version"],
            name="claude",
            display_name="Claude Code",
            install_hint="npm i -g @anthropic-ai/claude-code",
            auth_check=_check_auth,
        )

    def execute(
        self,
        topic_path: Path,
        command: Optional[List[str]] = None,
        context: Optional[Dict[str, Any]] = None,
    ) -> ExecutionResult:
        context = context or {}

        # Build prompt
        if command:
            prompt = " ".join(command)
        else:
            prompt = build_prompt_from_docs(topic_path)

        # Prepend project-level context
        project_context = context.get("project_context", {})
        if project_context:
            prompt = prepend_project_context(project_context, prompt)

        # Append reporting instructions
        report_path = context.get("report_path")
        if report_path:
            prompt = append_reporting_instructions(prompt, report_path)

        workspace_dir = resolve_workspace(topic_path, context)

        return run_cli(
            args=["claude", "-p", prompt, "--output-format", "text", "--dangerously-skip-permissions"],
            cwd=workspace_dir,
            timeout=self.timeout,
            cli_name="Claude agent",
        )
