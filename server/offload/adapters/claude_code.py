"""Claude Code adapter — first-class streaming via --include-partial-messages."""
from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Dict, List, Optional

from ._base import AgentEvent, EventCallback


class ClaudeCodeAdapter:
    """Drives Claude Code CLI with true token-level streaming.

    Uses ``--include-partial-messages`` with ``stream-json`` to get
    ``content_block_delta`` events containing individual text tokens.
    """

    def __init__(self, skip_permissions: bool = True) -> None:
        self._cwd: Optional[Path] = None
        self._env: Optional[Dict[str, str]] = None
        self._session_id: Optional[str] = None
        self._proc: Optional[subprocess.Popen] = None
        self._skip_permissions = skip_permissions
        self._resume_failed = False  # set if --resume produced a new session

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
        cmd.extend([
            "-p", message,
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ])
        if self._skip_permissions:
            cmd.append("--dangerously-skip-permissions")

        # Include .offload/ CLAUDE.md for harness context
        offload_dir = self._cwd / ".offload"
        if offload_dir.is_dir():
            cmd.extend(["--add-dir", str(offload_dir)])

        self._proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,  # line-buffered
            cwd=self._cwd,
        )

        result_text = ""
        expected_session_id = self._session_id  # the id we're trying to resume
        self._resume_failed = False
        # Track current tool_use for input accumulation
        _current_tool_name: Optional[str] = None
        _current_tool_input: List[str] = []
        try:
            while True:
                line = self._proc.stdout.readline()  # type: ignore[union-attr]
                if not line:
                    break
                line = line.strip()
                if not line:
                    continue
                try:
                    data = json.loads(line)
                except json.JSONDecodeError:
                    continue

                etype = data.get("type", "")

                if etype == "stream_event":
                    evt = data.get("event", {})
                    evt_type = evt.get("type", "")

                    if evt_type == "content_block_start":
                        block = evt.get("content_block", {})
                        if block.get("type") == "tool_use":
                            _current_tool_name = block.get("name", "")
                            _current_tool_input = []

                    elif evt_type == "content_block_delta":
                        delta = evt.get("delta", {})
                        if delta.get("type") == "text_delta":
                            text = delta.get("text", "")
                            if text and on_event:
                                on_event(AgentEvent("text_output", {"text": text}))
                        elif delta.get("type") == "input_json_delta":
                            _current_tool_input.append(delta.get("partial_json", ""))

                    elif evt_type == "content_block_stop":
                        # Emit tool_use event with parsed input
                        if _current_tool_name and on_event:
                            input_str = "".join(_current_tool_input)
                            input_preview = ""
                            try:
                                parsed = json.loads(input_str)
                                # Extract the most useful field for display
                                input_preview = (
                                    parsed.get("file_path")
                                    or parsed.get("command")
                                    or parsed.get("pattern")
                                    or parsed.get("query")
                                    or str(parsed)[:100]
                                )
                            except json.JSONDecodeError:
                                input_preview = input_str[:100]
                            on_event(AgentEvent("tool_use", {
                                "tool": _current_tool_name,
                                "input_preview": str(input_preview)[:150],
                            }))
                            _current_tool_name = None
                            _current_tool_input = []

                    # Capture session_id from any stream_event
                    sid = data.get("session_id")
                    if sid:
                        self._session_id = sid

                elif etype == "result":
                    result_text = data.get("result", "")
                    sid = data.get("session_id")
                    if sid:
                        # Detect resume failure: we asked for old_id but got a new one
                        if expected_session_id and sid != expected_session_id:
                            self._resume_failed = True
                        self._session_id = sid
                    if on_event:
                        on_event(AgentEvent("done", {
                            "result": result_text,
                            "session_id": sid,
                        }))

            self._proc.wait(timeout=600)
        except subprocess.TimeoutExpired:
            self._proc.kill()
            if on_event:
                on_event(AgentEvent("error", {"error": "Agent timed out after 600s"}))
        finally:
            self._proc = None

        return result_text

    def stop(self) -> None:
        proc = self._proc
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        self._proc = None

    @property
    def is_running(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    @property
    def session_id(self) -> Optional[str]:
        return self._session_id

    @property
    def resume_failed(self) -> bool:
        return self._resume_failed
