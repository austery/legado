"""Require the upstream URI suite to execute successfully in C1's JVM task."""
from pathlib import Path
import xml.etree.ElementTree as ET


def validate_report(root: Path) -> int:
    report = root / "data/build/test-results/jvmTest/TEST-io.legado.app.utils.UriCanonicalTest.xml"
    if not report.is_file():
        raise RuntimeError("Missing upstream URI regression report")
    cases = list(ET.parse(report).getroot().iter("testcase"))
    if not cases or any(case.find(tag) is not None for case in cases
                        for tag in ("failure", "error", "skipped")):
        raise RuntimeError("Missing, failed or skipped upstream URI regressions")
    return len(cases)


if __name__ == "__main__":
    print(f"Upstream URI regressions passed: {validate_report(Path(__file__).resolve().parents[2])}")
