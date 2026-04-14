from __future__ import annotations

import json
import subprocess
import textwrap
import uuid
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from .models import FeedbackRequest, FeedbackRequestType, TopicState

# Callback type: (topic_id, stage, chunk_text) -> None
StreamCallback = Optional[Callable[[str, str, str], None]]


class TopicPlanner:
    """Generates documents and feedback requests for topics.

    When Claude CLI is available, uses it for intelligent requirement
    clarification and plan generation. Falls back to templates otherwise.
    """

    # --- Document generation (templates — used as initial scaffolding) ---

    def initial_documents(self, state: TopicState, shared_context: Optional[str] = None) -> Dict[str, str]:
        parent_line = f"- Parent Topic: `{state.parent_topic_id}`" if state.parent_topic_id else "- Parent Topic: none"
        notes = textwrap.dedent(f"""
            # Notes

            ## Raw Intake

            {state.raw_input.strip()}
        """).strip()
        if shared_context:
            notes += textwrap.dedent(f"""

                ## Shared Context

                {shared_context}
            """).rstrip()
        topic = textwrap.dedent(f"""
            # {state.title}

            - Topic ID: `{state.topic_id}`
            {parent_line}
            - Requirement State: `{state.requirement_state.value}`
            - Execution State: `{state.execution_state.value}`
            - Decision State: `{state.decision_state.value}`
            - Tags: {", ".join(state.tags) if state.tags else "none"}

            {state.summary}
        """).strip()
        # Minimal requirement — will be refined by agent clarification
        requirement = textwrap.dedent(f"""
            # Requirement

            ## User Request

            {state.raw_input.strip()}

            ## Status

            Awaiting clarification from agent before detailed requirement can be written.
        """).strip()
        # Plan is empty until requirement is approved
        plan = "# Implementation Plan\n\nPending — requirement must be approved first."
        return {
            "topic.md": topic,
            "requirement.md": requirement,
            "plan.md": plan,
            "notes.md": notes,
        }

    # --- Agent-powered clarification ---

    def generate_clarifying_questions(
        self,
        state: TopicState,
        project_context: Optional[Dict[str, str]] = None,
        on_stream: StreamCallback = None,
        project_path: Optional[str] = None,
    ) -> List[FeedbackRequest]:
        """Use Claude to analyze the raw input and generate clarifying questions.

        Returns a list of FeedbackRequests with GUI-friendly options.
        Falls back to a generic confirmation if Claude is unavailable.
        """
        context_block = ""
        if project_context:
            parts = []
            for name in ["summary.md", "architecture.md"]:
                content = project_context.get(name, "").strip()
                if content:
                    parts.append(f"## {name}\n{content[:1000]}")
            if parts:
                context_block = "Project context:\n" + "\n\n".join(parts)

        prompt = f"""You are a requirements analyst for a software project. A user has submitted a task request from their phone. You are running inside the project directory and CAN read files to understand the current state.

{context_block}

User's request: "{state.raw_input}"

IMPORTANT: Before generating questions, READ the relevant project files to understand the current state. For example, if the user mentions version numbers, read the actual config files to find current values. Use specific, concrete information from the codebase in your questions and options.

Respond with a JSON array of 1-3 clarifying questions. Each question must have:
- "title": short question title (shown as section header on phone)
- "prompt": the full question text (include current values you found in files)
- "options": array of 2-4 concrete answer choices the user can tap
- "allow_note": boolean, true if the user might want to type additional context

Rules:
- Options must be concrete and specific (include actual values from the codebase)
- If the request is already perfectly clear, return a single confirmation question
- Return ONLY valid JSON array, no markdown fencing, no explanation before/after"""

        questions = self._call_claude(prompt, topic_id=state.topic_id, stage="clarification", on_stream=on_stream, cwd=project_path)
        if questions is None:
            # Fallback: generic confirmation
            return [self._fallback_requirement_request(state.topic_id)]

        requests = []
        for i, q in enumerate(questions):
            requests.append(FeedbackRequest(
                request_id=f"fr-{uuid.uuid4().hex[:12]}",
                topic_id=state.topic_id,
                request_type=FeedbackRequestType.CHOOSE_ONE,
                title=q.get("title", f"Question {i+1}"),
                prompt=q.get("prompt", ""),
                options=q.get("options", ["Yes", "No"]),
                allow_note=q.get("allow_note", True),
                metadata={"stage": "clarification", "question_index": i},
            ))
        return requests

    def generate_requirement_doc(
        self,
        state: TopicState,
        feedback_history: List[Dict[str, Any]],
        project_context: Optional[Dict[str, str]] = None,
        on_stream: StreamCallback = None,
        project_path: Optional[str] = None,
    ) -> Optional[str]:
        """Use Claude to write a structured requirement based on the user's input + feedback answers."""
        context_block = ""
        if project_context:
            for name in ["summary.md", "architecture.md"]:
                content = project_context.get(name, "").strip()
                if content:
                    context_block += f"\n## {name}\n{content[:1000]}\n"

        feedback_block = ""
        for fb in feedback_history:
            feedback_block += f"\nQ: {fb.get('title', '')}: {fb.get('prompt', '')}\n"
            feedback_block += f"A: {', '.join(fb.get('selected_options', []))}"
            if fb.get('note'):
                feedback_block += f" — {fb['note']}"
            feedback_block += "\n"

        prompt = f"""Write a structured requirement document for a software task.

Original request: "{state.raw_input}"

Clarification Q&A:
{feedback_block}

{context_block}

Write the requirement in this markdown format:

# Requirement

## Goal
One paragraph describing what needs to be done.

## Scope
- Bullet list of what's in scope

## Out of Scope
- What this does NOT include

## Success Criteria
- How to verify this is done correctly

## Technical Notes
Any implementation hints based on the project context.

Be concise and specific. Write ONLY the markdown document, no preamble."""

        result = self._call_claude_text(prompt, topic_id=state.topic_id, stage="requirement", on_stream=on_stream, cwd=project_path)
        return result

    def generate_plan_doc(
        self,
        state: TopicState,
        requirement_md: str,
        project_context: Optional[Dict[str, str]] = None,
        on_stream: StreamCallback = None,
        project_path: Optional[str] = None,
    ) -> Optional[str]:
        """Use Claude to generate an implementation plan based on the approved requirement."""
        context_block = ""
        if project_context:
            for name in ["summary.md", "architecture.md", "conventions.md"]:
                content = project_context.get(name, "").strip()
                if content:
                    context_block += f"\n## {name}\n{content[:1500]}\n"

        prompt = f"""Write an implementation plan for the following approved requirement.

{requirement_md}

Project context:
{context_block}

Write the plan in this markdown format:

# Implementation Plan

## Approach
One paragraph describing the strategy.

## Steps
1. Step one — what to do and which files to touch
2. Step two — ...
(be specific about file paths, function names, etc.)

## Files to Change
- `path/to/file.ext` — what changes and why

## Testing
- How to verify each step worked

## Risks
- Anything that could go wrong

Be specific and actionable. An agent will follow this plan to implement the changes.
Write ONLY the markdown document, no preamble."""

        result = self._call_claude_text(prompt, topic_id=state.topic_id, stage="planning", on_stream=on_stream, cwd=project_path)
        return result

    # --- Feedback request constructors ---

    def requirement_feedback_request(self, topic_id: str) -> FeedbackRequest:
        return FeedbackRequest(
            request_id=f"fr-{uuid.uuid4().hex[:12]}",
            topic_id=topic_id,
            request_type=FeedbackRequestType.CONFIRM_REQUIREMENT,
            title="Confirm requirement",
            prompt="Review the requirement document. Is it ready for planning?",
            options=["Looks good, proceed to plan", "Needs changes"],
            metadata={"approval_stage": "requirement"},
        )

    def plan_feedback_request(self, topic_id: str) -> FeedbackRequest:
        return FeedbackRequest(
            request_id=f"fr-{uuid.uuid4().hex[:12]}",
            topic_id=topic_id,
            request_type=FeedbackRequestType.CONFIRM_PLAN,
            title="Confirm plan",
            prompt="Review the implementation plan. Ready to execute?",
            options=["Approve, start execution", "Needs changes"],
            metadata={"approval_stage": "plan"},
        )

    # --- Private: Claude CLI integration ---

    def _call_claude(
        self,
        prompt: str,
        topic_id: str = "",
        stage: str = "",
        on_stream: StreamCallback = None,
        cwd: Optional[str] = None,
    ) -> Optional[List[Dict[str, Any]]]:
        """Call Claude CLI and parse JSON array response."""
        text = self._call_claude_text(prompt, topic_id=topic_id, stage=stage, on_stream=on_stream, cwd=cwd)
        if text is None:
            return None
        # Strip markdown code fences if present
        text = text.strip()
        if text.startswith("```"):
            lines = text.splitlines()
            text = "\n".join(lines[1:-1] if lines[-1].strip() == "```" else lines[1:])
        try:
            result = json.loads(text)
            if isinstance(result, list):
                return result
            return None
        except json.JSONDecodeError:
            return None

    @staticmethod
    def _call_claude_text(
        prompt: str,
        timeout: int = 120,
        topic_id: str = "",
        stage: str = "",
        on_stream: StreamCallback = None,
        cwd: Optional[str] = None,
    ) -> Optional[str]:
        """Call Claude CLI and stream output line-by-line via callback.

        If on_stream is provided, each line of stdout is pushed in real-time
        as an event to the iOS client. The full output is still returned.
        If cwd is set, Claude runs in that directory with file access.
        """
        try:
            proc = subprocess.Popen(
                ["claude", "-p", prompt, "--output-format", "text"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                cwd=cwd,
            )
            collected: list[str] = []
            for line in proc.stdout:
                collected.append(line)
                if on_stream and topic_id:
                    on_stream(topic_id, stage, line)
            proc.wait(timeout=timeout)
            full_text = "".join(collected).strip()
            if proc.returncode == 0 and full_text:
                return full_text
            return None
        except FileNotFoundError:
            return None
        except subprocess.TimeoutExpired:
            proc.kill()
            return None

    @staticmethod
    def _fallback_requirement_request(topic_id: str) -> FeedbackRequest:
        """Generic fallback when Claude is unavailable."""
        return FeedbackRequest(
            request_id=f"fr-{uuid.uuid4().hex[:12]}",
            topic_id=topic_id,
            request_type=FeedbackRequestType.CONFIRM_REQUIREMENT,
            title="Confirm requirement snapshot",
            prompt="Review the requirement. Add any missing details or approve to proceed.",
            options=["Looks right", "Needs changes"],
            metadata={"approval_stage": "requirement"},
        )
