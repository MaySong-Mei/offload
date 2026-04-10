from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Protocol


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

    def execute(
        self,
        topic_path: Path,
        command: Optional[List[str]] = None,
        context: Optional[Dict[str, Any]] = None,
    ) -> ExecutionResult:
        ...


class CommandExecutor:
    name = "command"

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


class ClaudeExecutor:
    name = "claude"
    timeout = 600

    def execute(
        self,
        topic_path: Path,
        command: Optional[List[str]] = None,
        context: Optional[Dict[str, Any]] = None,
    ) -> ExecutionResult:
        context = context or {}

        # Build prompt: user instruction or topic documents
        if command:
            prompt = " ".join(command)
        else:
            prompt = self._build_prompt_from_docs(topic_path)

        # Prepend project-level context (.offload/context/*.md) if available
        project_context = context.get("project_context", {})
        if project_context:
            prompt = self._prepend_project_context(project_context, prompt)

        # Working directory: project repo if available, else topic dir
        workspace_dir = topic_path
        wd = context.get("workspace_dir")
        if wd and Path(wd).is_dir():
            workspace_dir = Path(wd)

        try:
            completed = subprocess.run(
                ["claude", "-p", prompt, "--output-format", "text", "--dangerously-skip-permissions"],
                cwd=workspace_dir,
                capture_output=True,
                text=True,
                check=False,
                timeout=self.timeout,
            )
        except FileNotFoundError:
            return ExecutionResult(
                summary="Claude CLI not found. Install it with: npm install -g @anthropic-ai/claude-code",
                exit_code=127,
                stdout="",
                stderr="claude: command not found",
                artifacts={},
                error="Claude CLI binary not found in PATH.",
            )
        except subprocess.TimeoutExpired:
            return ExecutionResult(
                summary=f"Claude agent timed out after {self.timeout}s.",
                exit_code=124,
                stdout="",
                stderr=f"Process exceeded {self.timeout}s timeout.",
                artifacts={},
                error=f"Timeout after {self.timeout} seconds.",
            )

        success = completed.returncode == 0
        artifacts = {
            "artifacts/latest/stdout.log": completed.stdout,
            "artifacts/latest/stderr.log": completed.stderr,
        }
        summary = "Claude agent finished successfully." if success else "Claude agent failed."
        error = None if success else f"Claude exited with status {completed.returncode}."
        return ExecutionResult(
            summary=summary,
            exit_code=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
            artifacts=artifacts,
            error=error,
        )

    @staticmethod
    def _prepend_project_context(project_context: Dict[str, str], prompt: str) -> str:
        """Prepend .offload/context/*.md content as system-level project knowledge."""
        sections: List[str] = []
        # Order: summary first, then architecture, conventions, glossary
        for filename in ["summary.md", "architecture.md", "conventions.md", "glossary.md"]:
            content = project_context.get(filename, "").strip()
            if content:
                label = filename.replace(".md", "").replace("_", " ").title()
                sections.append(f"## Project {label}\n\n{content}")
        if not sections:
            return prompt
        header = (
            "# Project Context (from .offload/context/)\n"
            "The following is persistent knowledge about this repository. "
            "Use it to understand the codebase without re-reading everything.\n\n"
        )
        context_block = header + "\n\n---\n\n".join(sections)
        return f"{context_block}\n\n---\n\n# Your Task\n\n{prompt}"

    @staticmethod
    def _build_prompt_from_docs(topic_path: Path) -> str:
        parts: List[str] = []
        for filename, label in [("requirement.md", "Requirement"), ("plan.md", "Plan")]:
            doc = topic_path / filename
            if doc.exists():
                content = doc.read_text().strip()
                if content:
                    parts.append(f"## {label}\n\n{content}")
        if not parts:
            return "No requirement or plan documents found. Please describe what you want to build."
        return "\n\n---\n\n".join(parts)
