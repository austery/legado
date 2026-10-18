"""Missing, skipped or failed native suites must not satisfy C1."""
from pathlib import Path
import tempfile
import unittest

from kotlin_native_ci import MODULES, validate_reports


class NativeReportTests(unittest.TestCase):
    def test_all_modules_require_executed_successful_tests(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(RuntimeError):
                validate_reports(root)
            for module in MODULES:
                folder = root / module / 'build/test-results/iosSimulatorArm64Test'
                folder.mkdir(parents=True)
                (folder / 'TEST-suite.xml').write_text(
                    '<testsuite><testcase classname="NativeJsConcurrentScopeTest" name="nested"/></testsuite>')
            self.assertEqual(validate_reports(root), dict.fromkeys(MODULES, 1))
            report = root / 'data/build/test-results/iosSimulatorArm64Test/TEST-suite.xml'
            for body in ('', '<testcase classname="Other"/>',
                         '<testcase classname="NativeJsConcurrentScopeTest"><failure/></testcase>',
                         '<testcase classname="NativeJsConcurrentScopeTest"><skipped/></testcase>'):
                report.write_text(f'<testsuite>{body}</testsuite>')
                with self.subTest(body=body), self.assertRaises(RuntimeError):
                    validate_reports(root)
