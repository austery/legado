"""Temporary test devices are removed without touching caller-owned simulators."""
from contextlib import nullcontext
import io
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import ci_harness
import native_product_ci
import process_interruption_regression as interruption

DEVICE = "11111111-1111-1111-1111-111111111111"
RUNTIME = {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
           "version": "27.0", "isAvailable": True}


class SimulatorCleanupTests(unittest.TestCase):
    def test_shutdown_timeout_still_deletes_exact_device(self) -> None:
        with patch.object(ci_harness.subprocess, "run", side_effect=[
                subprocess.TimeoutExpired("shutdown", 60),
                subprocess.CompletedProcess([], 0)]) as run, patch("sys.stderr", new_callable=io.StringIO):
            ci_harness.delete_owned_simulator(DEVICE)
        self.assertEqual([c.args[0] for c in run.call_args_list], [
            ["xcrun", "simctl", "shutdown", DEVICE], ["xcrun", "simctl", "delete", DEVICE]])

    def test_rejects_global_and_non_uuid_selectors(self) -> None:
        with patch.object(ci_harness.subprocess, "run") as run:
            for selector in ("all", "booted", "", "existing-reader"):
                with self.subTest(selector=selector), self.assertRaises(ValueError):
                    ci_harness.delete_owned_simulator(selector)
            run.assert_not_called()

    def test_delete_failure_fails_successful_run(self) -> None:
        failure = subprocess.CalledProcessError(1, ["simctl", "delete"])
        with patch.object(ci_harness.subprocess, "run", side_effect=[
                subprocess.CompletedProcess([], 0), failure]), patch("sys.stderr", new_callable=io.StringIO) as log:
            with self.assertRaises(subprocess.CalledProcessError):
                ci_harness.delete_owned_simulator(DEVICE)
            self.assertIn(DEVICE, log.getvalue())

    def test_delete_failure_preserves_original_test_error(self) -> None:
        failure = subprocess.CalledProcessError(1, ["simctl", "delete"])
        with patch.object(ci_harness.subprocess, "run", side_effect=[
                subprocess.CompletedProcess([], 0), failure]), patch("sys.stderr", new_callable=io.StringIO) as log:
            with self.assertRaisesRegex(RuntimeError, "test failed"):
                try:
                    raise RuntimeError("test failed")
                finally:
                    ci_harness.delete_owned_simulator(DEVICE)
            self.assertIn("may remain", log.getvalue())

    def test_c1_cleans_up_on_success_test_failure_and_manifest_failure(self) -> None:
        for outcome in ("success", "test failure", "manifest failure", "interrupt"):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as folder:
                with patch("sys.argv", ["ci_harness", "--output", folder]), \
                        patch.object(ci_harness, "simctl", side_effect=[json.dumps({"runtimes": [RUNTIME]}), DEVICE, "", ""]), \
                        patch.object(ci_harness, "fixtures", return_value=nullcontext()), \
                        patch.object(ci_harness.subprocess, "run") as run:
                    # bootstatus and three harness invocations precede cleanup.
                    if outcome == "test failure":
                        run.side_effect = [RuntimeError("test failed"), None, None]
                    elif outcome == "interrupt":
                        run.side_effect = [KeyboardInterrupt(), None, None]
                    if outcome == "manifest failure":
                        with patch.object(Path, "write_text", side_effect=OSError("disk full")), self.assertRaises(OSError):
                            ci_harness.main()
                    elif outcome == "test failure":
                        with self.assertRaisesRegex(RuntimeError, "test failed"):
                            ci_harness.main()
                    elif outcome == "interrupt":
                        with self.assertRaises(KeyboardInterrupt):
                            ci_harness.main()
                    else:
                        ci_harness.main()
                    self.assertEqual([c.args[0] for c in run.call_args_list[-2:]], [
                        ["xcrun", "simctl", "shutdown", DEVICE], ["xcrun", "simctl", "delete", DEVICE]])

    def test_product_build_failure_cleans_up_without_removing_host_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "evidence"
            with patch("sys.argv", ["native_product_ci", "--output", str(output)]), \
                    patch.object(native_product_ci, "fixtures", return_value=nullcontext("http://fixture")), \
                    patch.object(native_product_ci, "expected_tests", return_value=1), \
                    patch.object(native_product_ci.subprocess, "check_output", return_value="test-commit"), \
                    patch.object(native_product_ci, "simctl", side_effect=[
                        json.dumps({"runtimes": [RUNTIME]}),
                        json.dumps({"devicetypes": [{"identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4"}]}), DEVICE]), \
                    patch.object(native_product_ci, "run", side_effect=RuntimeError("build failed")), \
                    patch.object(ci_harness.subprocess, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "build failed"):
                    native_product_ci.main()
                self.assertTrue((output / "simulator.txt").is_file())
                self.assertTrue((output / "scope.json").is_file())
                self.assertEqual(run.call_args.args[0], ["xcrun", "simctl", "delete", DEVICE])

    def test_interruption_boot_failure_deletes_owned_device_with_original_environment(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder) / "generated.xctestrun"
            config.write_bytes(plistlib.dumps({}))
            with patch.dict(interruption.os.environ, {"DEVELOPER_DIR": "/test/selected-xcode/Contents/Developer"}), \
                    patch("sys.argv", ["interruption", "--xctestrun", str(config), "--output", str(Path(folder) / "evidence")]), \
                    patch.object(interruption, "validate_template"), \
                    patch.object(interruption, "FixtureServer") as server, \
                    patch.object(interruption, "simctl", side_effect=[json.dumps({"runtimes": [RUNTIME]}), DEVICE, RuntimeError("boot failed")]), \
                    patch.object(ci_harness.subprocess, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "boot failed"):
                    interruption.main()
                self.assertEqual(run.call_args.args[0], ["xcrun", "simctl", "delete", DEVICE])
                self.assertEqual(run.call_args.kwargs["env"]["DEVELOPER_DIR"], "/test/selected-xcode/Contents/Developer")
                server.return_value.server_close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
