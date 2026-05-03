"""Claude Code adapter — pty-based for native terminal output."""
from __future__ import annotations

import fcntl
import json
import os
import pty
import select
import signal
import struct
import subprocess
import termios
import time
from pathlib import Path
from typing import Dict, List, Optional

from ._base import AgentEvent, EventCallback


class ClaudeCodeAdapter:
    """Drives Claude Code CLI via pty for native terminal rendering.

    Captures raw terminal output (including ANSI escape codes) so it can
    be rendered faithfully by xterm.js on the client.  Also runs a parallel
    stream-json process to capture the session_id for resume.
    """

    def __init__(self, skip_permissions: bool = True) -> None:
        self._cwd: Optional[Path] = None
        self._env: Optional[Dict[str, str]] = None
        self._session_id: Optional[str] = None
        self._child_pid: Optional[int] = None
        self._master_fd: Optional[int] = None
        self._skip_permissions = skip_permissions
        self._resume_failed = False

    # -- AgentAdapter interface ------------------------------------------------

    def start(self, cwd: Path, env: Optional[Dict[str, str]] = None) -> None:
        self._cwd = cwd
        self._env = env

    def send(
        self,
        message: str,
        on_event: Optional[EventCallback] = None,
    ) -> str:
        if self._cwd is None:
            raise RuntimeError("Adapter not started — call start(cwd) first")

        cmd: List[str] = ["claude"]
        if self._session_id:
            cmd.extend(["--resume", self._session_id])
        cmd.extend(["-p", message])
        if self._skip_permissions:
            cmd.append("--dangerously-skip-permissions")

        # Include .offload/ CLAUDE.md for harness context
        offload_dir = self._cwd / ".offload"
        if offload_dir.is_dir():
            cmd.extend(["--add-dir", str(offload_dir)])

        # Fork a pty so CC renders as if in a real terminal
        child_pid, master_fd = pty.fork()
        if child_pid == 0:
            # Child process
            os.chdir(str(self._cwd))
            env = os.environ.copy()
            env["TERM"] = "xterm-256color"
            env["COLUMNS"] = "90"
            env["LINES"] = "40"
            if self._env:
                env.update(self._env)
            os.execvpe(cmd[0], cmd, env)
            os._exit(1)

        self._child_pid = child_pid
        self._master_fd = master_fd

        # Set terminal size
        winsize = struct.pack("HHHH", 40, 90, 0, 0)
        fcntl.ioctl(master_fd, termios.TIOCSWINSZ, winsize)

        collected_raw: List[bytes] = []
        collected_text: List[str] = []
        result_text = ""

        try:
            deadline = time.monotonic() + 600

            while time.monotonic() < deadline:
                readable, _, _ = select.select([master_fd], [], [], 0.05)
                if master_fd in readable:
                    try:
                        chunk = os.read(master_fd, 4096)
                    except OSError:
                        break
                    if not chunk:
                        break
                    collected_raw.append(chunk)
                    text = chunk.decode("utf-8", errors="replace")
                    collected_text.append(text)
                    if on_event:
                        on_event(AgentEvent("terminal_output", {"data": text}))
                else:
                    # Check if child exited
                    try:
                        pid, status = os.waitpid(child_pid, os.WNOHANG)
                        if pid != 0:
                            # Drain remaining output
                            try:
                                while True:
                                    rem = os.read(master_fd, 4096)
                                    if not rem:
                                        break
                                    collected_raw.append(rem)
                                    text = rem.decode("utf-8", errors="replace")
                                    collected_text.append(text)
                                    if on_event:
                                        on_event(AgentEvent("terminal_output", {"data": text}))
                            except OSError:
                                pass
                            break
                    except ChildProcessError:
                        break

            result_text = "".join(collected_text)

            # Capture session_id from a quick json-format run
            self._capture_session_id_from_result(result_text)

            if on_event:
                on_event(AgentEvent("done", {
                    "result": result_text,
                    "session_id": self._session_id,
                }))

        finally:
            try:
                os.close(master_fd)
            except OSError:
                pass
            try:
                os.kill(child_pid, signal.SIGTERM)
                os.waitpid(child_pid, 0)
            except OSError:
                pass
            self._child_pid = None
            self._master_fd = None

        return result_text

    def stop(self) -> None:
        if self._master_fd is not None:
            try:
                os.close(self._master_fd)
            except OSError:
                pass
            self._master_fd = None
        if self._child_pid is not None:
            try:
                os.kill(self._child_pid, signal.SIGTERM)
                try:
                    os.waitpid(self._child_pid, os.WNOHANG)
                except ChildProcessError:
                    pass
            except OSError:
                pass
            self._child_pid = None

    @property
    def is_running(self) -> bool:
        if self._child_pid is None:
            return False
        try:
            pid, _ = os.waitpid(self._child_pid, os.WNOHANG)
            return pid == 0
        except ChildProcessError:
            return False

    @property
    def session_id(self) -> Optional[str]:
        return self._session_id

    @property
    def resume_failed(self) -> bool:
        return self._resume_failed

    # -- Internal --------------------------------------------------------------

    def _capture_session_id_from_result(self, output: str) -> None:
        """Try to find session_id from CC's output or recent session files."""
        # Check ~/.claude/projects/ for the most recent session
        try:
            if not self._cwd:
                return
            # CC stores sessions under a path-based key
            projects_dir = Path.home() / ".claude" / "projects"
            if not projects_dir.is_dir():
                return
            # Find most recently modified .jsonl file
            session_files = []
            for d in projects_dir.iterdir():
                if d.is_dir():
                    for f in d.iterdir():
                        if f.suffix == ".jsonl":
                            session_files.append(f)
            if not session_files:
                return
            session_files.sort(key=lambda f: f.stat().st_mtime, reverse=True)
            newest = session_files[0]
            # The filename (without extension) is the session_id
            new_sid = newest.stem
            if self._session_id and new_sid != self._session_id:
                self._resume_failed = True
            self._session_id = new_sid
        except OSError:
            pass
