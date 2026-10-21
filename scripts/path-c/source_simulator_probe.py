"""Diagnostic-branch-only cold simulator startup; never substitutes for C1 tests."""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path
import time

from simulator_diagnostics import capture_startup_failure

OUTPUT = Path("simulator-probe")
OUTPUT.mkdir(exist_ok=False)


def run(label: str, command: list[str], timeout: int = 30) -> str:
    started = time.monotonic()
    try:
        reply = subprocess.run(command, capture_output=True, text=True, check=True, timeout=timeout)
        output = reply.stdout
        status = {"returncode": reply.returncode}
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
        partial = error.stdout or ""
        output = partial.decode(errors="replace") if isinstance(partial, bytes) else partial
        status = {"error": str(error)}
        raise
    finally:
        elapsed = round(time.monotonic() - started, 3)
        (OUTPUT / f"{label}.txt").write_text(output)
        print(json.dumps({"step": label, "seconds": elapsed, **status}), flush=True)
        print(output[-12000:], flush=True)
    return output


simulator: str | None = None
try:
    run("commit", ["git", "rev-parse", "HEAD"])
    run("host", ["sw_vers"])
    run("xcode", ["xcodebuild", "-version"])
    run("memory", ["/usr/sbin/sysctl", "hw.memsize", "vm.swapusage"])
    run("processes-before", ["ps", "-axo", "pid,ppid,state,%cpu,rss,comm"])
    runtimes = json.loads(run("runtimes", ["xcrun", "simctl", "list", "runtimes", "--json"]))["runtimes"]
    runtime = next(item for item in runtimes if item["isAvailable"] and item["version"] == "27.0" and ".iOS-" in item["identifier"])
    simulator = run("create", ["xcrun", "simctl", "create", "Source startup probe", "com.apple.CoreSimulator.SimDeviceType.iPhone-16", runtime["identifier"]]).strip()
    if not re.fullmatch(r"[A-Fa-f0-9-]{36}", simulator):
        raise RuntimeError("Invalid owned simulator identity")
    (OUTPUT / "simulator.txt").write_text(simulator + "\n")
    run("boot", ["xcrun", "simctl", "boot", simulator])
    run("bootstatus", ["xcrun", "simctl", "bootstatus", simulator, "-b"], 180)
    run("getenv", ["xcrun", "simctl", "getenv", simulator, "SIMULATOR_MODEL_IDENTIFIER"])
    print("ISOLATED STARTUP PASSED (not C1 acceptance)", flush=True)
except BaseException:
    if simulator and re.fullmatch(r"[A-Fa-f0-9-]{36}", simulator):
        capture_startup_failure(simulator, OUTPUT / "startup-diagnostics.json")
        print((OUTPUT / "startup-diagnostics.json").read_text(), flush=True)
    run("processes-failure", ["ps", "-axo", "pid,ppid,state,%cpu,rss,comm"])
    raise
finally:
    if simulator and re.fullmatch(r"[A-Fa-f0-9-]{36}", simulator):
        for action in ("shutdown", "delete"):
            try:
                run(action, ["xcrun", "simctl", action, simulator], 60)
            except (OSError, subprocess.SubprocessError) as error:
                print(f"Owned simulator {action} failed: {error}", flush=True)
