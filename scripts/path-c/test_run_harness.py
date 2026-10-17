"""Preserve fresh-process and complete-report gates without a pre-launch terminate RPC."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import run_harness


class RunHarnessTests(unittest.TestCase):
    def setUp(self) -> None:
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.container = self.root / "container"
        (self.container / "Documents").mkdir(parents=True)
        self.output = self.root / "evidence.json"
        self.report = self.container / "Documents/results.json"
        self.checks: list[run_harness.Check] = [
            {"name": "suite-complete", "passed": True, "detail": ""}]
        self.calls: list[list[str]] = []

    def check_output(self, command: list[str], **kwargs: object) -> str:
        self.calls.append(command)
        if command[2] == "get_app_container":
            return str(self.container)
        self.assertEqual(command, ["xcrun", "simctl", "launch", "--terminate-running-process",
                                   "owned-device", "io.legado.pathc.engineharness"])
        self.report.write_text(json.dumps(self.checks))
        return "io.legado.pathc.engineharness: 123"

    def invoke(self, persistence: bool = False) -> int:
        arguments = ["run_harness", "--simulator", "owned-device", "--output", str(self.output)]
        if persistence:
            arguments.append("--persistence")
        with patch("sys.argv", arguments), \
                patch.object(run_harness.subprocess, "check_output", side_effect=self.check_output), \
                patch.object(run_harness.subprocess, "run", side_effect=subprocess.TimeoutExpired(
                    ["xcrun", "simctl", "terminate"], 30)) as terminate:
            result = run_harness.main()
            terminate.assert_not_called()
            return result

    def test_first_launch_succeeds_even_when_separate_terminate_would_hang(self) -> None:
        self.assertEqual(self.invoke(), 0)
        self.assertEqual(json.loads(self.output.read_text()), self.checks)
        self.assertEqual(len(self.calls), 2)

    def test_persistence_and_rerun_launch_new_processes_with_original_environment(self) -> None:
        for persistence in (True, False):
            with self.subTest(persistence=persistence), patch.dict(os.environ):
                os.environ["SIMCTL_CHILD_PATH_C_PERSISTENCE"] = "old"
                self.output = self.root / f"{persistence}.json"
                self.assertEqual(self.invoke(persistence), 0)
                self.assertEqual(os.environ.get("SIMCTL_CHILD_PATH_C_PERSISTENCE"),
                                 "1" if persistence else None)

    def test_failed_observation_still_fails_and_preserves_evidence(self) -> None:
        self.checks.insert(0, {"name": "regression", "passed": False, "detail": "failure"})
        self.assertEqual(self.invoke(), 1)
        self.assertEqual(json.loads(self.output.read_text()), self.checks)

    def test_incomplete_report_cannot_pass(self) -> None:
        self.checks = [{"name": "initialize", "passed": True, "detail": ""}]
        with patch.object(run_harness.time, "monotonic", side_effect=[0, 1, 61]), \
                patch.object(run_harness.time, "sleep"), self.assertRaisesRegex(SystemExit, "60 seconds"):
            self.invoke()
        self.assertFalse(self.output.exists())

    def test_stale_complete_report_cannot_pass(self) -> None:
        original = self.check_output

        def stale(command: list[str], **kwargs: object) -> str:
            result = original(command, **kwargs)
            if command[2] == "launch":
                os.utime(self.report, (1, 1))
            return result

        with patch.object(self, "check_output", side_effect=stale), \
                patch.object(run_harness.time, "monotonic", side_effect=[0, 1, 61]), \
                patch.object(run_harness.time, "sleep"), self.assertRaisesRegex(SystemExit, "60 seconds"):
            self.invoke()
        self.assertFalse(self.output.exists())

    def test_launch_failure_cannot_record_pass(self) -> None:
        with patch.object(self, "check_output", side_effect=subprocess.CalledProcessError(1, ["launch"])), \
                self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
