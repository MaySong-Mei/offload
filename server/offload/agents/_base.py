"""Shared types and helpers for all agent executors."""
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


@dataclass
class AgentStatus:
    name: str
    display_name: str
    available: bool
    version: Optional[str] = None
    error: Optional[str] = None
    auth_status: Optional[str] = None  # "authenticated", "needs_login", "unknown"
    detail: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "display_name": self.display_name,
            "available": self.available,
            "version": self.version,
            "error": self.error,
            "auth_status": self.auth_status,
            "detail": self.detail,
        }


class Executor(Protocol):
    name: str

    def execute(
        self,
        topic_path: Path,
        command: Optional[List[str]] = None,
        context: Optional[Dict[str, Any]] = None,
    ) -> ExecutionResult:
        ...

    def check_status(self) -> AgentStatus:
        ...


# ---------------------------------------------------------------------------
# Shared prompt-building helpers (used by Claude, Codex, and future agents)
# ---------------------------------------------------------------------------

def build_prompt_from_docs(topic_path: Path) -> str:
    """Build a prompt by concatenating requirement.md and plan.md from a topic directory."""
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


def prepend_project_context(project_context: Dict[str, str], prompt: str) -> str:
    """Prepend .offload/context/*.md content as system-level project knowledge."""
    sections: List[str] = []
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


def append_reporting_instructions(prompt: str, report_path: str) -> str:
    """Append structured report-writing instructions to the prompt."""
    return prompt + f"""

---

# Reporting (REQUIRED)

After completing your work, you MUST write a brief structured report to:
`{report_path}`

The report should be markdown with this format:

```
# Run Report

## Summary
One-paragraph summary of what was done.

## Files Changed
- `path/to/file.py` — what changed and why
- `path/to/new_file.py` — (new) description

## Tests
Did you run tests? Results?

## Notes
Any caveats, follow-ups, or things the human reviewer should know.
```

This report is read by the Offload phone client to show the human controller
what you did. Be concise but specific. Write the report LAST, after all code
changes are complete.
"""


def resolve_workspace(topic_path: Path, context: Optional[Dict[str, Any]] = None) -> Path:
    """Return the working directory for execution: project repo if available, else topic dir."""
    if context:
        wd = context.get("workspace_dir")
        if wd and Path(wd).is_dir():
            return Path(wd)
    return topic_path


def run_cli(
    args: List[str],
    cwd: Path,
    timeout: int = 600,
    cli_name: str = "agent",
) -> ExecutionResult:
    """Run a CLI subprocess and return a standardized ExecutionResult.

    Handles FileNotFoundError and TimeoutExpired gracefully.
    """
    try:
        completed = subprocess.run(
            args,
            cwd=cwd,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
        )
    except FileNotFoundError:
        return ExecutionResult(
            summary=f"{cli_name} CLI not found.",
            exit_code=127,
            stdout="",
            stderr=f"{args[0]}: command not found",
            artifacts={},
            error=f"{cli_name} CLI binary not found in PATH.",
        )
    except subprocess.TimeoutExpired:
        return ExecutionResult(
            summary=f"{cli_name} timed out after {timeout}s.",
            exit_code=124,
            stdout="",
            stderr=f"Process exceeded {timeout}s timeout.",
            artifacts={},
            error=f"Timeout after {timeout} seconds.",
        )

    success = completed.returncode == 0
    return ExecutionResult(
        summary=f"{cli_name} finished successfully." if success else f"{cli_name} failed.",
        exit_code=completed.returncode,
        stdout=completed.stdout,
        stderr=completed.stderr,
        artifacts={
            "artifacts/latest/stdout.log": completed.stdout,
            "artifacts/latest/stderr.log": completed.stderr,
        },
        error=None if success else f"{cli_name} exited with status {completed.returncode}.",
    )


def check_cli_available(
    version_args: List[str],
    name: str,
    display_name: str,
    install_hint: str,
    auth_check: Optional[callable] = None,
) -> AgentStatus:
    """Probe whether a CLI tool is installed and optionally check auth."""
    try:
        result = subprocess.run(
            version_args,
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0:
            version = result.stdout.strip().splitlines()[0] if result.stdout.strip() else None
            auth_status = auth_check() if auth_check else "unknown"
            return AgentStatus(
                name=name,
                display_name=display_name,
                available=True,
                version=version,
                auth_status=auth_status,
                detail=f"{display_name} detected and ready.",
            )
        return AgentStatus(
            name=name, display_name=display_name,
            available=False, error=f"{name} exited with {result.returncode}",
        )
    except FileNotFoundError:
        return AgentStatus(
            name=name, display_name=display_name,
            available=False, error=f"{display_name} not found. Install: {install_hint}",
        )
    except Exception as e:
        return AgentStatus(name=name, display_name=display_name, available=False, error=str(e))
