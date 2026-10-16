"""Guard against green CI with missing tests, missing fixture setup, or a foreign server."""
from pathlib import Path
import plistlib
import tempfile
import unittest

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


if __name__ == "__main__":
    unittest.main()
