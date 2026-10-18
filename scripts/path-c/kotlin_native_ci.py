"""Run Kotlin/Native suites on one invocation-owned simulator and reject empty reports."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

from ci_harness import delete_owned_simulator, simctl
from native_product_ci import fixtures

ROOT = Path(__file__).resolve().parents[2]
MODULES = ("data", "core", "engine-ios")


def validate_reports(root: Path) -> dict[str, int]:
    counts: dict[str, int] = {}
    for module in MODULES:
        files = list((root / module / "build/test-results/iosSimulatorArm64Test").glob("TEST-*.xml"))
        cases = [case for path in files for case in ET.parse(path).getroot().iter("testcase")]
        if not cases or any(case.find(tag) is not None for case in cases for tag in ("failure", "error", "skipped")):
            raise RuntimeError(f"{module}: missing, failed or skipped Kotlin/Native tests")
        if module == "data" and not any("NativeJsConcurrentScopeTest" in case.get("classname", "") for case in cases):
            raise RuntimeError("Missing native JS concurrency regression suite")
        counts[module] = len(cases)
    return counts


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runtime-version")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    runtimes = json.loads(simctl("list", "runtimes", "--json"))["runtimes"]
    available = [r for r in runtimes if r["isAvailable"] and ".iOS-" in r["identifier"]
                 and (not args.runtime_version or r["version"] == args.runtime_version)]
    if not available:
        raise RuntimeError("Required iOS simulator runtime unavailable")
    runtime = max(available, key=lambda r: tuple(map(int, r["version"].split("."))))
    simulator = simctl("create", "Kotlin Native CI", "com.apple.CoreSimulator.SimDeviceType.iPhone-16", runtime["identifier"])
    try:
        (output / "simulator.txt").write_text(simulator + "\n")
        simctl("boot", simulator)
        subprocess.run(["xcrun", "simctl", "bootstatus", simulator, "-b"], check=True, timeout=180)
        command = ["./gradlew", "--no-daemon", "--no-watch-fs", "--build-cache", "--max-workers=2",
                   "-Dorg.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=1g -Dfile.encoding=UTF-8",
                   *[f":{module}:iosSimulatorArm64Test" for module in MODULES]]
        with fixtures() as fixture_url, (output / "tests.log").open("x") as log:
            subprocess.run(command, cwd=ROOT, env=dict(os.environ, C1_NATIVE_SIMULATOR=simulator,
                           SPEC004_FIXTURE_BASE=fixture_url, SIMCTL_CHILD_SPEC004_FIXTURE_BASE=fixture_url),
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=2400)
        counts = validate_reports(ROOT)
        (output / "summary.json").write_text(json.dumps(counts, indent=2))
        print(f"Kotlin/Native tests passed: {counts}", flush=True)
    finally:
        delete_owned_simulator(simulator)


if __name__ == "__main__":
    main()
