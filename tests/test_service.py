from __future__ import annotations

import tempfile
import time
import unittest
from pathlib import Path

from server.offload.service import HarnessService, ValidationError


class HarnessServiceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.workspace = Path(self.temp_dir.name)
        self.service = HarnessService(self.workspace)

    def tearDown(self) -> None:
        self.service.close()
        self.temp_dir.cleanup()

    def test_create_topic_persists_core_files_and_feedback_request(self) -> None:
        detail = self.service.create_topic(
            title="Remote harness",
            raw_input="Build a remote harness for human and agent collaboration.",
            tags=["harness", "ios"],
        )
        topic_id = detail["topic"]["topic_id"]
        topic_dir = self.workspace / "topics" / topic_id
        self.assertTrue((topic_dir / "topic.md").exists())
        self.assertTrue((topic_dir / "requirement.md").exists())
        self.assertTrue((topic_dir / "plan.md").exists())
        self.assertTrue((topic_dir / "notes.md").exists())
        self.assertTrue((topic_dir / "state.json").exists())
        self.assertEqual(detail["topic"]["decision_state"], "needs_feedback")
        self.assertEqual(len(detail["feedback_requests"]), 1)
        self.assertIsNone(detail["parent_topic"])
        self.assertEqual(detail["child_topics"], [])

    def test_create_subtopic_inherits_parent_context(self) -> None:
        parent = self.service.create_topic(
            title="Parent Topic",
            raw_input="Build a remote harness for distributed topic orchestration.",
            tags=["harness", "remote"],
        )
        parent_id = parent["topic"]["topic_id"]
        child = self.service.create_topic(
            title="Child Topic",
            raw_input="Add subtopic support for shared context.",
            tags=["subtopic"],
            parent_topic_id=parent_id,
        )
        child_id = child["topic"]["topic_id"]
        self.assertEqual(child["topic"]["parent_topic_id"], parent_id)
        self.assertEqual(child["parent_topic"]["topic_id"], parent_id)
        self.assertIn("harness", child["topic"]["tags"])
        self.assertIn("subtopic", child["topic"]["tags"])
        self.assertEqual(child["child_topics"], [])
        self.assertIn("Parent Requirement Excerpt", child["documents"]["requirement.md"])
        self.assertIn("Parent Topic", child["documents"]["notes.md"])

        parent_detail = self.service.get_topic_detail(parent_id)
        self.assertEqual(len(parent_detail["child_topics"]), 1)
        self.assertEqual(parent_detail["child_topics"][0]["topic_id"], child_id)

    def test_double_approval_gate_is_required_before_execution(self) -> None:
        detail = self.service.create_topic(title="Approval flow", raw_input="Need approvals before execution.")
        topic_id = detail["topic"]["topic_id"]
        with self.assertRaises(ValidationError):
            self.service.trigger_run(topic_id, command=["/usr/bin/true"])
        self.service.approve_requirement(topic_id)
        with self.assertRaises(ValidationError):
            self.service.trigger_run(topic_id, command=["/usr/bin/true"])
        self.service.approve_plan(topic_id)
        run = self.service.trigger_run(topic_id, command=["/usr/bin/true"])
        self.assertEqual(run["status"], "queued")

    def test_run_writes_artifacts_and_updates_execution_state(self) -> None:
        detail = self.service.create_topic(title="Run flow", raw_input="Execute a command once approved.")
        topic_id = detail["topic"]["topic_id"]
        self.service.approve_requirement(topic_id)
        self.service.approve_plan(topic_id)
        run = self.service.trigger_run(topic_id, command=["/usr/bin/printf", "hello from offload"])
        self.assertEqual(run["status"], "queued")

        for _ in range(40):
            updated = self.service.get_topic_detail(topic_id)
            if updated["runs"] and updated["runs"][0]["status"] in {"succeeded", "failed"}:
                break
            time.sleep(0.05)

        updated = self.service.get_topic_detail(topic_id)
        self.assertEqual(updated["topic"]["execution_state"], "implemented")
        self.assertEqual(updated["topic"]["decision_state"], "needs_feedback")
        self.assertTrue(any(artifact.endswith("stdout.log") for artifact in updated["artifacts"]))

    def test_archive_requires_human_pass_confirmation(self) -> None:
        detail = self.service.create_topic(title="Archive flow", raw_input="Only archive after human pass.")
        topic_id = detail["topic"]["topic_id"]
        self.service.approve_requirement(topic_id)
        self.service.approve_plan(topic_id)
        self.service.trigger_run(topic_id, command=["/usr/bin/true"])

        for _ in range(40):
            updated = self.service.get_topic_detail(topic_id)
            if updated["topic"]["execution_state"] == "implemented":
                break
            time.sleep(0.05)

        with self.assertRaises(ValidationError):
            self.service.archive_topic(topic_id)
        with self.assertRaises(ValidationError):
            self.service.mark_passed(topic_id)

        updated = self.service.mark_human_testing(topic_id)
        self.assertEqual(updated["topic"]["execution_state"], "human_testing")

        updated = self.service.mark_passed(topic_id)
        self.assertEqual(updated["topic"]["execution_state"], "passed")

        updated = self.service.archive_topic(topic_id)
        self.assertEqual(updated["topic"]["decision_state"], "archived")

    def test_reindex_recovers_topics_from_workspace(self) -> None:
        detail = self.service.create_topic(title="Recovery", raw_input="Reindex state from files.")
        topic_id = detail["topic"]["topic_id"]
        self.service.close()
        self.service = HarnessService(self.workspace)
        topics = self.service.list_topics()
        self.assertEqual(len(topics), 1)
        self.assertEqual(topics[0]["topic_id"], topic_id)


if __name__ == "__main__":
    unittest.main()
