from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

from .repo_offload import (
    InitRunner,
    RepoOffload,
    STATUS_INITIALIZING,
    STATUS_NOT_INITIALIZED,
    STATUS_READY,
)


README_NAMES = ["README.md", "README", "readme.md", "Readme.md", "README.MD"]
MAX_README_BYTES = 256 * 1024  # 256 KB safety cap
MAX_SCAN_DEPTH = 4


@dataclass
class ProjectInfo:
    name: str
    path: str
    has_readme: bool
    is_initialized: bool = False
    init_status: str = STATUS_NOT_INITIALIZED
    summary: Optional[str] = None
    init_error: Optional[str] = None

    def to_json_dict(self) -> dict:
        return {
            "name": self.name,
            "path": self.path,
            "has_readme": self.has_readme,
            "is_initialized": self.is_initialized,
            "init_status": self.init_status,
            "summary": self.summary,
            "init_error": self.init_error,
        }


class ProjectScanner:
    def __init__(self, root: Optional[Path], init_runner: Optional[InitRunner] = None):
        self.root = root.resolve() if root else None
        self.init_runner = init_runner

    def list_projects(self) -> List[ProjectInfo]:
        if not self.root or not self.root.is_dir():
            return []
        results: List[ProjectInfo] = []
        self._scan(self.root, depth=0, results=results)
        results.sort(key=lambda p: p.name.lower())
        return results

    def _scan(self, directory: Path, depth: int, results: List[ProjectInfo]) -> None:
        if depth > MAX_SCAN_DEPTH:
            return
        try:
            entries = sorted(directory.iterdir(), key=lambda p: p.name.lower())
        except (PermissionError, OSError):
            return
        # Is this directory itself a git repo?
        if (directory / ".git").exists():
            results.append(self._build_project_info(directory))
            return  # Don't recurse into git repo subdirectories
        for entry in entries:
            if not entry.is_dir():
                continue
            if entry.name.startswith("."):
                continue
            if entry.name in {"node_modules", "venv", ".venv", "__pycache__", "build", "dist", "target"}:
                continue
            self._scan(entry, depth + 1, results)

    def _build_project_info(self, directory: Path) -> ProjectInfo:
        repo = RepoOffload(directory)
        is_init = repo.is_initialized()
        path_str = str(directory)
        if self.init_runner:
            status = self.init_runner.status(path_str)
            job = self.init_runner.get_job(path_str)
            init_error = job.error if job else None
        else:
            status = STATUS_READY if is_init else STATUS_NOT_INITIALIZED
            init_error = None
        return ProjectInfo(
            name=directory.name,
            path=path_str,
            has_readme=self._find_readme(directory) is not None,
            is_initialized=is_init,
            init_status=status,
            summary=repo.read_summary_excerpt() if is_init else None,
            init_error=init_error,
        )

    def _find_readme(self, directory: Path) -> Optional[Path]:
        for name in README_NAMES:
            candidate = directory / name
            if candidate.is_file():
                return candidate
        return None

    def read_readme(self, project_path: str) -> Optional[str]:
        if not self.root:
            return None
        try:
            target = Path(project_path).resolve()
        except (OSError, ValueError):
            return None
        # Containment check: target must be inside root
        try:
            target.relative_to(self.root)
        except ValueError:
            return None
        if not target.is_dir():
            return None
        readme = self._find_readme(target)
        if readme is None:
            return None
        try:
            with readme.open("rb") as f:
                data = f.read(MAX_README_BYTES + 1)
        except OSError:
            return None
        if len(data) > MAX_README_BYTES:
            data = data[:MAX_README_BYTES] + b"\n\n... (truncated)"
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError:
            return data.decode("utf-8", errors="replace")
