from __future__ import annotations

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from server.offload.executors import ClaudeExecutor, CommandExecutor
from server.offload.agents._base import build_prompt_from_docs


class TestCommandExecutor(unittest.TestCase):
    def test_name(self) -> None:
        self.assertEqual(CommandExecutor.name, "command")

    def test_execute_echo(self) -> None:
        with TemporaryDirectory() as tmpdir:
            executor = CommandExecutor()
            result = executor.execute(Path(tmpdir), command=["/usr/bin/printf", "hello"])
            self.assertEqual(result.exit_code, 0)
            self.assertEqual(result.stdout, "hello")
            self.assertIsNone(result.error)
            self.assertIn("artifacts/latest/stdout.log", result.artifacts)

    def test_execute_failure(self) -> None:
        with TemporaryDirectory() as tmpdir:
            executor = CommandExecutor()
            result = executor.execute(Path(tmpdir), command=["/usr/bin/false"])
            self.assertNotEqual(result.exit_code, 0)
            self.assertIsNotNone(result.error)

    def test_execute_accepts_context(self) -> None:
        """Context param is accepted but ignored by CommandExecutor."""
        with TemporaryDirectory() as tmpdir:
            executor = CommandExecutor()
            result = executor.execute(Path(tmpdir), command=["/usr/bin/true"], context={"workspace_dir": "/tmp"})
            self.assertEqual(result.exit_code, 0)


class TestClaudeExecutor(unittest.TestCase):
    def test_name(self) -> None:
        self.assertEqual(ClaudeExecutor.name, "claude")

    def test_missing_binary(self) -> None:
        """When claude is not in PATH, should return a graceful failure."""
        with TemporaryDirectory() as tmpdir:
            executor = ClaudeExecutor()
            # Use a non-existent path to ensure claude won't be found
            import os
            old_path = os.environ.get("PATH", "")
            os.environ["PATH"] = "/nonexistent"
            try:
                result = executor.execute(Path(tmpdir), command=["say hello"])
                self.assertEqual(result.exit_code, 127)
                self.assertIn("not found", result.error or "")
            finally:
                os.environ["PATH"] = old_path

    def test_build_prompt_from_docs(self) -> None:
        with TemporaryDirectory() as tmpdir:
            topic_path = Path(tmpdir)
            (topic_path / "requirement.md").write_text("Build a REST API")
            (topic_path / "plan.md").write_text("Step 1: Create endpoints")

            prompt = build_prompt_from_docs(topic_path)
            self.assertIn("Build a REST API", prompt)
            self.assertIn("Step 1: Create endpoints", prompt)
            self.assertIn("Requirement", prompt)
            self.assertIn("Plan", prompt)

    def test_build_prompt_no_docs(self) -> None:
        with TemporaryDirectory() as tmpdir:
            prompt = build_prompt_from_docs(Path(tmpdir))
            self.assertIn("No requirement or plan", prompt)

    def test_workspace_dir_from_context(self) -> None:
        """When context provides workspace_dir, it should be used as cwd."""
        with TemporaryDirectory() as tmpdir:
            executor = ClaudeExecutor()
            import os
            old_path = os.environ.get("PATH", "")
            os.environ["PATH"] = "/nonexistent"
            try:
                # Even though claude won't be found, verify the context is accepted
                result = executor.execute(
                    Path(tmpdir),
                    command=["test prompt"],
                    context={"workspace_dir": tmpdir},
                )
                self.assertEqual(result.exit_code, 127)
            finally:
                os.environ["PATH"] = old_path

    def test_timeout_value(self) -> None:
        self.assertEqual(ClaudeExecutor.timeout, 600)


if __name__ == "__main__":
    unittest.main()
