from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional

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

    def get_architecture_tree(self, project_path: str) -> Optional[Dict[str, Any]]:
        """Return parsed architecture.md as a visual tree structure."""
        if not self.root:
            return None
        target = Path(project_path).resolve()
        repo = RepoOffload(target)
        context = repo.read_context()
        arch_md = context.get("architecture.md", "")
        if not arch_md.strip():
            return None
        name = target.name
        info = self._build_project_info(target) if (target / ".git").exists() else None
        if info:
            name = info.name
        return _parse_architecture_tree(arch_md, name)

    def _validate_project_path(self, project_path: str, rel: str = "") -> Optional[Path]:
        """Resolve and validate that a path is within a known project. Returns resolved path or None."""
        if not self.root:
            return None
        target = Path(project_path).resolve()
        try:
            target.relative_to(self.root)
        except ValueError:
            return None
        if rel:
            full = (target / rel).resolve()
            # Prevent path traversal
            try:
                full.relative_to(target)
            except ValueError:
                return None
            return full
        return target

    def list_files(self, project_path: str, rel: str = "") -> Optional[Dict[str, Any]]:
        """List files/directories in a project subdirectory."""
        base = self._validate_project_path(project_path)
        if base is None:
            return None
        target = self._validate_project_path(project_path, rel) if rel else base
        if target is None or not target.is_dir():
            return None

        entries = []
        try:
            for child in sorted(target.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower())):
                name = child.name
                # Skip hidden files and common noise
                if name.startswith(".") and name not in (".offload",):
                    continue
                if name in ("node_modules", "__pycache__", ".build", "DerivedData"):
                    continue
                rel_path = str(child.relative_to(base))
                entry: Dict[str, Any] = {
                    "name": name,
                    "rel_path": rel_path,
                    "is_dir": child.is_dir(),
                }
                if child.is_file():
                    try:
                        entry["size"] = child.stat().st_size
                    except OSError:
                        entry["size"] = 0
                entries.append(entry)
        except PermissionError:
            return {"entries": [], "rel": rel, "error": "Permission denied"}

        return {"entries": entries, "rel": rel}

    def read_file(self, project_path: str, rel: str) -> Optional[Dict[str, Any]]:
        """Read a single file from a project. Returns content (text) or an error."""
        target = self._validate_project_path(project_path, rel)
        if target is None or not target.is_file():
            return None

        MAX_FILE_BYTES = 256 * 1024  # 256 KB
        try:
            size = target.stat().st_size
            if size > MAX_FILE_BYTES:
                return {
                    "rel": rel,
                    "truncated": True,
                    "size": size,
                    "content": target.read_bytes()[:MAX_FILE_BYTES].decode("utf-8", errors="replace")
                        + "\n\n... (truncated)",
                }
            content = target.read_bytes()
            # Check if binary
            if b"\x00" in content[:1024]:
                return {"rel": rel, "binary": True, "size": size, "content": None}
            return {
                "rel": rel,
                "truncated": False,
                "size": size,
                "content": content.decode("utf-8", errors="replace"),
            }
        except OSError:
            return None

    def get_project_activity(self, project_path: str, service: Any = None) -> Dict[str, Any]:
        """
        Aggregate meta stats + recent agent runs + recent git commits for a project.
        """
        if not self.root:
            return {"meta": {}, "recent_runs": [], "recent_commits": []}
        target = Path(project_path).resolve()

        # Meta
        repo = RepoOffload(target)
        info = self._build_project_info(target) if (target / ".git").exists() else None
        context = repo.read_context()

        # Topic stats from service (if available)
        topic_stats = {"total": 0, "active": 0, "completed": 0, "archived": 0}
        recent_runs: List[Dict[str, Any]] = []
        if service:
            all_topics = service.store.list_topics()
            project_topics = [t for t in all_topics if t.project == project_path]
            topic_stats["total"] = len(project_topics)
            topic_stats["active"] = sum(1 for t in project_topics if t.execution_state.value in ("queued", "implementing"))
            topic_stats["completed"] = sum(1 for t in project_topics if t.execution_state.value in ("implemented", "passed", "human_testing"))
            topic_stats["archived"] = sum(1 for t in project_topics if t.decision_state.value == "archived")

            # Recent runs across all project topics
            for t in project_topics:
                for run in service.store.list_runs(t.topic_id):
                    if run.status.value in ("succeeded", "failed"):
                        # Get first meaningful line from stdout artifact
                        report_excerpt = ""
                        try:
                            topic_dir = service.workspace.topic_dir(t.topic_id, project=t.project)
                            # Prefer structured report.md over raw stdout
                            report_path = topic_dir / f"artifacts/{run.run_id}/report.md"
                            if report_path.is_file():
                                text = report_path.read_text()[:2000]
                                # Extract the Summary section
                                in_summary = False
                                for line in text.splitlines():
                                    stripped = line.strip()
                                    if stripped.lower().startswith("## summary"):
                                        in_summary = True
                                        continue
                                    if in_summary and stripped.startswith("##"):
                                        break
                                    if in_summary and stripped:
                                        report_excerpt = stripped[:300]
                                        break
                            # Fallback to stdout first line
                            if not report_excerpt:
                                stdout_path = topic_dir / f"artifacts/{run.run_id}/stdout.log"
                                if stdout_path.is_file():
                                    lines = [l.strip() for l in stdout_path.read_text()[:1000].splitlines() if l.strip()]
                                    if lines:
                                        report_excerpt = lines[0][:200]
                        except OSError:
                            pass
                        recent_runs.append({
                            "topic_id": t.topic_id,
                            "topic_title": t.title,
                            "run_id": run.run_id,
                            "executor": run.executor,
                            "status": run.status.value,
                            "finished_at": run.finished_at,
                            "summary": run.summary,
                            "report_excerpt": report_excerpt,
                        })
            recent_runs.sort(key=lambda r: r.get("finished_at") or "", reverse=True)
            recent_runs = recent_runs[:10]

        # Recent git commits
        recent_commits = _git_recent_commits(target, limit=10)

        meta: Dict[str, Any] = {
            "name": info.name if info else target.name,
            "path": str(target),
            "summary": info.summary if info else None,
            "topic_stats": topic_stats,
        }
        # Add architecture excerpt if available
        arch = context.get("architecture.md", "")
        if arch:
            # First 2 non-empty, non-heading lines
            lines = [l.strip() for l in arch.splitlines() if l.strip() and not l.strip().startswith("#")]
            meta["architecture_excerpt"] = " ".join(lines[:2])[:300] if lines else None

        return {
            "meta": meta,
            "recent_runs": recent_runs,
            "recent_commits": recent_commits,
        }


