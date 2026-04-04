from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Any, Dict, List, Optional


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


class StrEnum(str, Enum):
    def __str__(self) -> str:
        return self.value


class RequirementState(StrEnum):
    CAPTURED = "captured"
    CLARIFYING = "clarifying"
    DISCUSSED = "discussed"
    SPECIFIED = "specified"
    APPROVED = "approved"


class ExecutionState(StrEnum):
    IDLE = "idle"
    QUEUED = "queued"
    IMPLEMENTING = "implementing"
    IMPLEMENTED = "implemented"
    HUMAN_TESTING = "human_testing"
    PASSED = "passed"
    FAILED = "failed"
    PAUSED = "paused"


class DecisionState(StrEnum):
    NONE = "none"
    NEEDS_FEEDBACK = "needs_feedback"
    BLOCKED = "blocked"
    PENDING_IMPLEMENTATION = "pending_implementation"
    ARCHIVED = "archived"


class FeedbackRequestType(StrEnum):
    CHOOSE_ONE = "choose_one"
    CHOOSE_MANY = "choose_many"
    APPROVE_REJECT = "approve_reject"
    ADD_NOTE = "add_note"
    CONFIRM_REQUIREMENT = "confirm_requirement"
    CONFIRM_PLAN = "confirm_plan"


class FeedbackRequestStatus(StrEnum):
    PENDING = "pending"
    RESOLVED = "resolved"
    DISMISSED = "dismissed"


class RunStatus(StrEnum):
    QUEUED = "queued"
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"


@dataclass
class TopicState:
    topic_id: str
    title: str
    summary: str
    raw_input: str
    tags: List[str] = field(default_factory=list)
    priority: str = "normal"
    project: Optional[str] = None
    created_at: str = field(default_factory=utc_now)
    updated_at: str = field(default_factory=utc_now)
    requirement_state: RequirementState = RequirementState.CLARIFYING
    execution_state: ExecutionState = ExecutionState.IDLE
    decision_state: DecisionState = DecisionState.NEEDS_FEEDBACK
    requirement_approved_at: Optional[str] = None
    plan_approved_at: Optional[str] = None
    latest_run_id: Optional[str] = None
    pending_feedback_request_id: Optional[str] = None
    assigned_executor: Optional[str] = None
    workspace_path: str = ""

    def to_json_dict(self) -> Dict[str, Any]:
        return {
            "topic_id": self.topic_id,
            "title": self.title,
            "summary": self.summary,
            "raw_input": self.raw_input,
            "tags": self.tags,
            "priority": self.priority,
            "project": self.project,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "requirement_state": self.requirement_state.value,
            "execution_state": self.execution_state.value,
            "decision_state": self.decision_state.value,
            "requirement_approved_at": self.requirement_approved_at,
            "plan_approved_at": self.plan_approved_at,
            "latest_run_id": self.latest_run_id,
            "pending_feedback_request_id": self.pending_feedback_request_id,
            "assigned_executor": self.assigned_executor,
            "workspace_path": self.workspace_path,
        }

    @classmethod
    def from_json_dict(cls, payload: Dict[str, Any]) -> "TopicState":
        return cls(
            topic_id=payload["topic_id"],
            title=payload["title"],
            summary=payload.get("summary", ""),
            raw_input=payload.get("raw_input", ""),
            tags=list(payload.get("tags", [])),
            priority=payload.get("priority", "normal"),
            project=payload.get("project"),
            created_at=payload.get("created_at", utc_now()),
            updated_at=payload.get("updated_at", utc_now()),
            requirement_state=RequirementState(payload.get("requirement_state", RequirementState.CLARIFYING.value)),
            execution_state=ExecutionState(payload.get("execution_state", ExecutionState.IDLE.value)),
            decision_state=DecisionState(payload.get("decision_state", DecisionState.NEEDS_FEEDBACK.value)),
            requirement_approved_at=payload.get("requirement_approved_at"),
            plan_approved_at=payload.get("plan_approved_at"),
            latest_run_id=payload.get("latest_run_id"),
            pending_feedback_request_id=payload.get("pending_feedback_request_id"),
            assigned_executor=payload.get("assigned_executor"),
            workspace_path=payload.get("workspace_path", ""),
        )


