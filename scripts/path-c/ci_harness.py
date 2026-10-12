"""Run the real C1 suites on a newly created simulator with owned fixtures."""
from __future__ import annotations

import argparse
from contextlib import ExitStack, contextmanager
import json
from pathlib import Path
import subprocess
import sys
import time
from typing import Iterator, TypedDict, cast
from urllib.request import urlopen


class Runtime(TypedDict):
    identifier: str
    version: str
    isAvailable: bool


def simctl(*args: str) -> str:
    return subprocess.check_output(["xcrun", "simctl", *args], text=True).strip()


def stop(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


@contextmanager
def fixtures(output: Path) -> Iterator[None]:
    with ExitStack() as stack:
        for script, port, endpoint in [("fixture_server.py", 18765, "/sources.json"),
                                       ("engine_fixture_server.py", 18767, "/engine-sources.json")]:
            print(f"Starting fixture {script} with {sys.executable}", flush=True)
            log = stack.enter_context((output / f"{port}-fixture.log").open("wb"))
            process = subprocess.Popen([sys.executable, "-u", str(Path(__file__).with_name(script))],
                                       stdout=log, stderr=subprocess.STDOUT)
            stack.callback(stop, process)
            deadline = time.monotonic() + 15
            while True:
                if process.poll() is not None:
                    raise RuntimeError(f"Fixture {script} exited before readiness")
                try:
                    with urlopen(f"http://127.0.0.1:{port}{endpoint}", timeout=1) as response:
                        response.read()
                    print(f"Fixture {script} ready", flush=True)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        subprocess.run(["sample", str(process.pid), "1", "-file",
                                        str(output / f"{port}-startup-stack.txt")],
                                       check=False, timeout=15)
                        raise RuntimeError(f"Fixture {script} did not become ready")
                    time.sleep(0.2)
        yield


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixtures-only", action="store_true")
    args = parser.parse_args()
    output: Path = args.output
    output.mkdir(parents=True, exist_ok=True)
    if args.fixtures_only:
        with fixtures(output):
            print("Fixture preflight passed", flush=True)
        return
    runtimes = cast(dict[str, list[Runtime]], json.loads(simctl("list", "runtimes", "--json")))
    available = [item for item in runtimes["runtimes"]
                 if item["isAvailable"] and ".iOS-" in item["identifier"]]
    if not available:
        raise SystemExit("No available iOS simulator runtime")
    runtime = max(available, key=lambda item: tuple(int(part) for part in item["version"].split(".")))
    simulator = simctl("create", "C1 Engine CI", "com.apple.CoreSimulator.SimDeviceType.iPhone-16",
                       runtime["identifier"])
    (output / "simulator.txt").write_text(f"{simulator}\n{runtime['identifier']}\n")
    try:
        with fixtures(output):
            # Ready fixtures before simulator startup competes for the hosted VM resources.
            simctl("boot", simulator)
            subprocess.run(["xcrun", "simctl", "bootstatus", simulator, "-b"], check=True, timeout=180)
            simctl("install", simulator,
                   "engine-ios/harness/build/Build/Products/Debug-iphonesimulator/PathCEngineHarness.app")
            for name, flags in [("full", []), ("restart", ["--persistence"]), ("rerun", [])]:
                subprocess.run([sys.executable, str(Path(__file__).with_name("run_harness.py")),
                                "--simulator", simulator, "--output", str(output / f"{name}.json"),
                                *flags], check=True, timeout=90)
    finally:
        # Only shut down the simulator created by this invocation. The hosted VM is disposable.
        subprocess.run(["xcrun", "simctl", "shutdown", simulator], check=False)


if __name__ == "__main__":
    main()