def _parse_architecture_tree(md: str, project_name: str) -> Dict[str, Any]:
    """Parse architecture.md into a top-down tree of nodes.

    Returns a tree structure like:
    {
        "id": "root",
        "label": "Project Name",
        "type": "project",
        "children": [
            {"id": "...", "label": "Server", "type": "layer", "desc": "...", "children": [
                {"id": "...", "label": "http.py", "type": "module", "desc": "...", "children": []}
            ]}
        ]
    }
    """
    import re
    import hashlib

    def _id(text: str) -> str:
        return hashlib.md5(text.encode()).hexdigest()[:8]

    root: Dict[str, Any] = {
        "id": "root",
        "label": project_name,
        "type": "project",
        "desc": "",
        "children": [],
    }

    lines = md.splitlines()
    # Gather overview text (before first ##)
    overview_lines: List[str] = []
    i = 0
    # Skip the leading "# Architecture" heading
    while i < len(lines) and not lines[i].strip().startswith("##"):
        line = lines[i].strip()
        if line and not line.startswith("#"):
            overview_lines.append(line)
        i += 1
    root["desc"] = " ".join(overview_lines)[:400]

    # Parse sections
    current_h2: Optional[Dict[str, Any]] = None
    current_h3: Optional[Dict[str, Any]] = None
    buffer: List[str] = []

    def _flush_buffer() -> str:
        text = "\n".join(buffer).strip()
        buffer.clear()
        return text

    def _extract_modules(text: str) -> List[Dict[str, Any]]:
        """Extract `name` — description entries from a section body."""
        modules: List[Dict[str, Any]] = []
        for line in text.splitlines():
            # Match patterns like: - `http.py` — description
            # or - **http.py** — description
            m = re.match(r'^[-*]\s+[`*]*([^`*]+?)[`*]*\s*[—–-]\s*(.+)', line.strip())
            if m:
                name = m.group(1).strip()
                desc = m.group(2).strip()
                modules.append({
                    "id": _id(name),
                    "label": name,
                    "type": "module",
                    "desc": desc[:300],
                    "children": [],
                })
        return modules

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        if stripped.startswith("### "):
            # Flush previous h3
            if current_h3 is not None:
                body = _flush_buffer()
                current_h3["desc"] = body[:300]
                current_h3["children"] = _extract_modules(body)
            elif current_h2 is not None:
                body = _flush_buffer()
                if not current_h2["desc"]:
                    current_h2["desc"] = body[:300]
                current_h2["children"].extend(_extract_modules(body))

            title = stripped[4:].strip().rstrip("#").strip()
            # Extract parenthetical path hint
            path_match = re.search(r'\(([^)]+)\)', title)
            path_hint = path_match.group(1) if path_match else ""
            label = re.sub(r'\s*\([^)]*\)\s*', '', title).strip()

            current_h3 = {
                "id": _id(title),
                "label": label,
                "type": "layer",
                "desc": path_hint,
                "children": [],
            }
            if current_h2 is not None:
                current_h2["children"].append(current_h3)
            else:
                root["children"].append(current_h3)

        elif stripped.startswith("## "):
            # Flush previous
            if current_h3 is not None:
                body = _flush_buffer()
                current_h3["desc"] = body[:300]
                current_h3["children"] = _extract_modules(body)
                current_h3 = None
            elif current_h2 is not None:
                body = _flush_buffer()
                if not current_h2["desc"]:
                    current_h2["desc"] = body[:300]
                current_h2["children"].extend(_extract_modules(body))

            title = stripped[3:].strip().rstrip("#").strip()
            current_h2 = {
                "id": _id(title),
                "label": title,
                "type": "group",
                "desc": "",
                "children": [],
            }
            root["children"].append(current_h2)

        else:
            buffer.append(line)

        i += 1

    # Flush last
    if current_h3 is not None:
        body = _flush_buffer()
        current_h3["desc"] = body[:300]
        current_h3["children"] = _extract_modules(body)
    elif current_h2 is not None:
        body = _flush_buffer()
        if not current_h2["desc"]:
            current_h2["desc"] = body[:300]
        current_h2["children"].extend(_extract_modules(body))

    return root


def _git_recent_commits(repo_path: Path, limit: int = 10) -> List[Dict[str, str]]:
    try:
        result = subprocess.run(
            ["git", "log", f"--max-count={limit}", "--format=%H|%s|%ai|%an"],
            cwd=repo_path, capture_output=True, text=True, timeout=5,
        )
        commits = []
        for line in result.stdout.strip().splitlines():
            parts = line.split("|", 3)
            if len(parts) >= 4:
                commits.append({
                    "hash": parts[0][:8],
                    "message": parts[1],
                    "date": parts[2],
                    "author": parts[3],
                })
        return commits
    except Exception:
        return []
