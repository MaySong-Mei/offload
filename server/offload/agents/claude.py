"""Claude Code executor — runs Anthropic's Claude CLI agent."""
from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from ._base import (
    AgentStatus,
    ExecutionResult,
    append_reporting_instructions,
    build_prompt_from_docs,
    check_cli_available,
    prepend_project_context,
    resolve_workspace,
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

        # Build CLI args with streaming and optional session resume
        cmd = ["claude"]
        resume_session_id = context.get("resume_session_id")
        if resume_session_id:
            cmd.extend(["--resume", resume_session_id])
        cmd.extend(["-p", prompt, "--output-format", "stream-json",
                    "--verbose", "--dangerously-skip-permissions"])

        on_stream: Optional[Callable] = context.get("on_stream")

        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                cwd=workspace_dir,
            )
            result_text = ""
            stdout_lines: List[str] = []
            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue
                stdout_lines.append(line)
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue

                # Forward stream events via callback
                if on_stream:
                    # Callback expects (topic_id, stage, event) but we don't have topic_id here;
                    # the service wraps this so the callback is already bound to the right topic.
                    on_stream("", "execution", event)

                if event.get("type") == "result":
                    result_text = event.get("result", "")

            proc.wait(timeout=self.timeout)
            stderr_text = proc.stderr.read() if proc.stderr else ""
            exit_code = proc.returncode

            success = exit_code == 0
            stdout_full = "\n".join(stdout_lines)
            return ExecutionResult(
                summary="Claude agent finished successfully." if success else "Claude agent failed.",
                exit_code=exit_code,
                stdout=result_text or stdout_full,
                stderr=stderr_text,
                artifacts={
                    "artifacts/latest/stdout.log": result_text or stdout_full,
                    "artifacts/latest/stderr.log": stderr_text,
                },
                error=None if success else f"Claude agent exited with status {exit_code}.",
            )
        except FileNotFoundError:
            return ExecutionResult(
                summary="Claude agent CLI not found.",
                exit_code=127,
                stdout="",
                stderr="claude: command not found",
                artifacts={},
                error="Claude agent CLI binary not found in PATH.",
            )
        except subprocess.TimeoutExpired:
            proc.kill()
            return ExecutionResult(
                summary=f"Claude agent timed out after {self.timeout}s.",
                exit_code=124,
                stdout="",
                stderr=f"Process exceeded {self.timeout}s timeout.",
                artifacts={},
                error=f"Timeout after {self.timeout} seconds.",
            )
