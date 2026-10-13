"""Run the already-built, isolated Swift harness and require a complete passing report."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from pathlib import Path
from typing import TypedDict, cast


class Check(TypedDict):
    name: str
    passed: bool
    detail: str


def simctl(*args: str) -> str:
    print(f"simctl {' '.join(args)}", flush=True)
    return subprocess.check_output(["xcrun", "simctl", *args], text=True, timeout=120).strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--persistence", action="store_true")
    args = parser.parse_args()
    bundle = "io.legado.pathc.engineharness"
    output: Path = args.output
    if output.exists():
        raise SystemExit("Output already exists; choose a new evidence path")
    # This tool only terminates its dedicated test application, never a reader app.
    print("Terminating previous harness process", flush=True)
    subprocess.run(["xcrun", "simctl", "terminate", args.simulator, bundle],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False, timeout=30)
    container = Path(simctl("get_app_container", args.simulator, bundle, "data"))
    report = container / "Documents" / "results.json"
    started = time.time()
    if args.persistence:
        os.environ["SIMCTL_CHILD_PATH_C_PERSISTENCE"] = "1"
    else:
        os.environ.pop("SIMCTL_CHILD_PATH_C_PERSISTENCE", None)
    print(simctl("launch", args.simulator, bundle), flush=True)
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if report.exists() and report.stat().st_mtime >= started:
            checks = cast(list[Check], json.loads(report.read_text()))
            if checks and checks[-1]["name"] == "suite-complete":
                output.parent.mkdir(parents=True, exist_ok=True)
                with output.open("x") as stream:
                    json.dump(checks, stream, indent=2, ensure_ascii=False)
                    stream.write("\n")
                failures = [item for item in checks if not item["passed"]]
                for item in failures:
                    print(f"FAIL {item['name']}: {item['detail']}")
                print(f"{len(checks) - len(failures)}/{len(checks)} observations passed; {output}")
                return 1 if failures else 0
        time.sleep(0.25)
    raise SystemExit("Harness did not finish within 60 seconds; no pass recorded")


if __name__ == "__main__":
    raise SystemExit(main())
