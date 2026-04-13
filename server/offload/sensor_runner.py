"""SensorRunner — scans .offload/sensors/, runs collection scripts on schedule, stores signals."""
from __future__ import annotations

import json
import subprocess
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

from .database import IndexStore
from .event_bus import EventBus
from .models import EventRecord, SensorRecord, SensorStatus, Signal, SignalSeverity, utc_now


class SensorRunner:
    """Manages sensor lifecycle: discovery, scheduling, execution, signal ingestion."""

    def __init__(self, store: IndexStore, event_bus: EventBus, project_paths: List[str]):
        self._store = store
        self._event_bus = event_bus
        self._project_paths = project_paths
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        """Start the background scheduler thread."""
        self._stop.clear()
        self._thread = threading.Thread(target=self._run_loop, daemon=True, name="sensor-runner")
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=5)

    def scan_and_register(self) -> List[SensorRecord]:
        """Discover sensors from .offload/sensors/*/manifest.yaml across all projects."""
        discovered = []
        for project_path in self._project_paths:
            sensors_dir = Path(project_path) / ".offload" / "sensors"
            if not sensors_dir.is_dir():
                continue
            for child in sensors_dir.iterdir():
                if not child.is_dir() or child.name.startswith("_"):
                    continue
                manifest = child / "manifest.yaml"
                if not manifest.is_file():
                    continue
                sensor = self._load_manifest(manifest, project_path)
                if sensor:
                    existing = self._store.get_sensor(sensor.sensor_id)
                    if existing is None:
                        self._store.upsert_sensor(sensor)
                    discovered.append(sensor)
        return discovered

    def list_sensors(self, project: Optional[str] = None) -> List[Dict[str, Any]]:
        return [s.to_json_dict() for s in self._store.list_sensors(project)]

    def list_signals(self, project: Optional[str] = None, sensor_id: Optional[str] = None, limit: int = 50) -> List[Dict[str, Any]]:
        return [s.to_json_dict() for s in self._store.list_signals(project, sensor_id, limit)]

    def ingest_signals(self, sensor_id: str, raw_signals: List[Dict[str, Any]]) -> int:
        """Manually ingest signals (e.g. from webhook). Returns count ingested."""
        sensor = self._store.get_sensor(sensor_id)
        if sensor is None:
            return 0
        count = 0
        for raw in raw_signals:
            signal = Signal(
                signal_id=f"sig-{uuid.uuid4().hex[:12]}",
                sensor_id=sensor_id,
                project=sensor.project,
                severity=SignalSeverity(raw.get("severity", "info")),
                title=raw.get("title", ""),
                detail=raw.get("detail", ""),
                count=raw.get("count", 1),
                source=raw.get("source", sensor.name),
                metadata=raw.get("metadata", {}),
            )
            self._store.insert_signal(signal)
            count += 1
        # Publish event
        if count > 0:
            self._publish_event("sensor.signals", sensor_id=sensor_id, payload={
                "sensor_id": sensor_id,
                "project": sensor.project,
                "count": count,
            })
        return count

    # --- Private ---

    def _run_loop(self) -> None:
        """Main scheduler loop. Checks every 60s which sensors are due."""
        while not self._stop.wait(timeout=60):
            try:
                self.scan_and_register()
                self._tick()
            except Exception as e:
                import traceback
                traceback.print_exc()

    def _tick(self) -> None:
        """Execute any sensors that are due based on their schedule."""
        now = datetime.now(timezone.utc)
        for sensor in self._store.list_sensors():
            if sensor.status != SensorStatus.ACTIVE:
                continue
            if not self._is_due(sensor, now):
                continue
            self._execute_sensor(sensor)

    def _execute_sensor(self, sensor: SensorRecord) -> None:
        """Run a sensor's collection script and ingest output."""
        sensor_dir = Path(sensor.sensor_path)
        run_script = sensor_dir / "run.sh"
        if not run_script.is_file():
            sensor.last_error = "run.sh not found"
            sensor.consecutive_failures += 1
            sensor.updated_at = utc_now()
            self._store.upsert_sensor(sensor)
            return

        try:
            result = subprocess.run(
                ["sh", str(run_script)],
                cwd=sensor_dir,
                capture_output=True,
                text=True,
                timeout=120,
            )
            sensor.last_run_at = utc_now()

            if result.returncode != 0:
                sensor.last_error = result.stderr[:500] if result.stderr else f"exit code {result.returncode}"
                sensor.consecutive_failures += 1
                if sensor.consecutive_failures >= 5:
                    sensor.status = SensorStatus.FAILED
                sensor.updated_at = utc_now()
                self._store.upsert_sensor(sensor)
                return

            # Parse stdout as JSON array of signals
            raw_signals = json.loads(result.stdout)
            if not isinstance(raw_signals, list):
                raw_signals = [raw_signals]

            self.ingest_signals(sensor.sensor_id, raw_signals)

            sensor.consecutive_failures = 0
            sensor.last_error = None
            sensor.updated_at = utc_now()
            self._store.upsert_sensor(sensor)

        except json.JSONDecodeError as e:
            sensor.last_error = f"Invalid JSON output: {e}"
            sensor.consecutive_failures += 1
            sensor.updated_at = utc_now()
            self._store.upsert_sensor(sensor)
        except subprocess.TimeoutExpired:
            sensor.last_error = "Collection timed out (120s)"
            sensor.consecutive_failures += 1
            sensor.updated_at = utc_now()
            self._store.upsert_sensor(sensor)
        except Exception as e:
            sensor.last_error = str(e)
            sensor.consecutive_failures += 1
            sensor.updated_at = utc_now()
            self._store.upsert_sensor(sensor)

    def _is_due(self, sensor: SensorRecord, now: datetime) -> bool:
        """Simple cron check: parse schedule and see if we should run."""
        if sensor.last_run_at is None:
            return True
        try:
            last = datetime.fromisoformat(sensor.last_run_at.replace("Z", "+00:00"))
        except (ValueError, TypeError):
            return True
        # Parse interval from schedule (support simple */N patterns)
        interval_minutes = self._parse_interval(sensor.schedule)
        elapsed = (now - last).total_seconds() / 60
        return elapsed >= interval_minutes

    @staticmethod
    def _parse_interval(schedule: str) -> int:
        """Parse a cron-like schedule to get interval in minutes.
        Supports: '*/N * * * *' (every N minutes), or defaults to 30.
        """
        parts = schedule.strip().split()
        if len(parts) >= 1:
            minute_part = parts[0]
            if minute_part.startswith("*/"):
                try:
                    return int(minute_part[2:])
                except ValueError:
                    pass
        return 30

    def _load_manifest(self, path: Path, project_path: str) -> Optional[SensorRecord]:
        """Load a manifest.yaml into a SensorRecord."""
        try:
            text = path.read_text()
            data = _parse_yaml_simple(text)
            name = data.get("name", path.parent.name)
            sensor_id = f"sensor-{name}-{Path(project_path).name}"
            return SensorRecord(
                sensor_id=sensor_id,
                project=project_path,
                name=name,
                description=data.get("description", ""),
                status=SensorStatus(data.get("status", "active")),
                schedule=data.get("schedule", "*/30 * * * *"),
                source_topic_id=data.get("created_by"),
                sensor_path=str(path.parent),
            )
        except Exception:
            return None

    def _publish_event(self, event_type: str, sensor_id: str = "", payload: Optional[Dict[str, Any]] = None) -> None:
        event = EventRecord(
            event_id=f"evt-{uuid.uuid4().hex[:12]}",
            event_type=event_type,
            payload=payload or {},
        )
        self._store.append_event(event)
        self._event_bus.publish(event)


def _parse_yaml_simple(text: str) -> Dict[str, str]:
    """Minimal YAML parser for flat key: value manifests. No dependency needed."""
    result: Dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" in line:
            key, _, value = line.partition(":")
            key = key.strip()
            value = value.strip().strip("'\"")
            if value:
                result[key] = value
    return result
