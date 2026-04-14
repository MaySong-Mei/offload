from __future__ import annotations

import json
import threading
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional

from .database import IndexStore
from .event_bus import EventBus
from .agents import ALL_EXECUTORS, Executor
from .models import (
    DecisionState,
    EventRecord,
    ExecutionState,
    FeedbackRequest,
    FeedbackRequestStatus,
    FeedbackRequestType,
    FeedbackResponse,
    RequirementState,
    RunRecord,
    RunStatus,
    TopicState,
    utc_now,
)
from .planner import TopicPlanner
from .repo_offload import RepoOffload
from .sensor_runner import SensorRunner
from .workspace import WorkspaceManager


class NotFoundError(Exception):
    pass


class ValidationError(Exception):
    pass


class HarnessService:
    def __init__(self, workspace_root: Path, project_paths: Optional[List[str]] = None):
        self.workspace_root = Path(workspace_root)
        self.workspace = WorkspaceManager(self.workspace_root)
        self.store = IndexStore(self.workspace_root / "offload.db")
        self.planner = TopicPlanner()
        self.event_bus = EventBus()
        self.executors: Dict[str, Executor] = {
            cls.name: cls() for cls in ALL_EXECUTORS
        }
        self._lock = threading.RLock()
        self._run_threads: Dict[str, threading.Thread] = {}
        self._project_paths = project_paths or []
        self.sensor_runner = SensorRunner(self.store, self.event_bus, self._project_paths)
        self.reindex()

    def start_sensors(self) -> None:
        """Start the sensor background scheduler. Call after server is ready."""
        self.sensor_runner.scan_and_register()
        self.sensor_runner.start()

    def close(self) -> None:
        self.sensor_runner.stop()
        threads = []
        with self._lock:
            threads = list(self._run_threads.values())
        for thread in threads:
            thread.join(timeout=5.0)
        self.store.close()

    # ---- Reindex + Migration ------------------------------------------------

    def reindex(self) -> None:
        with self._lock:
            # First: migrate any workspace topics that have a project field
            self._migrate_workspace_topics()

            # Then: index from all locations
            for topic_id, project in self.workspace.list_all_topic_ids(self._project_paths):
                try:
                    state = self.workspace.load_state(topic_id, project=project)
                    self.store.upsert_topic(state)
                    for name, payload in self.workspace.load_feedback_files(topic_id, project=project):
                        if payload.get("response_id"):
                            self.store.insert_feedback_response(FeedbackResponse.from_json_dict(payload))
                        elif payload.get("request_id"):
                            self.store.upsert_feedback_request(FeedbackRequest.from_json_dict(payload))
                    for run in self.workspace.load_runs(topic_id, project=project):
                        self.store.upsert_run(run)
                except Exception as e:
                    import sys
                    print(f"Warning: failed to reindex topic {topic_id}: {e}", file=sys.stderr)

    def _migrate_workspace_topics(self) -> None:
        """Move topics from server workspace to their repo's .offload/topics/ if they have a project."""
        import sys
        for topic_id in self.workspace.list_topic_ids():
            try:
                state = self.workspace.load_state(topic_id)
                if state.project and Path(state.project).is_dir():
                    if self.workspace.migrate_topic_to_repo(topic_id, state.project):
                        # Update workspace_path in the migrated state
                        new_path = str(Path(state.project) / ".offload" / "topics" / topic_id)
                        state.workspace_path = new_path
                        self.workspace.save_state(state)
                        print(f"Migrated topic {topic_id} → {new_path}", file=sys.stderr)
            except Exception as e:
                print(f"Warning: migration failed for topic {topic_id}: {e}", file=sys.stderr)

    # ---- Topic CRUD ---------------------------------------------------------

    def create_topic(
        self,
        title: str,
        raw_input: str,
        tags: Optional[List[str]] = None,
        priority: str = "normal",
        project: Optional[str] = None,
        parent_topic_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        with self._lock:
            now = utc_now()
            topic_id = f"topic-{uuid.uuid4().hex[:10]}"
            parent_state = None
            parent_tags: List[str] = []
            inherited_project = project
            shared_context = None
            if parent_topic_id:
                parent_state = self._require_topic(parent_topic_id)
                parent_tags = list(parent_state.tags)
                inherited_project = project if project is not None else parent_state.project
                shared_context = self._build_parent_context(parent_topic_id)
            summary = raw_input.strip().splitlines()[0][:180]
            # workspace_path now points to the per-repo location if project is set
            workspace_path = str(self.workspace.topic_dir(topic_id, project=inherited_project))
            state = TopicState(
                topic_id=topic_id,
                title=title.strip() or summary or "Untitled topic",
                summary=summary or "New topic captured from controller input.",
                raw_input=raw_input.strip(),
                parent_topic_id=parent_topic_id,
                tags=self._merge_tags(parent_tags, list(tags or [])),
                priority=priority,
                project=inherited_project,
                created_at=now,
                updated_at=now,
                requirement_state=RequirementState.CLARIFYING,
                execution_state=ExecutionState.IDLE,
                decision_state=DecisionState.NEEDS_FEEDBACK,
                workspace_path=workspace_path,
            )
            documents = self.planner.initial_documents(state, shared_context=shared_context)
            proj = state.project
            self.workspace.create_topic(state, documents)
            self.store.upsert_topic(state)
            topic_event_type = "topic.subtopic_created" if parent_topic_id else "topic.created"
            topic_event = self._record_event(
                topic_event_type,
                topic_id=topic_id,
                payload={"topic": state.to_json_dict(), "parent_topic_id": parent_topic_id},
            )
            self.event_bus.publish(topic_event)

            # Kick off async agent clarification
            project_context = self._load_project_context(proj)
            threading.Thread(
                target=self._run_clarification,
                args=(topic_id, state, project_context),
                daemon=True,
            ).start()

            return self.get_topic_detail(topic_id)

    def list_topics(self) -> List[Dict[str, Any]]:
        with self._lock:
            return [state.to_json_dict() for state in self.store.list_topics()]

    def list_feedback_queue(self) -> List[Dict[str, Any]]:
        with self._lock:
            return [request.to_json_dict() for request in self.store.list_feedback_requests(pending_only=True)]

    def get_topic_detail(self, topic_id: str) -> Dict[str, Any]:
        with self._lock:
            state = self._require_topic(topic_id)
            proj = state.project
            documents = self.workspace.load_documents(topic_id, project=proj)
            feedback_requests = [request.to_json_dict() for request in self.store.list_feedback_requests(topic_id=topic_id)]
            runs = [run.to_json_dict() for run in self.store.list_runs(topic_id)]
            artifacts = self.workspace.list_artifacts(topic_id, project=proj)
            parent_topic = self.store.get_topic(state.parent_topic_id) if state.parent_topic_id else None
            child_topics = [child.to_json_dict() for child in self.store.list_child_topics(topic_id)]
            return {
                "topic": state.to_json_dict(),
                "parent_topic": parent_topic.to_json_dict() if parent_topic else None,
                "child_topics": child_topics,
                "documents": documents,
                "feedback_requests": feedback_requests,
                "runs": runs,
                "artifacts": artifacts,
            }

    def list_runs(self, topic_id: str) -> List[Dict[str, Any]]:
        with self._lock:
            self._require_topic(topic_id)
            return [run.to_json_dict() for run in self.store.list_runs(topic_id)]

    def list_artifacts(self, topic_id: str) -> List[str]:
        with self._lock:
            state = self._require_topic(topic_id)
            return self.workspace.list_artifacts(topic_id, project=state.project)

    # ---- Requirement / Plan --------------------------------------------------

    def refresh_requirement(self, topic_id: str, note: str = "") -> Dict[str, Any]:
        with self._lock:
            state = self._require_topic(topic_id)
            self._ensure_not_archived(state)
            proj = state.project
            state.requirement_state = RequirementState.SPECIFIED
            state.decision_state = DecisionState.NEEDS_FEEDBACK
            state.requirement_approved_at = None
            state.updated_at = utc_now()
            requirement = self.planner.render_requirement(
                state,
                extra_note=note or None,
                shared_context=self._build_parent_context(state.parent_topic_id),
            )
            self.workspace.write_document(topic_id, "requirement.md", requirement, project=proj)
            self.workspace.append_note(topic_id, "Requirement Refresh", note or "Requirement snapshot regenerated.", project=proj)
            request = self.planner.requirement_feedback_request(topic_id)
            state.pending_feedback_request_id = request.request_id
            self.workspace.save_feedback_request(request, project=proj)
            self.workspace.save_state(state)
            self.store.upsert_topic(state)
            self.store.upsert_feedback_request(request)
            self._publish_topic_updated(state)
            self._publish_feedback_requested(request)
            return self.get_topic_detail(topic_id)

    def refresh_plan(self, topic_id: str, note: str = "") -> Dict[str, Any]:
        with self._lock:
            state = self._require_topic(topic_id)
            self._ensure_not_archived(state)
            proj = state.project
            state.plan_approved_at = None
            state.updated_at = utc_now()
            state.decision_state = DecisionState.NEEDS_FEEDBACK
            if note:
                self.workspace.append_note(topic_id, "Plan Revision Request", note, project=proj)
            self.workspace.save_state(state)
            self.store.upsert_topic(state)
            self._publish_topic_updated(state)

        # Regenerate plan with Claude (async, with user's note as context)
        project_context = self._load_project_context(state.project)
        threading.Thread(
            target=self._run_planning,
            args=(topic_id, project_context, note),
            daemon=True,
        ).start()
        return self.get_topic_detail(topic_id)

    # ---- Feedback ------------------------------------------------------------

    def create_feedback_request(
        self,
        topic_id: str,
        request_type: str,
        title: str,
        prompt: str,
        options: Optional[List[str]] = None,
        allow_note: bool = True,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        with self._lock:
            state = self._require_topic(topic_id)
            self._ensure_not_archived(state)
            proj = state.project
            request = FeedbackRequest(
                request_id=f"fr-{uuid.uuid4().hex[:12]}",
                topic_id=topic_id,
                request_type=FeedbackRequestType(request_type),
                title=title,
                prompt=prompt,
                options=list(options or []),
                allow_note=allow_note,
                metadata=dict(metadata or {}),
            )
            state.pending_feedback_request_id = request.request_id
            state.decision_state = DecisionState.NEEDS_FEEDBACK
            state.updated_at = utc_now()
            self.workspace.save_feedback_request(request, project=proj)
            self.workspace.save_state(state)
            self.store.upsert_feedback_request(request)
            self.store.upsert_topic(state)
            self._publish_topic_updated(state)
            self._publish_feedback_requested(request)
            return request.to_json_dict()

    def respond_to_feedback(
        self,
        topic_id: str,
        request_id: str,
        selected_options: Optional[List[str]] = None,
        note: str = "",
        actor: str = "human",
    ) -> Dict[str, Any]:
        with self._lock:
            state = self._require_topic(topic_id)
            self._ensure_not_archived(state)
            proj = state.project
            request = self.store.get_feedback_request(request_id)
            if request is None or request.topic_id != topic_id:
                raise NotFoundError(f"Feedback request {request_id} was not found.")
            response = FeedbackResponse(
                response_id=f"resp-{uuid.uuid4().hex[:12]}",
                request_id=request_id,
                topic_id=topic_id,
                selected_options=list(selected_options or []),
                note=note,
                actor=actor,
            )
            request.status = FeedbackRequestStatus.RESOLVED
            request.resolved_at = utc_now()
            state.updated_at = utc_now()
            state.pending_feedback_request_id = None if state.pending_feedback_request_id == request_id else state.pending_feedback_request_id
            if "Needs changes" in response.selected_options:
                state.decision_state = DecisionState.NEEDS_FEEDBACK
                if request.request_type == FeedbackRequestType.CONFIRM_REQUIREMENT:
                    state.requirement_state = RequirementState.CLARIFYING
                    state.requirement_approved_at = None
                if request.request_type == FeedbackRequestType.CONFIRM_PLAN:
                    state.plan_approved_at = None
            self.workspace.save_feedback_response(response, project=proj)
            self.workspace.save_feedback_request(request, project=proj)
            if note or response.selected_options:
                body = "\n".join(
                    [
                        f"- Request: {request.title}",
                        f"- Choices: {', '.join(response.selected_options) if response.selected_options else 'none'}",
                        f"- Note: {note or 'none'}",
                    ]
                )
                self.workspace.append_note(topic_id, "Human Feedback", body, project=proj)
            self.workspace.save_state(state)
            self.store.insert_feedback_response(response)
            self.store.upsert_feedback_request(request)
            self.store.upsert_topic(state)
            self._publish_topic_updated(state)
            event = self._record_event(
                "feedback.responded",
                topic_id=topic_id,
                payload={"feedback_response": response.to_json_dict(), "feedback_request": request.to_json_dict()},
            )
            self.event_bus.publish(event)

            return self.get_topic_detail(topic_id)

    # ---- Approval gates ------------------------------------------------------

    def approve_requirement(self, topic_id: str, actor: str = "human") -> Dict[str, Any]:
        with self._lock:
            state = self._require_topic(topic_id)
            self._ensure_not_archived(state)
            proj = state.project
            state.requirement_state = RequirementState.APPROVED
            state.requirement_approved_at = utc_now()
            state.updated_at = utc_now()
            state.decision_state = DecisionState.NEEDS_FEEDBACK
            self._resolve_pending_requests(topic_id, FeedbackRequestType.CONFIRM_REQUIREMENT, project=proj)
            self.workspace.append_note(topic_id, "Requirement Approved", f"Approved by {actor} at {state.requirement_approved_at}.", project=proj)
            self.workspace.save_state(state)
            self.store.upsert_topic(state)
            self._publish_topic_updated(state)

        # Kick off async plan generation (outside lock — calls Claude)
        project_context = self._load_project_context(state.project)
        threading.Thread(
            target=self._run_planning,
            args=(topic_id, project_context),
            daemon=True,
        ).start()

        return self.get_topic_detail(topic_id)

    def approve_plan(self, topic_id: str, actor: str = "human") -> Dict[str, Any]:
        with self._lock:
            state = self._require_topic(topic_id)
            self._ensure_not_archived(state)
            proj = state.project
            if not state.requirement_approved_at:
                raise ValidationError("Requirement must be approved before plan approval.")
            state.plan_approved_at = utc_now()
            state.updated_at = utc_now()
            state.decision_state = DecisionState.PENDING_IMPLEMENTATION
            self._resolve_pending_requests(topic_id, FeedbackRequestType.CONFIRM_PLAN, project=proj)
            state.pending_feedback_request_id = None
            self.workspace.append_note(topic_id, "Plan Approved", f"Approved by {actor} at {state.plan_approved_at}.", project=proj)
            self.workspace.save_state(state)
            self.store.upsert_topic(state)
            self._publish_topic_updated(state)
            return self.get_topic_detail(topic_id)

    # ---- Async agent-powered clarification & planning -------------------------

    def _load_project_context(self, project: Optional[str]) -> Optional[Dict[str, str]]:
        """Load .offload/context/*.md for a project."""
        if not project:
            return None
        project_path = Path(project)
        if not project_path.is_dir():
            return None
        repo = RepoOffload(project_path)
        ctx = repo.read_context()
        return ctx if ctx else None

    def _make_stream_callback(self, topic_id: str) -> callable:
        """Create a callback that forwards Claude stream-json events to iOS via WebSocket."""
        def _on_stream(tid: str, stage: str, event: dict) -> None:
            # Simplify the event for iOS — extract the useful parts
            evt_type = event.get("type", "")
            payload: dict = {"stage": stage, "claude_event_type": evt_type}

            if evt_type == "assistant":
                # Extract text and tool_use from message content
                msg = event.get("message", {})
                contents = msg.get("content", [])
                for c in contents:
                    ct = c.get("type", "")
                    if ct == "text":
                        payload["text"] = c["text"]
                    elif ct == "tool_use":
                        payload["tool_name"] = c.get("name", "")
                        payload["tool_input"] = json.dumps(c.get("input", {}))[:500]
            elif evt_type == "tool_result":
                payload["tool_result"] = str(event.get("content", ""))[:500]
            elif evt_type == "result":
                payload["result"] = event.get("result", "")[:500]
                payload["duration_ms"] = event.get("duration_ms", 0)
            elif evt_type == "system":
                payload["subtype"] = event.get("subtype", "")
                payload["session_id"] = event.get("session_id", "")
            else:
                # Skip rate_limit_event, etc.
                return

            ws_event = self._record_event(
                "agent.stream",
                topic_id=tid,
                payload=payload,
            )
            self.event_bus.publish(ws_event)

        return _on_stream

    def _run_clarification(self, topic_id: str, state: TopicState, project_context: Optional[Dict[str, str]]) -> None:
        """Background thread: run Claude session for Phase 1 (understand).

        Claude reads project files, discusses with context, writes requirement.md
        directly to .offload/topics/<id>/. When done, we check if requirement.md
        was updated and present the confirmation gate.
        """
        import sys
        try:
            stream_cb = self._make_stream_callback(topic_id)
            self.planner.run_clarification(
                state, project_context,
                on_stream=stream_cb,
                project_path=state.project,
            )

            # After Claude session ends, check if requirement.md was written
            with self._lock:
                current = self.store.get_topic(topic_id)
                if current is None:
                    return
                proj = current.project
                documents = self.workspace.load_documents(topic_id, project=proj)
                req = documents.get("requirement.md", "")

                if "Pending" not in req and "## Goal" in req:
                    # Claude wrote a real requirement — present confirmation gate
                    current.requirement_state = RequirementState.SPECIFIED
                    confirm = self.planner.requirement_feedback_request(topic_id)
                    current.pending_feedback_request_id = confirm.request_id
                    current.updated_at = utc_now()
                    self.workspace.save_feedback_request(confirm, project=proj)
                    self.workspace.save_state(current)
                    self.store.upsert_feedback_request(confirm)
                    self.store.upsert_topic(current)
                    self._publish_topic_updated(current)
                    self._publish_feedback_requested(confirm)
                else:
                    # Claude didn't write requirement (maybe asked questions in output)
                    # Present generic confirmation
                    confirm = self.planner.requirement_feedback_request(topic_id)
                    current.pending_feedback_request_id = confirm.request_id
                    current.updated_at = utc_now()
                    self.workspace.save_feedback_request(confirm, project=proj)
                    self.workspace.save_state(current)
                    self.store.upsert_feedback_request(confirm)
                    self.store.upsert_topic(current)
                    self._publish_topic_updated(current)
                    self._publish_feedback_requested(confirm)

        except Exception as e:
            print(f"[Planner] Clarification failed for {topic_id}: {e}", file=sys.stderr)
            import traceback
            traceback.print_exc()

    def _run_planning(self, topic_id: str, project_context: Optional[Dict[str, str]], revision_note: str = "") -> None:
        """Background thread: run Claude session for Phase 2 (plan).

        Claude reads confirmed requirement, writes plan.md directly.
        """
        import sys
        try:
            with self._lock:
                state = self.store.get_topic(topic_id)
                if state is None:
                    return
                proj = state.project
                documents = self.workspace.load_documents(topic_id, project=proj)
                requirement_md = documents.get("requirement.md", "")

            stream_cb = self._make_stream_callback(topic_id)
            self.planner.run_planning(
                state, requirement_md, project_context,
                on_stream=stream_cb,
                project_path=state.project,
                revision_note=revision_note,
            )

            # After Claude session ends, present plan confirmation gate
            with self._lock:
                state = self.store.get_topic(topic_id)
                if state is None:
                    return
                proj = state.project
                plan_request = self.planner.plan_feedback_request(topic_id)
                state.pending_feedback_request_id = plan_request.request_id
                state.updated_at = utc_now()
                self.workspace.save_feedback_request(plan_request, project=proj)
                self.workspace.save_state(state)
                self.store.upsert_feedback_request(plan_request)
                self.store.upsert_topic(state)
                self._publish_topic_updated(state)
                self._publish_feedback_requested(plan_request)

        except Exception as e:
            print(f"[Planner] Planning failed for {topic_id}: {e}", file=sys.stderr)
            import traceback
            traceback.print_exc()
        except Exception as e:
            print(f"[Planner] Requirement generation failed for {topic_id}: {e}", file=sys.stderr)

    # ---- Testing / Archive ---------------------------------------------------

    def mark_human_testing(self, topic_id: str) -> Dict[str, Any]:
        with self._lock:
            state = self._require_topic(topic_id)
            self._ensure_not_archived(state)
            if state.execution_state != ExecutionState.IMPLEMENTED:
                raise ValidationError("Human testing can start only after implementation succeeds.")
            state.execution_state = ExecutionState.HUMAN_TESTING
            state.decision_state = DecisionState.NEEDS_FEEDBACK
            state.updated_at = utc_now()
            self.workspace.append_note(topic_id, "Human Testing", f"Human testing started at {state.updated_at}.", project=state.project)
            self.workspace.save_state(state)
            self.store.upsert_topic(state)
            self._publish_topic_updated(state)
            return self.get_topic_detail(topic_id)

    def mark_passed(self, topic_id: str) -> Dict[str, Any]:
        with self._lock:
            state = self._require_topic(topic_id)
            self._ensure_not_archived(state)
            if state.execution_state != ExecutionState.HUMAN_TESTING:
                raise ValidationError("Pass can be marked only after a human testing review.")
            state.execution_state = ExecutionState.PASSED
            state.decision_state = DecisionState.NONE
            state.updated_at = utc_now()
            self.workspace.append_note(topic_id, "Passed", f"Human confirmed testing passed at {state.updated_at}.", project=state.project)
            self.workspace.save_state(state)
            self.store.upsert_topic(state)
            self._publish_topic_updated(state)
            return self.get_topic_detail(topic_id)

    def archive_topic(self, topic_id: str) -> Dict[str, Any]:
        with self._lock:
            state = self._require_topic(topic_id)
            if state.execution_state != ExecutionState.PASSED:
                raise ValidationError("Only passed topics can be archived.")
            if state.decision_state == DecisionState.ARCHIVED:
                return self.get_topic_detail(topic_id)
            state.decision_state = DecisionState.ARCHIVED
            state.updated_at = utc_now()
            self.workspace.append_note(topic_id, "Archived", f"Topic archived at {state.updated_at}.", project=state.project)
            self.workspace.save_state(state)
            self.store.upsert_topic(state)
            self._publish_topic_updated(state)
            archived_event = self._record_event("topic.archived", topic_id=topic_id, payload={"topic": state.to_json_dict()})
            self.event_bus.publish(archived_event)
            return self.get_topic_detail(topic_id)

    # ---- Execution -----------------------------------------------------------

    def trigger_run(
        self,
        topic_id: str,
        executor_name: str = "command",
        command: Optional[List[str]] = None,
    ) -> Dict[str, Any]:
        with self._lock:
            state = self._require_topic(topic_id)
            self._ensure_not_archived(state)
            proj = state.project
            if not state.requirement_approved_at or not state.plan_approved_at:
                raise ValidationError("Both requirement and plan approvals are required before execution.")
            executor = self.executors.get(executor_name)
            if executor is None:
                raise ValidationError(f"Unknown executor: {executor_name}")
            now = utc_now()
            run = RunRecord(
                run_id=f"run-{uuid.uuid4().hex[:12]}",
                topic_id=topic_id,
                executor=executor_name,
                status=RunStatus.QUEUED,
                created_at=now,
                updated_at=now,
                summary="Run queued.",
                command=list(command or []),
            )
            state.execution_state = ExecutionState.QUEUED
            state.latest_run_id = run.run_id
            state.assigned_executor = executor_name
            state.updated_at = now
            self.workspace.save_run(run, project=proj)
            self.workspace.save_state(state)
            self.store.upsert_run(run)
            self.store.upsert_topic(state)
            self._publish_topic_updated(state)
            queued_event = self._record_event("run.queued", topic_id=topic_id, run_id=run.run_id, payload={"run": run.to_json_dict()})
            self.event_bus.publish(queued_event)
            worker = threading.Thread(
                target=self._execute_run_worker,
                args=(topic_id, run.run_id, executor_name, list(command or [])),
                daemon=True,
            )
            self._run_threads[run.run_id] = worker
            worker.start()
            return run.to_json_dict()

    def events_since(self, after_sequence: int = 0) -> List[Dict[str, Any]]:
        with self._lock:
            return [event.to_json_dict() for event in self.store.list_events(after_sequence=after_sequence)]

    def _execute_run_worker(self, topic_id: str, run_id: str, executor_name: str, command: List[str]) -> None:
        try:
            executor = self.executors[executor_name]
            with self._lock:
                state = self._require_topic(topic_id)
                proj = state.project
                run = self.store.get_run(run_id)
                if run is None:
                    return
                run.status = RunStatus.RUNNING
                run.updated_at = utc_now()
                run.summary = "Run is executing."
                state.execution_state = ExecutionState.IMPLEMENTING
                state.updated_at = run.updated_at
                self.workspace.save_run(run, project=proj)
                self.workspace.save_state(state)
                self.store.upsert_run(run)
                self.store.upsert_topic(state)
                self._publish_topic_updated(state)
                started_event = self._record_event("run.started", topic_id=topic_id, run_id=run_id, payload={"run": run.to_json_dict()})
                self.event_bus.publish(started_event)

            context: Dict[str, Any] = {}
            # Tell the agent where to write its structured report
            state_ctx = self.store.get_topic(topic_id)
            report_dir = self.workspace.topic_dir(topic_id, project=state_ctx.project if state_ctx else None) / f"artifacts/{run_id}"
            report_dir.mkdir(parents=True, exist_ok=True)
            context["report_path"] = str(report_dir / "report.md")
            if state_ctx and state_ctx.project:
                project_path = Path(state_ctx.project)
                if project_path.is_dir():
                    context["workspace_dir"] = str(project_path)
                    from .repo_offload import RepoOffload
                    repo = RepoOffload(project_path)
                    offload_context = repo.read_context()
                    if offload_context:
                        context["project_context"] = offload_context
            # topic_dir now routes to per-repo location
            result = executor.execute(self.workspace.topic_dir(topic_id, project=state_ctx.project if state_ctx else None), command=command or None, context=context)

            with self._lock:
                state = self._require_topic(topic_id)
                proj = state.project
                run = self.store.get_run(run_id)
                if run is None:
                    return
                artifact_prefix = f"artifacts/{run.run_id}"
                persisted_artifacts = []
                for name, content in result.artifacts.items():
                    relative_name = name.replace("artifacts/latest", artifact_prefix, 1)
                    persisted_artifacts.append(self.workspace.write_artifact_text(topic_id, relative_name, content, project=proj))
                metadata_artifact = self.workspace.write_artifact_text(
                    topic_id,
                    f"{artifact_prefix}/result.json",
                    json.dumps(
                        {
                            "summary": result.summary,
                            "exit_code": result.exit_code,
                            "error": result.error,
                        },
                        indent=2,
                    ),
                    project=proj,
                )
                persisted_artifacts.append(metadata_artifact)
                run.status = RunStatus.SUCCEEDED if result.exit_code == 0 else RunStatus.FAILED
                run.updated_at = utc_now()
                run.finished_at = run.updated_at
                run.summary = result.summary
                run.exit_code = result.exit_code
                run.artifacts = persisted_artifacts
                run.error = result.error
                state.execution_state = ExecutionState.IMPLEMENTED if result.exit_code == 0 else ExecutionState.FAILED
                state.decision_state = DecisionState.NEEDS_FEEDBACK if result.exit_code == 0 else DecisionState.BLOCKED
                state.latest_run_id = run.run_id
                state.updated_at = run.updated_at
                if result.exit_code == 0:
                    self.workspace.append_note(
                        topic_id,
                        "Implementation Complete",
                        "Implementation finished. Human testing and pass confirmation are required before archiving.",
                        project=proj,
                    )
                self.workspace.save_run(run, project=proj)
                self.workspace.save_state(state)
                self.store.upsert_run(run)
                self.store.upsert_topic(state)
                self._publish_topic_updated(state)
                finished_event = self._record_event("run.finished", topic_id=topic_id, run_id=run_id, payload={"run": run.to_json_dict()})
                self.event_bus.publish(finished_event)
        finally:
            with self._lock:
                self._run_threads.pop(run_id, None)

    # ---- Helpers -------------------------------------------------------------

    def _resolve_pending_requests(self, topic_id: str, request_type: FeedbackRequestType, project: Optional[str] = None) -> None:
        requests = self.store.list_feedback_requests(topic_id=topic_id, pending_only=True)
        for request in requests:
            if request.request_type != request_type:
                continue
            request.status = FeedbackRequestStatus.RESOLVED
            request.resolved_at = utc_now()
            self.workspace.save_feedback_request(request, project=project)
            self.store.upsert_feedback_request(request)

    def _publish_topic_updated(self, state: TopicState) -> None:
        event = self._record_event("topic.updated", topic_id=state.topic_id, payload={"topic": state.to_json_dict()})
        self.event_bus.publish(event)

    def _publish_feedback_requested(self, request: FeedbackRequest) -> None:
        event = self._record_event("feedback.requested", topic_id=request.topic_id, payload={"feedback_request": request.to_json_dict()})
        self.event_bus.publish(event)

    def _record_event(
        self,
        event_type: str,
        topic_id: Optional[str] = None,
        run_id: Optional[str] = None,
        payload: Optional[Dict[str, Any]] = None,
    ) -> EventRecord:
        event = EventRecord(
            event_id=f"evt-{uuid.uuid4().hex[:12]}",
            event_type=event_type,
            topic_id=topic_id,
            run_id=run_id,
            payload=dict(payload or {}),
        )
        return self.store.append_event(event)

    def _require_topic(self, topic_id: str) -> TopicState:
        state = self.store.get_topic(topic_id)
        if state is None:
            raise NotFoundError(f"Topic {topic_id} was not found.")
        return state

    def _ensure_not_archived(self, state: TopicState) -> None:
        if state.decision_state == DecisionState.ARCHIVED:
            raise ValidationError("Archived topics are read-only.")

    def _merge_tags(self, parent_tags: List[str], new_tags: List[str]) -> List[str]:
        merged: List[str] = []
        for tag in parent_tags + new_tags:
            if tag and tag not in merged:
                merged.append(tag)
        return merged

    def _build_parent_context(self, parent_topic_id: Optional[str]) -> Optional[str]:
        if not parent_topic_id:
            return None
        parent_state = self.store.get_topic(parent_topic_id)
        if parent_state is None:
            return None
        parent_documents = self.workspace.load_documents(parent_topic_id, project=parent_state.project)
        requirement_excerpt = self._excerpt(parent_documents.get("requirement.md", ""))
        plan_excerpt = self._excerpt(parent_documents.get("plan.md", ""))
        return "\n".join(
            [
                f"- Parent Topic ID: `{parent_state.topic_id}`",
                f"- Parent Title: {parent_state.title}",
                f"- Parent Summary: {parent_state.summary}",
                "",
                "### Parent Requirement Excerpt",
                "",
                requirement_excerpt or "No requirement snapshot available.",
                "",
                "### Parent Plan Excerpt",
                "",
                plan_excerpt or "No implementation plan available.",
            ]
        ).strip()

    def _excerpt(self, content: str, limit: int = 900) -> str:
        normalized = content.strip()
        if len(normalized) <= limit:
            return normalized
        return normalized[:limit].rstrip() + "\n..."
