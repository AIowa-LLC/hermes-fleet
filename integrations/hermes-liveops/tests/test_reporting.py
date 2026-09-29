import asyncio
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

spec = importlib.util.spec_from_file_location(
    "fleet_liveops_plugin", Path(__file__).parents[1] / "dashboard" / "plugin_api.py")
plugin = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = plugin
spec.loader.exec_module(plugin)


class ReportingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def payload(self, key, runtime="same-runtime", timestamp=100):
        return {"schema": 1, "written_at": timestamp, "sessions": [{
            "id": f"fleet:{key}:{runtime}", "session_key": f"stored-{key}",
            "status": "working", "last_active": timestamp, "subagents": []}]}

    def test_two_desktop_processes_with_same_runtime_id_remain_distinct(self):
        plugin.publish(self.root, self.payload("a"), publisher="a")
        plugin.publish(self.root, self.payload("b"), publisher="b")
        result = plugin.aggregate(self.root, 101)
        self.assertEqual(result["publishers"], 2)
        self.assertEqual({row["id"] for row in result["sessions"]},
                         {"fleet:a:same-runtime", "fleet:b:same-runtime"})
        self.assertEqual((self.root / "a.json").stat().st_mode & 0o777, 0o600)

    def test_stale_crashed_reporter_is_not_live(self):
        plugin.publish(self.root, self.payload("stale", timestamp=90), publisher="stale")
        plugin.publish(self.root, self.payload("current"), publisher="current")
        result = plugin.aggregate(self.root, 101)
        self.assertEqual(result["publishers"], 1)
        self.assertEqual(len(result["sessions"]), 1)
        self.assertEqual(result["sessions"][0]["session_key"], "stored-current")
        self.assertEqual(result["stale_publishers"], 0)
        # A still-running process whose publisher stalled is unavailable
        # coverage, rather than evidence that its previously live run finished.
        with patch.object(plugin, "publisher_alive", return_value=True):
            self.assertEqual(plugin.aggregate(self.root, 101)["stale_publishers"], 1)

    def test_corrupt_future_and_symlink_reports_are_ignored(self):
        (self.root / "corrupt.json").write_text("{")
        plugin.publish(self.root, self.payload("future", timestamp=200), publisher="future")
        target = self.root / "target.txt"
        target.write_text(json.dumps(self.payload("link")))
        (self.root / "link.json").symlink_to(target)
        self.assertEqual(plugin.aggregate(self.root, 101)["publishers"], 0)

    def test_delegation_joins_durable_owner_and_does_not_publish_private_handles(self):
        server = SimpleNamespace(
            _sessions_lock=threading.Lock(),
            _sessions={"rt": {}, "closed": {"_finalized": True}},
            _session_live_item=lambda sid, session: {
                "session_key": "stored-parent", "status": "idle", "last_active": 100,
                "cwd": "private-workspace", "transport": "private-transport"})
        registry = SimpleNamespace(list_active_subagents=lambda: [{
            "owner_agent_session_id": "stored-parent", "subagent_id": "child",
            "status": "running", "goal": "Synthetic task", "agent": "private-handle"},
            {"owner_agent_session_id": "unrelated", "subagent_id": "other"}])
        result = plugin.collect_process_snapshot(server, registry, 100)
        self.assertEqual(len(result["sessions"]), 1)
        row = result["sessions"][0]
        self.assertEqual(row["status"], "idle")
        self.assertEqual(row["subagents"][0]["subagent_id"], "child")
        self.assertNotIn("private-", json.dumps(result))
        self.assertNotIn("owner_agent_session_id", row["subagents"][0])

    def test_included_router_lifespan_starts_and_stops_publisher(self):
        events = []

        async def fake_publisher(root):
            events.append("start")
            plugin.publish(root, self.payload("current", timestamp=plugin.time.time()))
            try:
                await asyncio.Future()
            finally:
                events.append("stop")

        app = FastAPI()
        app.include_router(plugin.router, prefix="/api/plugins/fleet-liveops")
        with patch.object(plugin, "reporting_directory", return_value=self.root), \
                patch.object(plugin, "publisher_loop", fake_publisher):
            with TestClient(app) as client:
                result = client.get("/api/plugins/fleet-liveops/snapshot")
                self.assertEqual(result.status_code, 200)
                self.assertEqual(result.json()["publishers"], 1)
            self.assertEqual(events, ["start", "stop"])


if __name__ == "__main__":
    unittest.main()
