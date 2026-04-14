"""Topic planner — starts Claude sessions that operate on .offload/ data objects.

The planner doesn't parse Claude's output. Instead, Claude writes directly to
.offload/topics/<id>/ files (requirement.md, plan.md, etc.). The planner just
constructs the right prompt and streams the session to iOS.
"""
from __future__ import annotations

import json
import subprocess
import uuid
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from .models import FeedbackRequest, FeedbackRequestType, TopicState

# Callback type: (topic_id, stage, event_dict) -> None
StreamCallback = Optional[Callable[[str, str, Dict[str, Any]], None]]

# System prompt template
_SYSTEM_PROMPT_PATH = Path(__file__).parent / "templates" / "system.md"


class TopicPlanner:
    """Manages Claude sessions that operate on .offload/ topic data objects."""

    def __init__(self):
        self._system_prompt: Optional[str] = None

    @property
    def system_prompt(self) -> str:
        if self._system_prompt is None:
            if _SYSTEM_PROMPT_PATH.is_file():
                self._system_prompt = _SYSTEM_PROMPT_PATH.read_text()
            else:
                self._system_prompt = "You are an Offload agent. Read .offload/ files for context."
        return self._system_prompt

    # --- Initial document scaffolding (before first agent session) ---

    def initial_documents(self, state: TopicState, shared_context: Optional[str] = None) -> Dict[str, str]:
        """Create minimal scaffolding files for a new topic."""
        parent_line = f"- Parent Topic: `{state.parent_topic_id}`" if state.parent_topic_id else "- Parent Topic: none"
        topic = f"""# {state.title}

- Topic ID: `{state.topic_id}`
{parent_line}
- Tags: {", ".join(state.tags) if state.tags else "none"}

{state.summary}"""

        notes = f"""# Notes

## Raw Intake

{state.raw_input.strip()}"""
        if shared_context:
            notes += f"\n\n## Shared Context\n\n{shared_context}"

        requirement = f"""# Requirement

## User Request

{state.raw_input.strip()}

## Status

Pending — agent will analyze and write structured requirement after discussing with user."""

        plan = "# Implementation Plan\n\nPending — requirement must be confirmed first."

        return {
            "topic.md": topic,
            "requirement.md": requirement,
            "plan.md": plan,
            "notes.md": notes,
        }

    # --- Agent sessions ---

    def run_clarification(
        self,
        state: TopicState,
        project_context: Optional[Dict[str, str]] = None,
        on_stream: StreamCallback = None,
        project_path: Optional[str] = None,
    ) -> Optional[str]:
        """Run a Claude session for Phase 1: understand the user's request.

        Claude reads the project, asks questions, and writes requirement.md.
        Returns the text result (or None if failed).
        """
        topic_dir = state.workspace_path
        context_block = self._format_project_context(project_context)

        prompt = f"""{self.system_prompt}

---

# Current Task

You are in Phase 1 (Understand). The user has submitted a new task.

Topic directory: `{topic_dir}`

{context_block}

## User's Request

{state.raw_input}

## What To Do

1. Read relevant project files to understand the current state related to this request
2. If anything is ambiguous, explain what you found and what you need to know
3. When you have enough understanding, write a structured `requirement.md` to `{topic_dir}/requirement.md`

Use the format:
```
# Requirement

## Goal
One paragraph.

## Scope
- What's in scope

## Out of Scope
- What's NOT included

## Success Criteria
- How to verify this is done

## Technical Notes
Specific files, current values, implementation hints.
```

After writing requirement.md, update `{topic_dir}/notes.md` with a summary of what you learned.

Remember: write requirement.md and STOP. Do not make code changes."""

        return self._run_claude(
            prompt, cwd=project_path,
            topic_id=state.topic_id, stage="clarification",
            on_stream=on_stream,
        )

    def run_planning(
        self,
        state: TopicState,
        requirement_md: str,
        project_context: Optional[Dict[str, str]] = None,
        on_stream: StreamCallback = None,
        project_path: Optional[str] = None,
        revision_note: str = "",
    ) -> Optional[str]:
        """Run a Claude session for Phase 2: generate implementation plan.

        Claude reads the confirmed requirement and writes plan.md.
        """
        topic_dir = state.workspace_path
        context_block = self._format_project_context(project_context)
        revision_block = ""
        if revision_note:
            revision_block = f"\n## User's Revision Notes\n\n{revision_note}\n"

        prompt = f"""{self.system_prompt}

---

# Current Task

You are in Phase 2 (Plan). The requirement has been confirmed by the user.

Topic directory: `{topic_dir}`

{context_block}

## Confirmed Requirement

{requirement_md}
{revision_block}

## What To Do

1. Read the project files referenced in the requirement
2. Write a detailed implementation plan to `{topic_dir}/plan.md`

Use the format:
```
# Implementation Plan

## Approach
One paragraph strategy.

## Steps
1. Step one — specific file, specific change
2. Step two — ...

## Files to Change
- `path/to/file` — what changes

## Testing
- How to verify

## Risks
- What could go wrong
```

After writing plan.md, update `{topic_dir}/notes.md` with planning decisions.

Remember: write plan.md and STOP. Do not make code changes yet."""

        return self._run_claude(
            prompt, cwd=project_path,
            topic_id=state.topic_id, stage="planning",
            on_stream=on_stream,
        )

    # --- Feedback requests (still needed for the mobile GUI gate) ---

    def requirement_feedback_request(self, topic_id: str) -> FeedbackRequest:
        return FeedbackRequest(
            request_id=f"fr-{uuid.uuid4().hex[:12]}",
            topic_id=topic_id,
            request_type=FeedbackRequestType.CONFIRM_REQUIREMENT,
            title="Review requirement",
            prompt="The agent has written a requirement document. Review it and confirm or request changes.",
            options=["Looks good, proceed to plan", "Needs changes"],
            metadata={"approval_stage": "requirement"},
        )

    def plan_feedback_request(self, topic_id: str) -> FeedbackRequest:
        return FeedbackRequest(
            request_id=f"fr-{uuid.uuid4().hex[:12]}",
            topic_id=topic_id,
            request_type=FeedbackRequestType.CONFIRM_PLAN,
            title="Review plan",
            prompt="The agent has written an implementation plan. Approve to execute or request changes.",
            options=["Approve, start execution", "Needs changes"],
            metadata={"approval_stage": "plan"},
        )

    # --- Private ---

    def _format_project_context(self, project_context: Optional[Dict[str, str]]) -> str:
        if not project_context:
            return ""
        parts = []
        for name in ["summary.md", "architecture.md", "conventions.md"]:
            content = project_context.get(name, "").strip()
            if content:
                parts.append(f"## {name}\n{content[:2000]}")
        if not parts:
            return ""
        return "## Project Context\n\n" + "\n\n".join(parts)

    @staticmethod
    def _run_claude(
        prompt: str,
        cwd: Optional[str] = None,
        topic_id: str = "",
        stage: str = "",
        on_stream: StreamCallback = None,
        timeout: int = 180,
    ) -> Optional[str]:
        """Run a Claude CLI session with stream-json output.

        Streams structured events to iOS via callback.
        Returns the final text result.
        """
        try:
            proc = subprocess.Popen(
                ["claude", "-p", prompt, "--output-format", "stream-json",
                 "--verbose", "--dangerously-skip-permissions"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                cwd=cwd,
            )
            result_text = None
            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue

                if on_stream and topic_id:
                    on_stream(topic_id, stage, event)

                if event.get("type") == "result":
                    result_text = event.get("result", "")

            proc.wait(timeout=timeout)
            return result_text.strip() if result_text else None
        except FileNotFoundError:
            return None
        except subprocess.TimeoutExpired:
            proc.kill()
            return None
