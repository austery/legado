"""Diagnostic-branch-only cold simulator startup; never substitutes for C1 tests."""
from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
import time
import threading

from simulator_diagnostics import capture_startup_failure

OUTPUT = Path("simulator-probe")
OUTPUT.mkdir(exist_ok=False)


def run(label: str, command: list[str], timeout: int = 30) -> str:
    started = time.monotonic()
    try:
        reply = subprocess.run(command, capture_output=True, text=True, check=True, timeout=timeout)
        output = reply.stdout
        status = {"returncode": reply.returncode}
    except (OSError, subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
        partial = getattr(error, "stdout", None) or ""
        output = partial.decode(errors="replace") if isinstance(partial, bytes) else partial
        status = {"error": str(error)}
        raise
    finally:
        elapsed = round(time.monotonic() - started, 3)
        (OUTPUT / f"{label}.txt").write_text(output)
        print(json.dumps({"step": label, "seconds": elapsed, **status}), flush=True)
        print(output[-12000:], flush=True)
    return output


def service_processes(label: str) -> list[int]:
    text = run(label, ["ps", "-ww", "-axo", "pid=,ppid=,state=,pcpu=,rss=,comm="], 15)
    rows = [line.split(None, 5) for line in text.splitlines()]
    candidates = [row for row in rows if len(row) == 6 and
                  (any(name in row[5] for name in ("CoreSimulatorService", "simdiskimaged")) or
                   (row[1] == str(os.getpid()) and row[5].endswith("/simctl")))]
    print(json.dumps({"serviceProcesses": candidates}), flush=True)
    return [int(row[0]) for row in candidates[:3]]


def during_start(stop: threading.Event, known: list[int]) -> None:
    if stop.wait(45):
        return
    print("[STARTUP-PROBE] during-start observation", flush=True)
    try:
        run("load-during-start", ["uptime"], 5)
        run("cpu-during-start", ["/usr/bin/top", "-l", "2", "-s", "1", "-n", "12", "-o", "cpu",
                                  "-stats", "pid,command,cpu,mem,state"], 10)
    except Exception as error:
        print(f"[STARTUP-PROBE] CPU observation unavailable: {error}", flush=True)
    for pid in known:
        if stop.is_set():
            break
        stack = OUTPUT / f"service-{pid}.sample.txt"
        try:
            run(f"sample-{pid}", ["/usr/bin/sample", str(pid), "3", "1", "-file", str(stack)], 8)
        except Exception as error:
            print(f"[STARTUP-PROBE] sample {pid} unavailable: {error}", flush=True)
        try:
            if stack.is_file():
                print(f"[STARTUP-PROBE] sample {pid}\n{stack.read_text(errors='replace')[:18000]}", flush=True)
        except OSError as error:
            print(f"[STARTUP-PROBE] sample output {pid} unavailable: {error}", flush=True)


print(json.dumps({key: os.environ.get(key) for key in ("ImageOS", "ImageVersion", "GITHUB_RUN_ID")}), flush=True)
simulator: str | None = None
monitor: threading.Thread | None = None
stop = threading.Event()
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
    try:
        known = service_processes("services-before-boot")
    except Exception as error:
        print(f"[STARTUP-PROBE] initial process list unavailable: {error}", flush=True)
        known = []
    monitor = threading.Thread(target=during_start, args=(stop, known), daemon=True)
    monitor.start()
    run("boot", ["xcrun", "simctl", "boot", simulator])
    run("bootstatus", ["xcrun", "simctl", "bootstatus", simulator, "-b"], 180)
    run("getenv", ["xcrun", "simctl", "getenv", simulator, "SIMULATOR_MODEL_IDENTIFIER"])
    print("ISOLATED STARTUP PASSED (not C1 acceptance)", flush=True)
except BaseException:
    if simulator and re.fullmatch(r"[A-Fa-f0-9-]{36}", simulator):
        try:
            capture_startup_failure(simulator, OUTPUT / "startup-diagnostics.json")
            print((OUTPUT / "startup-diagnostics.json").read_text(), flush=True)
        except Exception as error:
            print(f"Startup diagnostic unavailable: {error}", flush=True)
    try:
        run("processes-failure", ["ps", "-axo", "pid,ppid,state,%cpu,rss,comm"])
    except Exception as error:
        print(f"Process diagnostic unavailable: {error}", flush=True)
    raise
finally:
    stop.set()
    if monitor:
        monitor.join(timeout=45)
    if simulator and re.fullmatch(r"[A-Fa-f0-9-]{36}", simulator):
        for action in ("shutdown", "delete"):
            try:
                run(action, ["xcrun", "simctl", action, simulator], 60)
            except (OSError, subprocess.SubprocessError) as error:
                print(f"Owned simulator {action} failed: {error}", flush=True)
