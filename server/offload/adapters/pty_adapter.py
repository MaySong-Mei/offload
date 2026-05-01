"""PTY adapter — universal fallback for any CLI agent."""
from __future__ import annotations

import os
import pty
import select
import signal
import time
from pathlib import Path
from typing import Dict, Optional

from ._base import AgentEvent, EventCallback


class PTYAdapter:
    """Drives any CLI agent through a pty.

    The orchestrator treats all output as raw text — no structured parsing.
    """

    def __init__(self, shell_command: str = "/bin/zsh") -> None:
        self._shell = shell_command
        self._cwd: Optional[Path] = None
        self._child_pid: Optional[int] = None
        self._master_fd: Optional[int] = None

    # -- AgentAdapter interface ------------------------------------------------

    def start(self, cwd: Path, env: Optional[Dict[str, str]] = None) -> None:
        self._cwd = cwd
        pid, fd = pty.fork()
        if pid == 0:
            # Child
            os.chdir(str(cwd))
            if env:
                os.environ.update(env)
            os.execvpe(self._shell, [self._shell, "-l"], os.environ)
            os._exit(1)
        self._child_pid = pid
        self._master_fd = fd

    def send(
        self,
        message: str,
        on_event: Optional[EventCallback] = None,
    ) -> str:
        if self._master_fd is None:
            raise RuntimeError("Adapter not started")

        # Write instruction + newline
        os.write(self._master_fd, (message + "\n").encode())

        # Collect output until idle (no new data for 2s)
        collected = []
        idle_timeout = 2.0
        last_data = time.monotonic()

        while True:
            elapsed = time.monotonic() - last_data
            if elapsed >= idle_timeout:
                break
            remaining = idle_timeout - elapsed
            readable, _, _ = select.select([self._master_fd], [], [], min(remaining, 0.1))
            if self._master_fd in readable:
                try:
                    data = os.read(self._master_fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                text = data.decode("utf-8", errors="replace")
                collected.append(text)
                last_data = time.monotonic()
                if on_event:
                    on_event(AgentEvent("text_output", {"text": text}))

        return "".join(collected)

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
                os.waitpid(self._child_pid, 0)
            except OSError:
                pass
            self._child_pid = None

    @property
    def is_running(self) -> bool:
        if self._child_pid is None:
            return False
        try:
            pid, status = os.waitpid(self._child_pid, os.WNOHANG)
            return pid == 0
        except ChildProcessError:
            return False

    @property
    def session_id(self) -> Optional[str]:
        return None
