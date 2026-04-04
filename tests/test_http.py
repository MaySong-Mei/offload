from __future__ import annotations

import json
import tempfile
import threading
import time
import unittest
import urllib.request
from pathlib import Path

from server.offload.http import create_http_server
from server.offload.service import HarnessService


class HarnessHTTPTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.workspace = Path(self.temp_dir.name)
        self.service = HarnessService(self.workspace)
        try:
            self.server = create_http_server("127.0.0.1", 0, self.service)
        except PermissionError:
            self.service.close()
            self.temp_dir.cleanup()
            self.skipTest("Socket binding is not permitted in this sandbox.")
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        time.sleep(0.05)

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.service.close()
        self.temp_dir.cleanup()

    def request(self, method: str, path: str, payload=None):
        data = None
        headers = {}
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}",
            data=data,
            headers=headers,
            method=method,
        )
        with urllib.request.urlopen(request) as response:
            return response.status, json.loads(response.read().decode("utf-8"))

    def test_topic_creation_and_listing_via_http(self) -> None:
        status, detail = self.request(
            "POST",
            "/topics",
            {"title": "HTTP topic", "raw_input": "Create a topic over HTTP.", "tags": ["api"]},
        )
        self.assertEqual(status, 201)
        topic_id = detail["topic"]["topic_id"]
        status, listing = self.request("GET", "/topics")
        self.assertEqual(status, 200)
        self.assertEqual(listing["topics"][0]["topic_id"], topic_id)

    def test_subtopic_creation_via_http(self) -> None:
        _, parent = self.request(
            "POST",
            "/topics",
            {"title": "Parent", "raw_input": "Parent topic over HTTP.", "tags": ["root"]},
        )
        parent_id = parent["topic"]["topic_id"]
        status, child = self.request(
            "POST",
            f"/topics/{parent_id}/subtopics",
            {"title": "Child", "raw_input": "Child topic over HTTP.", "tags": ["child"]},
        )
        self.assertEqual(status, 201)
        self.assertEqual(child["topic"]["parent_topic_id"], parent_id)
        self.assertEqual(child["parent_topic"]["topic_id"], parent_id)

    def test_run_endpoint_requires_approvals(self) -> None:
        _, detail = self.request("POST", "/topics", {"title": "Gate", "raw_input": "Needs approval."})
        topic_id = detail["topic"]["topic_id"]
        with self.assertRaises(urllib.error.HTTPError) as context:
            self.request("POST", f"/topics/{topic_id}/runs", {"executor": "command", "command": ["/usr/bin/true"]})
        self.assertEqual(context.exception.code, 422)

    def test_archive_endpoint_requires_passed_state(self) -> None:
        _, detail = self.request("POST", "/topics", {"title": "Archive Gate", "raw_input": "Archive only after pass."})
        topic_id = detail["topic"]["topic_id"]
        with self.assertRaises(urllib.error.HTTPError) as context:
            self.request("POST", f"/topics/{topic_id}/archive", {})
        self.assertEqual(context.exception.code, 422)


if __name__ == "__main__":
    unittest.main()
