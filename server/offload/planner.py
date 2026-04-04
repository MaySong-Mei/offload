from __future__ import annotations

import textwrap
import uuid
from typing import Dict, Optional

from .models import FeedbackRequest, FeedbackRequestType, TopicState


class TopicPlanner:
    def initial_documents(self, state: TopicState) -> Dict[str, str]:
        requirement = self.render_requirement(state)
        plan = self.render_plan(state, requirement)
        notes = textwrap.dedent(
            f"""
            # Notes

            ## Raw Intake

            {state.raw_input.strip()}
            """
        ).strip()
        topic = textwrap.dedent(
            f"""
            # {state.title}

            - Topic ID: `{state.topic_id}`
            - Requirement State: `{state.requirement_state.value}`
            - Execution State: `{state.execution_state.value}`
            - Decision State: `{state.decision_state.value}`
            - Tags: {", ".join(state.tags) if state.tags else "none"}

            {state.summary}
            """
        ).strip()
        return {
            "topic.md": topic,
            "requirement.md": requirement,
            "plan.md": plan,
            "notes.md": notes,
        }

    def render_requirement(self, state: TopicState, extra_note: Optional[str] = None) -> str:
        note_line = extra_note.strip() if extra_note else "Pending clarification from the human controller."
        return textwrap.dedent(
            f"""
            # Requirement Snapshot

            ## Goal

            {state.raw_input.strip()}

            ## Current Understanding

            {state.summary}

            ## In Scope

            - Turn the topic into a structured, trackable work item.
            - Capture human feedback asynchronously.
            - Prepare for manual execution approval.

            ## Out Of Scope

            - Auto-implementation without human approval.
            - Unbounded executor autonomy.

            ## Success Criteria

            - Requirement snapshot is clear enough for implementation.
            - Human can explicitly approve the requirement.
            - Plan can be produced and reviewed separately.

            ## Open Questions

            - What is missing or ambiguous in the current scope?
            - What should the first implementation slice exclude?

            ## Latest Clarification

            {note_line}
            """
        ).strip()

    def render_plan(self, state: TopicState, requirement_markdown: str) -> str:
        requirement_summary = state.summary.strip()
        return textwrap.dedent(
            f"""
            # Implementation Plan

            ## Approach

            - Keep the topic in discussion until both requirement and plan are approved.
            - Use the workspace files as the agent-readable source of truth.
            - Trigger implementation manually through a run.

            ## First Slice

            - Normalize the topic into stable documents.
            - Collect and store feedback requests and responses.
            - Expose status, approvals, and run control through the client.

            ## Tests

            - Topic creation persists all core files and indexes.
            - Approval gates prevent execution before both approvals.
            - Run artifacts are written back into the topic workspace.

            ## Risks

            - Requirement drift if notes are not folded back into the snapshot.
            - Plan drift if execution occurs before refresh.

            ## Working Summary

            {requirement_summary}
            """
        ).strip()

    def requirement_feedback_request(self, topic_id: str) -> FeedbackRequest:
        return FeedbackRequest(
            request_id=f"fr-{uuid.uuid4().hex[:12]}",
            topic_id=topic_id,
            request_type=FeedbackRequestType.CONFIRM_REQUIREMENT,
            title="Confirm requirement snapshot",
            prompt="Review the requirement snapshot. Add missing scope or reject it before implementation planning continues.",
            options=["Looks right", "Needs changes"],
            metadata={"approval_stage": "requirement"},
        )

    def plan_feedback_request(self, topic_id: str) -> FeedbackRequest:
        return FeedbackRequest(
            request_id=f"fr-{uuid.uuid4().hex[:12]}",
            topic_id=topic_id,
            request_type=FeedbackRequestType.CONFIRM_PLAN,
            title="Confirm implementation plan",
            prompt="Review the implementation plan. Approve it only when the scope and test strategy match the requirement snapshot.",
            options=["Approve plan", "Needs changes"],
            metadata={"approval_stage": "plan"},
        )

