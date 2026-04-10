from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

from .models import FeedbackRequest, FeedbackResponse, RunRecord, TopicState


CORE_DOCUMENTS = ("topic.md", "requirement.md", "plan.md", "notes.md")


class WorkspaceManager:
    def __init__(self, root: Path):
        self.root = Path(root)
        self.topics_root = self.root / "topics"
        self.bootstrap()

    def bootstrap(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        self.topics_root.mkdir(parents=True, exist_ok=True)

    # ---- Path routing --------------------------------------------------------
    # If a topic has a project (repo path), its files live at
    # <project>/.offload/topics/<topic_id>/. Otherwise, <workspace>/topics/<topic_id>/.

    def topic_dir(self, topic_id: str, project: Optional[str] = None) -> Path:
        if project:
            p = Path(project)
            if p.is_dir():
                return p / ".offload" / "topics" / topic_id
        return self.topics_root / topic_id

    def state_path(self, topic_id: str, project: Optional[str] = None) -> Path:
        return self.topic_dir(topic_id, project) / "state.json"

    # ---- Topic CRUD ----------------------------------------------------------

    def create_topic(self, state: TopicState, documents: Dict[str, str]) -> None:
        proj = state.project
        td = self.topic_dir(state.topic_id, proj)
        (td / "feedback").mkdir(parents=True, exist_ok=True)
        (td / "runs").mkdir(parents=True, exist_ok=True)
        (td / "artifacts").mkdir(parents=True, exist_ok=True)
        for name in CORE_DOCUMENTS:
            self.write_document(state.topic_id, name, documents.get(name, ""), project=proj)
        self.save_state(state)

    def save_state(self, state: TopicState) -> None:
        self._atomic_write_json(self.state_path(state.topic_id, state.project), state.to_json_dict())

    def load_state(self, topic_id: str, project: Optional[str] = None) -> TopicState:
        return TopicState.from_json_dict(json.loads(self.state_path(topic_id, project).read_text(encoding="utf-8")))

    # ---- Topic discovery -----------------------------------------------------

    def list_topic_ids(self) -> List[str]:
        """List topic IDs in the server workspace only (ungrouped)."""
        if not self.topics_root.exists():
            return []
        return sorted(entry.name for entry in self.topics_root.iterdir() if entry.is_dir())

    def list_all_topic_ids(self, project_paths: Optional[List[str]] = None) -> List[Tuple[str, Optional[str]]]:
        """
        Discover all topic IDs across workspace + repos.
        Returns list of (topic_id, project_path_or_None).
        """
        result: List[Tuple[str, Optional[str]]] = []
        # Workspace (ungrouped)
        for tid in self.list_topic_ids():
            result.append((tid, None))
        # Per-repo
        for repo_path in (project_paths or []):
            topics_dir = Path(repo_path) / ".offload" / "topics"
            if topics_dir.is_dir():
                try:
                    for entry in sorted(topics_dir.iterdir()):
                        if entry.is_dir():
                            result.append((entry.name, repo_path))
                except (PermissionError, OSError):
                    pass
        return result

    # ---- Documents -----------------------------------------------------------

    def write_document(self, topic_id: str, name: str, content: str, project: Optional[str] = None) -> None:
        self._atomic_write_text(self.topic_dir(topic_id, project) / name, content.rstrip() + "\n")

    def read_document(self, topic_id: str, name: str, project: Optional[str] = None) -> str:
        return (self.topic_dir(topic_id, project) / name).read_text(encoding="utf-8")

    def load_documents(self, topic_id: str, project: Optional[str] = None) -> Dict[str, str]:
        return {name: self.read_document(topic_id, name, project) for name in CORE_DOCUMENTS}

    # ---- Feedback ------------------------------------------------------------

    def save_feedback_request(self, request: FeedbackRequest, project: Optional[str] = None) -> None:
        path = self.topic_dir(request.topic_id, project) / "feedback" / f"{request.request_id}.json"
        self._atomic_write_json(path, request.to_json_dict())

    def save_feedback_response(self, response: FeedbackResponse, project: Optional[str] = None) -> None:
        path = self.topic_dir(response.topic_id, project) / "feedback" / f"{response.response_id}.json"
        self._atomic_write_json(path, response.to_json_dict())

    def load_feedback_files(self, topic_id: str, project: Optional[str] = None) -> Iterable[Tuple[str, dict]]:
        feedback_dir = self.topic_dir(topic_id, project) / "feedback"
        if not feedback_dir.exists():
            return []
        pairs = []
        for entry in sorted(feedback_dir.glob("*.json")):
            pairs.append((entry.name, json.loads(entry.read_text(encoding="utf-8"))))
        return pairs

    # ---- Runs ----------------------------------------------------------------

    def save_run(self, run: RunRecord, project: Optional[str] = None) -> None:
        path = self.topic_dir(run.topic_id, project) / "runs" / f"{run.run_id}.json"
        self._atomic_write_json(path, run.to_json_dict())

    def load_runs(self, topic_id: str, project: Optional[str] = None) -> List[RunRecord]:
        runs_dir = self.topic_dir(topic_id, project) / "runs"
        if not runs_dir.exists():
            return []
        runs = []
        for entry in sorted(runs_dir.glob("*.json")):
            runs.append(RunRecord.from_json_dict(json.loads(entry.read_text(encoding="utf-8"))))
        return runs

    # ---- Artifacts -----------------------------------------------------------

    def write_artifact_text(self, topic_id: str, relative_path: str, content: str, project: Optional[str] = None) -> str:
        td = self.topic_dir(topic_id, project)
        artifact_path = td / relative_path
        artifact_path.parent.mkdir(parents=True, exist_ok=True)
        self._atomic_write_text(artifact_path, content)
        return str(artifact_path.relative_to(td))

    def list_artifacts(self, topic_id: str, project: Optional[str] = None) -> List[str]:
        td = self.topic_dir(topic_id, project)
        artifacts_dir = td / "artifacts"
        if not artifacts_dir.exists():
            return []
        artifacts = []
        for entry in sorted(artifacts_dir.rglob("*")):
            if entry.is_file():
                artifacts.append(str(entry.relative_to(td)))
        return artifacts

    # ---- Notes ---------------------------------------------------------------

    def append_note(self, topic_id: str, heading: str, body: str, project: Optional[str] = None) -> None:
        existing = self.read_document(topic_id, "notes.md", project)
        snippet = f"\n## {heading}\n\n{body.rstrip()}\n"
        self.write_document(topic_id, "notes.md", existing.rstrip() + snippet, project)

    # ---- Migration -----------------------------------------------------------

    def migrate_topic_to_repo(self, topic_id: str, project: str) -> bool:
        """
        Move a topic from server workspace to <project>/.offload/topics/.
        Returns True if migration happened.
        """
        src = self.topics_root / topic_id
        if not src.is_dir():
            return False
        dst = Path(project) / ".offload" / "topics" / topic_id
        if dst.exists():
            return False  # already there
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(src), str(dst))
        return True

    # ---- Internals -----------------------------------------------------------

    def _atomic_write_text(self, path: Path, content: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(content, encoding="utf-8")
        tmp.replace(path)

    def _atomic_write_json(self, path: Path, payload: dict) -> None:
        self._atomic_write_text(path, json.dumps(payload, indent=2, sort_keys=True) + "\n")
