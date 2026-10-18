"""A skipped or absent upstream URL suite cannot silently satisfy C1."""
from pathlib import Path
import tempfile
import unittest

from verify_url_tests import validate_report


class UrlReportTests(unittest.TestCase):
    def test_requires_nonempty_successful_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(RuntimeError):
                validate_report(root)
            report = root / "data/build/test-results/jvmTest/TEST-io.legado.app.utils.UriCanonicalTest.xml"
            report.parent.mkdir(parents=True)
            for body in ("", "<testcase><failure/></testcase>", "<testcase><error/></testcase>",
                         "<testcase><skipped/></testcase>"):
                report.write_text(f"<testsuite>{body}</testsuite>")
                with self.subTest(body=body), self.assertRaises(RuntimeError):
                    validate_report(root)
            report.write_text('<testsuite><testcase name="uri"/></testsuite>')
            self.assertEqual(1, validate_report(root))
