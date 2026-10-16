"""Build and run the ordinary Swift product suites on a new synthetic-only simulator."""
from __future__ import annotations

import argparse
from contextlib import contextmanager, ExitStack
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from threading import Thread
from typing import Iterator, cast

from boundary_fixture_server import BoundaryHandler
from ci_harness import Runtime, simctl
from fixture_server import FixtureServer

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine-ios/fixtures"))
from search_fixture_server import Handler as SearchHandler

# These suites require external process orchestration, not an ordinary XCTest run.
EXTERNAL_SUITES = {"ProcessInterruptionTests", "ShelfProcessRestartTests"}


def expected_tests() -> int:
    count = 0
    for path in (ROOT / "native-ios-app/Tests").glob("*Tests.swift"):
        if path.stem not in EXTERNAL_SUITES:
            methods = re.findall(r"^\s+func (test\w+)\(", path.read_text(), re.MULTILINE)
            if not methods:
                raise RuntimeError(f"No ordinary tests discovered in {path}")
            count += len(methods)
    if count == 0:
        raise RuntimeError("No Swift product tests discovered")
    return count


def validate_summary(summary: dict[str, object], expected: int) -> None:
    if (expected <= 0 or summary.get("passedTests") != expected
            or summary.get("totalTestCount") != expected
            or summary.get("failedTests") != 0 or summary.get("skippedTests") != 0):
        raise RuntimeError(f"Expected {expected} passed tests with no failures/skips: {summary}")


@contextmanager
def fixtures() -> Iterator[str]:
    with ExitStack() as stack:
        # Bind before launching anything. An occupied port fails without contacting
        # or terminating its owner. The existing reading tests require port 18769.
        reading = stack.enter_context(FixtureServer(("127.0.0.1", 18769), BoundaryHandler))
        search = stack.enter_context(FixtureServer(("127.0.0.1", 0), SearchHandler))
        for server in (reading, search):
            worker = Thread(target=server.serve_forever, daemon=True)
            worker.start()
            stack.callback(worker.join, 5)
            stack.callback(server.shutdown)
        yield f"http://127.0.0.1:{search.server_port}"


def configure_test_run(path: Path, fixture_url: str) -> Path:
    config = cast(dict[str, object], plistlib.loads(path.read_bytes()))
    configurations = config.get("TestConfigurations")
    if not isinstance(configurations, list):
        raise RuntimeError("Expected Xcode test configurations")
    found = 0
    for configuration in configurations:
        targets = configuration.get("TestTargets") if isinstance(configuration, dict) else None
        if not isinstance(targets, list):
            raise RuntimeError("Expected Xcode test targets")
        for target in targets:
            if not isinstance(target, dict) or target.get("BlueprintName") != "NativeReaderTests":
                continue
            environment = target.setdefault("EnvironmentVariables", {})
            if not isinstance(environment, dict):
                raise RuntimeError("Expected test environment dictionary")
            environment["SPEC004_FIXTURE_BASE"] = fixture_url
            found += 1
    if found != 1:
        raise RuntimeError(f"Expected one NativeReaderTests target, found {found}")
    # Keep __TESTROOT__ relative to the original Products directory.
    destination = path.with_name("native-product-ci.xctestrun")
    with destination.open("xb") as output:
        plistlib.dump(config, output)
    return destination


def run(command: list[str], log: Path, timeout: int) -> None:
    print(f"Running {log.name}", flush=True)
    with log.open("xb") as output:
        subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                       check=True, timeout=timeout)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    expected = expected_tests()
    (output / "scope.json").write_text(json.dumps({"expectedTests": expected,
        "externalSuitesNotRun": sorted(EXTERNAL_SUITES)}, indent=2))
    (output / "commit.txt").write_text(subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True))
    runtimes = cast(dict[str, list[Runtime]], json.loads(simctl("list", "runtimes", "--json")))
    available = [runtime for runtime in runtimes["runtimes"]
                 if runtime["isAvailable"] and ".iOS-" in runtime["identifier"]]
    if not available:
        raise RuntimeError("No available iOS simulator runtime")
    runtime = max(available, key=lambda item: tuple(int(part) for part in item["version"].split(".")))
    device_types = cast(dict[str, list[dict[str, str]]], json.loads(simctl("list", "devicetypes", "--json")))
    # Newer Xcode versions distinguish the M4 memory variants in their identifiers.
    tablets = [item["identifier"] for item in device_types["devicetypes"]
               if item["identifier"].startswith("com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4")]
    if not tablets:
        raise RuntimeError("No iPad Pro 11-inch M4 simulator device type")
    with fixtures() as fixture_url:
        simulator = simctl("create", "Native Product CI", tablets[0], runtime["identifier"])
        (output / "simulator.txt").write_text(f"{simulator}\n{runtime['identifier']}\n")
        try:
            run(["xcodegen", "generate", "--spec", "native-ios-app/project.yml"],
                output / "project.log", 60)
            derived = output / "DerivedData"
            run(["xcodebuild", "build-for-testing", "-project", "native-ios-app/NativeReader.xcodeproj",
                 "-scheme", "NativeReader", "-sdk", "iphonesimulator",
                 "-destination", f"platform=iOS Simulator,id={simulator}",
                 "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO"],
                output / "build.log", 900)
            test_runs = list((derived / "Build/Products").glob("*.xctestrun"))
            if len(test_runs) != 1:
                raise RuntimeError(f"Expected one generated test run, found {len(test_runs)}")
            config = configure_test_run(test_runs[0], fixture_url)
            result = output / "NativeReader.xcresult"
            simctl("boot", simulator)
            run(["xcrun", "simctl", "bootstatus", simulator, "-b"], output / "boot.log", 180)
            run(["xcodebuild", "test-without-building", "-xctestrun", str(config),
                 "-destination", f"platform=iOS Simulator,id={simulator}",
                 "-parallel-testing-enabled", "NO", "-resultBundlePath", str(result),
                 *[f"-skip-testing:NativeReaderTests/{suite}" for suite in sorted(EXTERNAL_SUITES)]],
                output / "tests.log", 1200)
            summary_text = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary",
                                                    "--path", str(result)], text=True, timeout=60)
            (output / "summary.json").write_text(summary_text)
            validate_summary(cast(dict[str, object], json.loads(summary_text)), expected)
            print(f"Native product: {expected} tests passed, no failures or skips", flush=True)
        finally:
            # Retain the owned simulator and evidence; never shut down an existing reader.
            subprocess.run(["xcrun", "simctl", "shutdown", simulator], check=False, timeout=60)


if __name__ == "__main__":
    main()
