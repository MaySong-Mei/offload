"""Claude Code adapter — via Agent SDK bridge for structured streaming."""
from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Dict, List, Optional

from ._base import AgentEvent, EventCallback

# Path to the Node.js bridge script
_BRIDGE_SCRIPT = Path(__file__).parent.parent.parent / "cc-bridge.mjs"


class ClaudeCodeAdapter:
    """Drives Claude Code via the Agent SDK bridge (cc-bridge.mjs).

    The bridge outputs structured NDJSON events:
    - {"type":"text","text":"..."} — streaming text token
    - {"type":"tool_start","tool":"Read"} — tool call began
    - {"type":"tool_use","tool":"Read","input":{...}} — tool call with full input
    - {"type":"tool_result","content":"..."} — tool output
    - {"type":"result","result":"...","session_id":"..."} — final result
    """

    def __init__(self, skip_permissions: bool = True) -> None:
        self._cwd: Optional[Path] = None
        self._env: Optional[Dict[str, str]] = None
        self._session_id: Optional[str] = None
        self._proc: Optional[subprocess.Popen] = None
        self._skip_permissions = skip_permissions
        self._resume_failed = False

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

        cmd: List[str] = ["node", str(_BRIDGE_SCRIPT), str(self._cwd)]
        if self._session_id:
            cmd.extend(["--resume", self._session_id])
        cmd.append(message)

        self._proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            cwd=self._cwd,
        )

        result_text = ""
        expected_session_id = self._session_id
        self._resume_failed = False

        try:
            while True:
                line = self._proc.stdout.readline()
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

                if etype == "text":
                    text = data.get("text", "")
                    if text and on_event:
                        on_event(AgentEvent("text_output", {"text": text}))

                elif etype == "tool_start":
                    if on_event:
                        on_event(AgentEvent("tool_start", {
                            "tool": data.get("tool", ""),
                            "id": data.get("id", ""),
                        }))

                elif etype == "tool_use":
                    if on_event:
                        on_event(AgentEvent("tool_use", {
                            "tool": data.get("tool", ""),
                            "id": data.get("id", ""),
                            "input": data.get("input", {}),
                        }))

                elif etype == "tool_result":
                    if on_event:
                        on_event(AgentEvent("tool_result", {
                            "id": data.get("id", ""),
                            "content": data.get("content", ""),
                        }))

                elif etype == "result":
                    result_text = data.get("result", "")
                    sid = data.get("session_id")
                    if sid:
                        if expected_session_id and sid != expected_session_id:
                            self._resume_failed = True
                        self._session_id = sid
                    if on_event:
                        on_event(AgentEvent("done", {
                            "result": result_text,
                            "session_id": sid,
                            "cost": data.get("cost", 0),
                            "duration_ms": data.get("duration_ms", 0),
                        }))

                elif etype == "error":
                    if on_event:
                        on_event(AgentEvent("error", {"error": data.get("error", "")}))

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
