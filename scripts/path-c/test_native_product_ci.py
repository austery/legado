"""Guard against green CI with missing tests, missing fixture setup, or a foreign server."""
from contextlib import ExitStack
import json
from pathlib import Path
import subprocess
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import native_product_ci
from fixture_server import FixtureServer, Handler
from native_product_ci import configure_test_run, expected_tests, fixtures, validate_summary


class NativeProductGateTest(unittest.TestCase):
    def test_missing_failed_or_skipped_tests_cannot_pass(self) -> None:
        valid: dict[str, object] = {"passedTests": 29, "totalTestCount": 29,
                                   "failedTests": 0, "skippedTests": 0}
        validate_summary(valid, 29)
        for change in ({"passedTests": 0}, {"passedTests": 28}, {"failedTests": 1},
                       {"skippedTests": 1}, {"totalTestCount": 30}):
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                validate_summary({**valid, **change}, 29)
        with self.assertRaises(RuntimeError):
            validate_summary({}, 29)
        self.assertGreater(expected_tests(), 0)

    def test_fixture_environment_preserves_generated_runner_settings(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "generated.xctestrun"
            config = {"TestConfigurations": [{"TestTargets": [{"BlueprintName": "NativeReaderTests",
                "TestHostPath": "__TESTROOT__/NativeReader.app",
                "EnvironmentVariables": {"EXISTING": "preserved"}}]}]}
            original = plistlib.dumps(config)
            path.write_bytes(original)
            configured = configure_test_run(path, "http://127.0.0.1:12345")
            result = plistlib.loads(configured.read_bytes())["TestConfigurations"][0]["TestTargets"][0]
            self.assertEqual(result["EnvironmentVariables"],
                             {"EXISTING": "preserved", "SPEC004_FIXTURE_BASE": "http://127.0.0.1:12345"})
            self.assertEqual(result["TestHostPath"], "__TESTROOT__/NativeReader.app")
            self.assertEqual(path.read_bytes(), original)

    def test_missing_product_target_fails_before_running_tests(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "generated.xctestrun"
            path.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": []}]}))
            with self.assertRaises(RuntimeError):
                configure_test_run(path, "http://127.0.0.1:12345")

    def test_occupied_reading_port_is_not_reused_or_terminated(self) -> None:
        with FixtureServer(("127.0.0.1", 18769), Handler) as foreign:
            with self.assertRaises(OSError), fixtures():
                self.fail("Must not use an existing fixture server")
            self.assertEqual(foreign.socket.getsockname(), ("127.0.0.1", 18769))


class ProcessOnlyModeTest(unittest.TestCase):
    def test_fresh_build_then_both_process_suites_without_ordinary_fixtures(self) -> None:
        self.exercise_mode(fail_interruption=False)

    def test_process_failure_propagates_without_running_later_suite(self) -> None:
        self.exercise_mode(fail_interruption=True)

    def exercise_mode(self, fail_interruption: bool) -> None:
        commands: list[list[str]] = []
        simulator = "00000000-0000-0000-0000-000000000001"
        def fake_simctl(*args: str) -> str:
            if args[:2] == ("list", "runtimes"):
                return json.dumps({"runtimes": [{"isAvailable": True, "version": "27.0",
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0"}]})
            if args[:2] == ("list", "devicetypes"):
                return json.dumps({"devicetypes": [{"identifier":
                    "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4"}]})
            if args[0] == "create":
                return simulator
            self.fail(f"Unexpected simulator operation: {args}")

        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            output = Path(directory).resolve() / "result"
            def fake_run(command: list[str], log: Path, timeout: int) -> None:
                commands.append(command)
                if "build-for-testing" in command:
                    products = output / "DerivedData/Build/Products"
                    products.mkdir(parents=True)
                    (products / "fresh.xctestrun").write_bytes(b"fresh-build")
                if fail_interruption and log.name == "interruption.log":
                    raise subprocess.CalledProcessError(1, command)

            stack.enter_context(patch.object(native_product_ci.sys, "argv", ["native_product_ci.py",
                "--output", str(output), "--process-tests-only", "--runtime-version", "27.0"]))
            stack.enter_context(patch.object(native_product_ci, "simctl", side_effect=fake_simctl))
            stack.enter_context(patch.object(native_product_ci, "run", side_effect=fake_run))
            cleanup = stack.enter_context(patch.object(native_product_ci, "delete_owned_simulator"))
            fixture = stack.enter_context(patch.object(native_product_ci, "fixtures"))
            ordinary = stack.enter_context(patch.object(native_product_ci, "expected_tests"))
            stack.enter_context(patch.object(native_product_ci.subprocess, "check_output", return_value="head\n"))
            if fail_interruption:
                with self.assertRaises(subprocess.CalledProcessError):
                    native_product_ci.main()
            else:
                native_product_ci.main()
            fixture.assert_not_called()
            ordinary.assert_not_called()
            cleanup.assert_called_once_with(simulator)
            self.assertEqual(commands[1][1], "build-for-testing")
            process_commands = commands[2:]
            self.assertEqual(len(process_commands), 1 if fail_interruption else 2)
            for command in process_commands:
                self.assertTrue(command[1].endswith("process_interruption_regression.py"))
                self.assertIn(str(output / "DerivedData/Build/Products/fresh.xctestrun"), command)
                self.assertEqual(command[-2:], ["--runtime-version", "27.0"])
                self.assertNotIn("--case", command)  # Every declared reading and group boundary remains required.
            self.assertNotIn("--shelf-restart", process_commands[0])
            if not fail_interruption:
                self.assertIn("--shelf-restart", process_commands[1])


if __name__ == "__main__":
    unittest.main()
