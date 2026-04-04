from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

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

    def topic_dir(self, topic_id: str) -> Path:
        return self.topics_root / topic_id

    def state_path(self, topic_id: str) -> Path:
        return self.topic_dir(topic_id) / "state.json"

    def create_topic(self, state: TopicState, documents: Dict[str, str]) -> None:
        topic_dir = self.topic_dir(state.topic_id)
        (topic_dir / "feedback").mkdir(parents=True, exist_ok=True)
        (topic_dir / "runs").mkdir(parents=True, exist_ok=True)
        (topic_dir / "artifacts").mkdir(parents=True, exist_ok=True)
        for name in CORE_DOCUMENTS:
            self.write_document(state.topic_id, name, documents.get(name, ""))
        self.save_state(state)

    def save_state(self, state: TopicState) -> None:
        self._atomic_write_json(self.state_path(state.topic_id), state.to_json_dict())

    def load_state(self, topic_id: str) -> TopicState:
        return TopicState.from_json_dict(json.loads(self.state_path(topic_id).read_text(encoding="utf-8")))

    def list_topic_ids(self) -> List[str]:
        if not self.topics_root.exists():
            return []
        return sorted(entry.name for entry in self.topics_root.iterdir() if entry.is_dir())

    def write_document(self, topic_id: str, name: str, content: str) -> None:
        self._atomic_write_text(self.topic_dir(topic_id) / name, content.rstrip() + "\n")

    def read_document(self, topic_id: str, name: str) -> str:
        return (self.topic_dir(topic_id) / name).read_text(encoding="utf-8")

    def load_documents(self, topic_id: str) -> Dict[str, str]:
        return {name: self.read_document(topic_id, name) for name in CORE_DOCUMENTS}

    def save_feedback_request(self, request: FeedbackRequest) -> None:
        path = self.topic_dir(request.topic_id) / "feedback" / f"{request.request_id}.json"
        self._atomic_write_json(path, request.to_json_dict())

    def save_feedback_response(self, response: FeedbackResponse) -> None:
        path = self.topic_dir(response.topic_id) / "feedback" / f"{response.response_id}.json"
        self._atomic_write_json(path, response.to_json_dict())

    def load_feedback_files(self, topic_id: str) -> Iterable[Tuple[str, dict]]:
        feedback_dir = self.topic_dir(topic_id) / "feedback"
        if not feedback_dir.exists():
            return []
        pairs = []
        for entry in sorted(feedback_dir.glob("*.json")):
            pairs.append((entry.name, json.loads(entry.read_text(encoding="utf-8"))))
        return pairs

    def save_run(self, run: RunRecord) -> None:
        path = self.topic_dir(run.topic_id) / "runs" / f"{run.run_id}.json"
        self._atomic_write_json(path, run.to_json_dict())

    def load_runs(self, topic_id: str) -> List[RunRecord]:
        runs_dir = self.topic_dir(topic_id) / "runs"
        if not runs_dir.exists():
            return []
        runs = []
        for entry in sorted(runs_dir.glob("*.json")):
            runs.append(RunRecord.from_json_dict(json.loads(entry.read_text(encoding="utf-8"))))
        return runs

    def write_artifact_text(self, topic_id: str, relative_path: str, content: str) -> str:
        artifact_path = self.topic_dir(topic_id) / relative_path
        artifact_path.parent.mkdir(parents=True, exist_ok=True)
        self._atomic_write_text(artifact_path, content)
        return str(artifact_path.relative_to(self.topic_dir(topic_id)))

    def list_artifacts(self, topic_id: str) -> List[str]:
        artifacts_dir = self.topic_dir(topic_id) / "artifacts"
        if not artifacts_dir.exists():
            return []
        artifacts = []
        for entry in sorted(artifacts_dir.rglob("*")):
            if entry.is_file():
                artifacts.append(str(entry.relative_to(self.topic_dir(topic_id))))
        return artifacts

    def append_note(self, topic_id: str, heading: str, body: str) -> None:
        existing = self.read_document(topic_id, "notes.md")
        snippet = f"\n## {heading}\n\n{body.rstrip()}\n"
        self.write_document(topic_id, "notes.md", existing.rstrip() + snippet)

    def _atomic_write_text(self, path: Path, content: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(content, encoding="utf-8")
        tmp.replace(path)

    def _atomic_write_json(self, path: Path, payload: dict) -> None:
        self._atomic_write_text(path, json.dumps(payload, indent=2, sort_keys=True) + "\n")