@dataclass
class FeedbackRequest:
    request_id: str
    topic_id: str
    request_type: FeedbackRequestType
    title: str
    prompt: str
    options: List[str] = field(default_factory=list)
    status: FeedbackRequestStatus = FeedbackRequestStatus.PENDING
    created_at: str = field(default_factory=utc_now)
    resolved_at: Optional[str] = None
    allow_note: bool = True
    metadata: Dict[str, Any] = field(default_factory=dict)

    def to_json_dict(self) -> Dict[str, Any]:
        return {
            "request_id": self.request_id,
            "topic_id": self.topic_id,
            "request_type": self.request_type.value,
            "title": self.title,
            "prompt": self.prompt,
            "options": self.options,
            "status": self.status.value,
            "created_at": self.created_at,
            "resolved_at": self.resolved_at,
            "allow_note": self.allow_note,
            "metadata": self.metadata,
        }

    @classmethod
    def from_json_dict(cls, payload: Dict[str, Any]) -> "FeedbackRequest":
        return cls(
            request_id=payload["request_id"],
            topic_id=payload["topic_id"],
            request_type=FeedbackRequestType(payload["request_type"]),
            title=payload["title"],
            prompt=payload["prompt"],
            options=list(payload.get("options", [])),
            status=FeedbackRequestStatus(payload.get("status", FeedbackRequestStatus.PENDING.value)),
            created_at=payload.get("created_at", utc_now()),
            resolved_at=payload.get("resolved_at"),
            allow_note=bool(payload.get("allow_note", True)),
            metadata=dict(payload.get("metadata", {})),
        )


@dataclass
class FeedbackResponse:
    response_id: str
    request_id: str
    topic_id: str
    selected_options: List[str] = field(default_factory=list)
    note: str = ""
    actor: str = "human"
    created_at: str = field(default_factory=utc_now)

    def to_json_dict(self) -> Dict[str, Any]:
        return {
            "response_id": self.response_id,
            "request_id": self.request_id,
            "topic_id": self.topic_id,
            "selected_options": self.selected_options,
            "note": self.note,
            "actor": self.actor,
            "created_at": self.created_at,
        }

    @classmethod
    def from_json_dict(cls, payload: Dict[str, Any]) -> "FeedbackResponse":
        return cls(
            response_id=payload["response_id"],
            request_id=payload["request_id"],
            topic_id=payload["topic_id"],
            selected_options=list(payload.get("selected_options", [])),
            note=payload.get("note", ""),
            actor=payload.get("actor", "human"),
            created_at=payload.get("created_at", utc_now()),
        )


@dataclass
class RunRecord:
    run_id: str
    topic_id: str
    executor: str
    status: RunStatus
    created_at: str = field(default_factory=utc_now)
    updated_at: str = field(default_factory=utc_now)
    finished_at: Optional[str] = None
    summary: str = ""
    command: List[str] = field(default_factory=list)
    artifacts: List[str] = field(default_factory=list)
    exit_code: Optional[int] = None
    error: Optional[str] = None

    def to_json_dict(self) -> Dict[str, Any]:
        return {
            "run_id": self.run_id,
            "topic_id": self.topic_id,
            "executor": self.executor,
            "status": self.status.value,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "finished_at": self.finished_at,
            "summary": self.summary,
            "command": self.command,
            "artifacts": self.artifacts,
            "exit_code": self.exit_code,
            "error": self.error,
        }

    @classmethod
    def from_json_dict(cls, payload: Dict[str, Any]) -> "RunRecord":
        return cls(
            run_id=payload["run_id"],
            topic_id=payload["topic_id"],
            executor=payload["executor"],
            status=RunStatus(payload["status"]),
            created_at=payload.get("created_at", utc_now()),
            updated_at=payload.get("updated_at", utc_now()),
            finished_at=payload.get("finished_at"),
            summary=payload.get("summary", ""),
            command=list(payload.get("command", [])),
            artifacts=list(payload.get("artifacts", [])),
            exit_code=payload.get("exit_code"),
            error=payload.get("error"),
        )


@dataclass
class EventRecord:
    event_id: str
    event_type: str
    topic_id: Optional[str] = None
    run_id: Optional[str] = None
    created_at: str = field(default_factory=utc_now)
    payload: Dict[str, Any] = field(default_factory=dict)
    sequence: Optional[int] = None

    def to_json_dict(self) -> Dict[str, Any]:
        return {
            "sequence": self.sequence,
            "event_id": self.event_id,
            "event_type": self.event_type,
            "topic_id": self.topic_id,
            "run_id": self.run_id,
            "created_at": self.created_at,
            "payload": self.payload,
        }

    @classmethod
    def from_json_dict(cls, payload: Dict[str, Any]) -> "EventRecord":
        return cls(
            event_id=payload["event_id"],
            event_type=payload["event_type"],
            topic_id=payload.get("topic_id"),
            run_id=payload.get("run_id"),
            created_at=payload.get("created_at", utc_now()),
            payload=dict(payload.get("payload", {})),
            sequence=payload.get("sequence"),
        )

