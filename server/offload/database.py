from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import List, Optional

from .models import EventRecord, FeedbackRequest, FeedbackResponse, RunRecord, SensorRecord, Signal, TopicState


class IndexStore:
    def __init__(self, path: Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(self.path, check_same_thread=False)
        self.connection.row_factory = sqlite3.Row
        self._bootstrap()

    def _bootstrap(self) -> None:
        cursor = self.connection.cursor()
        cursor.executescript(
            """
            PRAGMA journal_mode=WAL;

            CREATE TABLE IF NOT EXISTS topics (
                topic_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                summary TEXT NOT NULL,
                raw_input TEXT NOT NULL,
                parent_topic_id TEXT,
                tags_json TEXT NOT NULL,
                priority TEXT NOT NULL,
                project_name TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                requirement_state TEXT NOT NULL,
                execution_state TEXT NOT NULL,
                decision_state TEXT NOT NULL,
                requirement_approved_at TEXT,
                plan_approved_at TEXT,
                latest_run_id TEXT,
                pending_feedback_request_id TEXT,
                assigned_executor TEXT,
                workspace_path TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS feedback_requests (
                request_id TEXT PRIMARY KEY,
                topic_id TEXT NOT NULL,
                request_type TEXT NOT NULL,
                title TEXT NOT NULL,
                prompt TEXT NOT NULL,
                options_json TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL,
                resolved_at TEXT,
                allow_note INTEGER NOT NULL,
                metadata_json TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS feedback_responses (
                response_id TEXT PRIMARY KEY,
                request_id TEXT NOT NULL,
                topic_id TEXT NOT NULL,
                selected_options_json TEXT NOT NULL,
                note TEXT NOT NULL,
                actor TEXT NOT NULL,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS runs (
                run_id TEXT PRIMARY KEY,
                topic_id TEXT NOT NULL,
                executor TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                finished_at TEXT,
                summary TEXT NOT NULL,
                command_json TEXT NOT NULL,
                artifacts_json TEXT NOT NULL,
                exit_code INTEGER,
                error TEXT
            );

            CREATE TABLE IF NOT EXISTS events (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id TEXT NOT NULL UNIQUE,
                event_type TEXT NOT NULL,
                topic_id TEXT,
                run_id TEXT,
                created_at TEXT NOT NULL,
                payload_json TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS sensors (
                sensor_id TEXT PRIMARY KEY,
                project TEXT NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'building',
                schedule TEXT NOT NULL DEFAULT '*/30 * * * *',
                source_topic_id TEXT,
                sensor_path TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                last_run_at TEXT,
                last_error TEXT,
                consecutive_failures INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS signals (
                signal_id TEXT PRIMARY KEY,
                sensor_id TEXT NOT NULL,
                project TEXT NOT NULL,
                severity TEXT NOT NULL DEFAULT 'info',
                title TEXT NOT NULL DEFAULT '',
                detail TEXT NOT NULL DEFAULT '',
                count INTEGER NOT NULL DEFAULT 1,
                source TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                metadata_json TEXT NOT NULL DEFAULT '{}'
            );

            CREATE INDEX IF NOT EXISTS idx_topics_updated ON topics(updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_topics_parent ON topics(parent_topic_id, updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_feedback_requests_topic ON feedback_requests(topic_id, status);
            CREATE INDEX IF NOT EXISTS idx_runs_topic ON runs(topic_id, created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_sensors_project ON sensors(project, status);
            CREATE INDEX IF NOT EXISTS idx_signals_sensor ON signals(sensor_id, created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_signals_project ON signals(project, created_at DESC);
            """
        )
        self._ensure_column("topics", "parent_topic_id", "TEXT")
        self.connection.commit()

    def _ensure_column(self, table_name: str, column_name: str, definition: str) -> None:
        columns = {
            row["name"]
            for row in self.connection.execute(f"PRAGMA table_info({table_name})").fetchall()
        }
        if column_name not in columns:
            self.connection.execute(f"ALTER TABLE {table_name} ADD COLUMN {column_name} {definition}")

    def close(self) -> None:
        self.connection.close()

    def upsert_topic(self, state: TopicState) -> None:
        self.connection.execute(
            """
            INSERT INTO topics (
                topic_id, title, summary, raw_input, parent_topic_id, tags_json, priority, project_name,
                created_at, updated_at, requirement_state, execution_state, decision_state,
                requirement_approved_at, plan_approved_at, latest_run_id,
                pending_feedback_request_id, assigned_executor, workspace_path
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(topic_id) DO UPDATE SET
                title=excluded.title,
                summary=excluded.summary,
                raw_input=excluded.raw_input,
                parent_topic_id=excluded.parent_topic_id,
                tags_json=excluded.tags_json,
                priority=excluded.priority,
                project_name=excluded.project_name,
                created_at=excluded.created_at,
                updated_at=excluded.updated_at,
                requirement_state=excluded.requirement_state,
                execution_state=excluded.execution_state,
                decision_state=excluded.decision_state,
                requirement_approved_at=excluded.requirement_approved_at,
                plan_approved_at=excluded.plan_approved_at,
                latest_run_id=excluded.latest_run_id,
                pending_feedback_request_id=excluded.pending_feedback_request_id,
                assigned_executor=excluded.assigned_executor,
                workspace_path=excluded.workspace_path
            """,
            (
                state.topic_id,
                state.title,
                state.summary,
                state.raw_input,
                state.parent_topic_id,
                json.dumps(state.tags),
                state.priority,
                state.project,
                state.created_at,
                state.updated_at,
                state.requirement_state.value,
                state.execution_state.value,
                state.decision_state.value,
                state.requirement_approved_at,
                state.plan_approved_at,
                state.latest_run_id,
                state.pending_feedback_request_id,
                state.assigned_executor,
                state.workspace_path,
            ),
        )
        self.connection.commit()

    def get_topic(self, topic_id: str) -> Optional[TopicState]:
        row = self.connection.execute("SELECT * FROM topics WHERE topic_id = ?", (topic_id,)).fetchone()
        if row is None:
            return None
        return TopicState.from_json_dict(
            {
                "topic_id": row["topic_id"],
                "title": row["title"],
                "summary": row["summary"],
                "raw_input": row["raw_input"],
                "parent_topic_id": row["parent_topic_id"],
                "tags": json.loads(row["tags_json"]),
                "priority": row["priority"],
                "project": row["project_name"],
                "created_at": row["created_at"],
                "updated_at": row["updated_at"],
                "requirement_state": row["requirement_state"],
                "execution_state": row["execution_state"],
                "decision_state": row["decision_state"],
                "requirement_approved_at": row["requirement_approved_at"],
                "plan_approved_at": row["plan_approved_at"],
                "latest_run_id": row["latest_run_id"],
                "pending_feedback_request_id": row["pending_feedback_request_id"],
                "assigned_executor": row["assigned_executor"],
                "workspace_path": row["workspace_path"],
            }
        )

    def list_topics(self) -> List[TopicState]:
        rows = self.connection.execute("SELECT * FROM topics ORDER BY updated_at DESC").fetchall()
        return [self.get_topic(row["topic_id"]) for row in rows if row is not None]

    def list_child_topics(self, parent_topic_id: str) -> List[TopicState]:
        rows = self.connection.execute(
            "SELECT topic_id FROM topics WHERE parent_topic_id = ? ORDER BY updated_at DESC",
            (parent_topic_id,),
        ).fetchall()
        return [self.get_topic(row["topic_id"]) for row in rows if row is not None]

    def upsert_feedback_request(self, request: FeedbackRequest) -> None:
        self.connection.execute(
            """
            INSERT INTO feedback_requests (
                request_id, topic_id, request_type, title, prompt, options_json, status,
                created_at, resolved_at, allow_note, metadata_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(request_id) DO UPDATE SET
                topic_id=excluded.topic_id,
                request_type=excluded.request_type,
                title=excluded.title,
                prompt=excluded.prompt,
                options_json=excluded.options_json,
                status=excluded.status,
                created_at=excluded.created_at,
                resolved_at=excluded.resolved_at,
                allow_note=excluded.allow_note,
                metadata_json=excluded.metadata_json
            """,
            (
                request.request_id,
                request.topic_id,
                request.request_type.value,
                request.title,
                request.prompt,
                json.dumps(request.options),
                request.status.value,
                request.created_at,
                request.resolved_at,
                1 if request.allow_note else 0,
                json.dumps(request.metadata),
            ),
        )
        self.connection.commit()

    def get_feedback_request(self, request_id: str) -> Optional[FeedbackRequest]:
        row = self.connection.execute("SELECT * FROM feedback_requests WHERE request_id = ?", (request_id,)).fetchone()
        if row is None:
            return None
        return FeedbackRequest.from_json_dict(
            {
                "request_id": row["request_id"],
                "topic_id": row["topic_id"],
                "request_type": row["request_type"],
                "title": row["title"],
                "prompt": row["prompt"],
                "options": json.loads(row["options_json"]),
                "status": row["status"],
                "created_at": row["created_at"],
                "resolved_at": row["resolved_at"],
                "allow_note": bool(row["allow_note"]),
                "metadata": json.loads(row["metadata_json"]),
            }
        )

    def list_feedback_requests(self, topic_id: Optional[str] = None, pending_only: bool = False) -> List[FeedbackRequest]:
        query = "SELECT request_id FROM feedback_requests"
        clauses = []
        params = []
        if topic_id:
            clauses.append("topic_id = ?")
            params.append(topic_id)
        if pending_only:
            clauses.append("status = ?")
            params.append("pending")
        if clauses:
            query += " WHERE " + " AND ".join(clauses)
        query += " ORDER BY created_at DESC"
        rows = self.connection.execute(query, params).fetchall()
        return [self.get_feedback_request(row["request_id"]) for row in rows if row is not None]

    def insert_feedback_response(self, response: FeedbackResponse) -> None:
        self.connection.execute(
            """
            INSERT OR REPLACE INTO feedback_responses (
                response_id, request_id, topic_id, selected_options_json, note, actor, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                response.response_id,
                response.request_id,
                response.topic_id,
                json.dumps(response.selected_options),
                response.note,
                response.actor,
                response.created_at,
            ),
        )
        self.connection.commit()

    def list_feedback_responses(self, topic_id: str) -> List[FeedbackResponse]:
        rows = self.connection.execute(
            "SELECT * FROM feedback_responses WHERE topic_id = ? ORDER BY created_at ASC",
            (topic_id,),
        ).fetchall()
        return [
            FeedbackResponse.from_json_dict({
                "response_id": r["response_id"],
                "request_id": r["request_id"],
                "topic_id": r["topic_id"],
                "selected_options": json.loads(r["selected_options_json"]),
                "note": r["note"],
                "actor": r["actor"],
                "created_at": r["created_at"],
            })
            for r in rows
        ]

    def upsert_run(self, run: RunRecord) -> None:
        self.connection.execute(
            """
            INSERT INTO runs (
                run_id, topic_id, executor, status, created_at, updated_at, finished_at,
                summary, command_json, artifacts_json, exit_code, error
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(run_id) DO UPDATE SET
                topic_id=excluded.topic_id,
                executor=excluded.executor,
                status=excluded.status,
                created_at=excluded.created_at,
                updated_at=excluded.updated_at,
                finished_at=excluded.finished_at,
                summary=excluded.summary,
                command_json=excluded.command_json,
                artifacts_json=excluded.artifacts_json,
                exit_code=excluded.exit_code,
                error=excluded.error
            """,
            (
                run.run_id,
                run.topic_id,
                run.executor,
                run.status.value,
                run.created_at,
                run.updated_at,
                run.finished_at,
                run.summary,
                json.dumps(run.command),
                json.dumps(run.artifacts),
                run.exit_code,
                run.error,
            ),
        )
        self.connection.commit()

    def get_run(self, run_id: str) -> Optional[RunRecord]:
        row = self.connection.execute("SELECT * FROM runs WHERE run_id = ?", (run_id,)).fetchone()
        if row is None:
            return None
        return RunRecord.from_json_dict(
            {
                "run_id": row["run_id"],
                "topic_id": row["topic_id"],
                "executor": row["executor"],
                "status": row["status"],
                "created_at": row["created_at"],
                "updated_at": row["updated_at"],
                "finished_at": row["finished_at"],
                "summary": row["summary"],
                "command": json.loads(row["command_json"]),
                "artifacts": json.loads(row["artifacts_json"]),
                "exit_code": row["exit_code"],
                "error": row["error"],
            }
        )

    def list_runs(self, topic_id: str) -> List[RunRecord]:
        rows = self.connection.execute("SELECT run_id FROM runs WHERE topic_id = ? ORDER BY created_at DESC", (topic_id,)).fetchall()
        return [self.get_run(row["run_id"]) for row in rows if row is not None]

    def append_event(self, event: EventRecord) -> EventRecord:
        cursor = self.connection.execute(
            """
            INSERT INTO events (event_id, event_type, topic_id, run_id, created_at, payload_json)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                event.event_id,
                event.event_type,
                event.topic_id,
                event.run_id,
                event.created_at,
                json.dumps(event.payload),
            ),
        )
        event.sequence = cursor.lastrowid
        self.connection.commit()
        return event

    # --- Sensors ---

    def upsert_sensor(self, sensor: SensorRecord) -> None:
        self.connection.execute(
            """
            INSERT INTO sensors (
                sensor_id, project, name, description, status, schedule,
                source_topic_id, sensor_path, created_at, updated_at,
                last_run_at, last_error, consecutive_failures
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(sensor_id) DO UPDATE SET
                name=excluded.name, description=excluded.description,
                status=excluded.status, schedule=excluded.schedule,
                sensor_path=excluded.sensor_path, updated_at=excluded.updated_at,
                last_run_at=excluded.last_run_at, last_error=excluded.last_error,
                consecutive_failures=excluded.consecutive_failures
            """,
            (
                sensor.sensor_id, sensor.project, sensor.name, sensor.description,
                sensor.status.value, sensor.schedule, sensor.source_topic_id,
                sensor.sensor_path, sensor.created_at, sensor.updated_at,
                sensor.last_run_at, sensor.last_error, sensor.consecutive_failures,
            ),
        )
        self.connection.commit()

    def get_sensor(self, sensor_id: str) -> Optional[SensorRecord]:
        row = self.connection.execute("SELECT * FROM sensors WHERE sensor_id = ?", (sensor_id,)).fetchone()
        if row is None:
            return None
        return SensorRecord.from_json_dict(dict(row))

    def list_sensors(self, project: Optional[str] = None) -> List[SensorRecord]:
        if project:
            rows = self.connection.execute(
                "SELECT * FROM sensors WHERE project = ? ORDER BY created_at DESC", (project,)
            ).fetchall()
        else:
            rows = self.connection.execute("SELECT * FROM sensors ORDER BY created_at DESC").fetchall()
        return [SensorRecord.from_json_dict(dict(r)) for r in rows]

    def insert_signal(self, signal: Signal) -> None:
        self.connection.execute(
            """
            INSERT INTO signals (
                signal_id, sensor_id, project, severity, title, detail,
                count, source, created_at, metadata_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                signal.signal_id, signal.sensor_id, signal.project,
                signal.severity.value, signal.title, signal.detail,
                signal.count, signal.source, signal.created_at,
                json.dumps(signal.metadata),
            ),
        )
        self.connection.commit()

    def list_signals(self, project: Optional[str] = None, sensor_id: Optional[str] = None, limit: int = 50) -> List[Signal]:
        query = "SELECT * FROM signals"
        clauses, params = [], []
        if project:
            clauses.append("project = ?")
            params.append(project)
        if sensor_id:
            clauses.append("sensor_id = ?")
            params.append(sensor_id)
        if clauses:
            query += " WHERE " + " AND ".join(clauses)
        query += " ORDER BY created_at DESC LIMIT ?"
        params.append(limit)
        rows = self.connection.execute(query, params).fetchall()
        return [
            Signal.from_json_dict({
                **dict(r),
                "metadata": json.loads(r["metadata_json"]),
            })
            for r in rows
        ]

    # --- Events ---

    def list_events(self, after_sequence: int = 0, limit: int = 200) -> List[EventRecord]:
        rows = self.connection.execute(
            "SELECT * FROM events WHERE sequence > ? ORDER BY sequence ASC LIMIT ?",
            (after_sequence, limit),
        ).fetchall()
        return [
            EventRecord.from_json_dict(
                {
                    "sequence": row["sequence"],
                    "event_id": row["event_id"],
                    "event_type": row["event_type"],
                    "topic_id": row["topic_id"],
                    "run_id": row["run_id"],
                    "created_at": row["created_at"],
                    "payload": json.loads(row["payload_json"]),
                }
            )
            for row in rows
        ]
