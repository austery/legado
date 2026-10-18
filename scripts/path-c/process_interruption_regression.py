"""Kill only the explicitly dedicated synthetic test host at four storage boundaries."""
from __future__ import annotations

import argparse
import copy
import datetime
from typing import Dict, List, Union
import json
import os
from pathlib import Path
import plistlib
import subprocess
import threading
import time
import uuid

from c2_fixture_server import C2Handler
from fixture_server import FixtureServer

from ci_harness import delete_owned_simulator, simctl
from native_product_ci import validate_summary


def validate_template(template: dict, root: Path) -> None:
    targets = [target for config in template["TestConfigurations"] for target in config["TestTargets"]]
    if len(targets) != 1 or targets[0].get("BlueprintName") != "NativeReaderTests":
        raise ValueError("Only the synthetic NativeReaderTests host is permitted")
    host = Path(targets[0]["TestHostPath"].replace("__TESTROOT__", str(root.resolve())))
    host = host.resolve()
    if not host.is_relative_to(root.resolve()) or host.name != "NativeReader.app":
        raise ValueError("Test host must be the generated synthetic app under TESTROOT")
    info = plistlib.loads((host / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE:
        raise ValueError("Unexpected test host bundle")


def owned_documents(container: str, simulator: str) -> Path:
    value = Path(container.strip()).resolve()
    expected = (Path.home() / "Library/Developer/CoreSimulator/Devices" / simulator / "data/Containers/Data/Application").resolve()
    if value.parent != expected:
        raise ValueError("Container is outside the newly created simulator")
    return value / "Documents"
BUNDLE = "io.legado.pathc.nativereader"
PlistValue = Union[str, int, float, bool, bytes, datetime.datetime, List["PlistValue"], Dict[str, "PlistValue"]]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xctestrun", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--shelf-restart", action="store_true", help="Run the two-process offline shelf journey instead of interruption cases")
    parser.add_argument("--case", choices=("before-file", "after-file", "before-db", "after-db"), action="append")
    parser.add_argument("--runtime-version", help="Require this exact iOS runtime")
    args = parser.parse_args()
    template = plistlib.loads(args.xctestrun.read_bytes())
    validate_template(template, args.xctestrun.parent)
    args.output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ)
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    gate = threading.Event()
    phase_by_run: dict[str, str] = {}

    class Handler(C2Handler):
        def do_GET(self) -> None:
            parts = self.path.split("/")
            run = parts[2] if len(parts) > 2 else ""
            if phase_by_run.get(run) == "before-file" and self.path.endswith("/chapter/2"):
                (args.output / (run + ".network-ready")).write_text(self.path)
                gate.wait(60)
            super().do_GET()

    server = FixtureServer(("127.0.0.1", 18771), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    simulator = ""

    def relocate(value: object) -> PlistValue:
        if isinstance(value, str):
            return value.replace("__TESTROOT__", str(args.xctestrun.parent.resolve()))
        if isinstance(value, list):
            return [relocate(item) for item in value]
        if isinstance(value, dict):
            if not all(isinstance(key, str) for key in value):
                raise TypeError("Property list keys must be strings")
            return {str(key): relocate(item) for key, item in value.items()}
        if isinstance(value, (int, float, bool, bytes, datetime.datetime)):
            return value
        raise TypeError("Unsupported property list value")

    def run_config(run: str, phase: str, mode: str) -> Path:
        config = relocate(copy.deepcopy(template))
        if not isinstance(config, dict):
            raise TypeError("Expected property list dictionary")
        configurations = config["TestConfigurations"]
        if not isinstance(configurations, list):
            raise TypeError("Expected test configuration list")
        for configuration in configurations:
            if not isinstance(configuration, dict) or not isinstance(configuration["TestTargets"], list):
                raise TypeError("Expected test target list")
            for target in configuration["TestTargets"]:
                if not isinstance(target, dict):
                    raise TypeError("Expected test target dictionary")
                environment = target.setdefault("EnvironmentVariables", {})
                if not isinstance(environment, dict):
                    raise TypeError("Expected test environment dictionary")
                if phase == "restart":
                    environment["SPEC003_RESTART_PHASE"] = mode
                environment.update({
                    "SPEC003_INTERRUPT_RUN": run,
                    "SPEC003_INTERRUPT_CASE": phase,
                    "SPEC003_INTERRUPT_MODE": mode,
                })
        path = args.output / f"{phase}-{mode}.xctestrun"
        path.write_bytes(plistlib.dumps(config))
        return path

    def command(config: Path, method: str) -> list[str]:
        return ["xcodebuild", "test-without-building", "-xctestrun", str(config),
                "-destination", "platform=iOS Simulator,id=" + simulator,
                "-only-testing:NativeReaderTests/" + method,
                "-parallel-testing-enabled", "NO", "-derivedDataPath", str(args.output / "DerivedData"),
                "-resultBundlePath", str(config.with_suffix(".xcresult"))]

    def require_one_pass(config: Path) -> None:
        summary = json.loads(subprocess.check_output(
            ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(config.with_suffix(".xcresult"))],
            text=True, env=env, timeout=60))
        validate_summary(summary, 1)
        config.with_suffix(".summary.json").write_text(json.dumps(summary, indent=2))

    results = []
    process: subprocess.Popen[bytes] | None = None
    try:
        runtimes = json.loads(simctl("list", "runtimes", "--json"))["runtimes"]
        available = [item for item in runtimes if item["isAvailable"] and ".iOS-" in item["identifier"]]
        if args.runtime_version:
            available = [item for item in available if item["version"] == args.runtime_version]
        if not available:
            raise RuntimeError("Required iOS simulator runtime unavailable")
        runtime = max(available, key=lambda item: tuple(map(int, item["version"].split("."))))
        simulator = simctl("create", "Native Boundary Interruption " + str(uuid.uuid4()),
                           "com.apple.CoreSimulator.SimDeviceType.iPhone-16", runtime["identifier"])
        uuid.UUID(simulator)
        (args.output / "simulator.txt").write_text(simulator + "\n")
        simctl("boot", simulator)
        subprocess.run(["xcrun", "simctl", "bootstatus", simulator, "-b"], check=True, env=env, timeout=180)
        if args.shelf_restart:
            reading = FixtureServer(("127.0.0.1", 18769), C2Handler)
            worker = threading.Thread(target=reading.serve_forever, daemon=True)
            worker.start()
            try:
                config = run_config(str(uuid.uuid4()), "restart", "prepare")
                with (args.output / "restart-prepare.log").open("w") as log:
                    subprocess.run(command(config, "ShelfProcessRestartTests/testPrepare"), stdout=log,
                                   stderr=subprocess.STDOUT, env=env, check=True, timeout=300)
                require_one_pass(config)
            finally:
                reading.shutdown(); reading.server_close(); worker.join(5)
            # No reading listener exists in this process during offline verification.
            config = run_config(str(uuid.uuid4()), "restart", "verify")
            with (args.output / "restart-verify.log").open("w") as log:
                subprocess.run(command(config, "ShelfProcessRestartTests/testVerify"), stdout=log,
                               stderr=subprocess.STDOUT, env=env, check=True, timeout=300)
            require_one_pass(config)
            (args.output / "results.json").write_text(json.dumps({"prepare": "passed", "offlineVerify": "passed"}))
            return
        for phase in args.case or ["before-file", "after-file", "before-db", "after-db"]:
            gate.clear()
            run = str(uuid.uuid4()).upper()
            phase_by_run[run] = phase
            prepare = run_config(run, phase, "prepare")
            log_path = args.output / (phase + "-prepare.log")
            with log_path.open("w") as log:
                process = subprocess.Popen(command(prepare, "ProcessInterruptionTests/testPrepareInterruption"), stdout=log, stderr=subprocess.STDOUT, env=env)
                container = None
                deadline = time.monotonic() + 90
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError(f"Prepare exited before boundary: {phase}; see {log_path}")
                    found = subprocess.run(["xcrun", "simctl", "get_app_container", simulator, BUNDLE, "data"],
                                           capture_output=True, text=True, env=env)
                    if found.returncode == 0:
                        container = owned_documents(found.stdout, simulator)
                        ready = container / f"spec003-interrupt-{run}.ready"
                        network_ready = args.output / (run + ".network-ready")
                        if ready.exists() and (phase != "before-file" or network_ready.exists()):
                            break
                    time.sleep(0.2)
                else:
                    process.terminate()
                    process.wait(timeout=20)
                    raise RuntimeError("Boundary not observed: " + phase)
                assert container is not None
                manifest = json.loads((container / f"spec003-interrupt-{run}.json").read_text())
                if (container / f"spec003-interrupt-{run}.ack").exists():
                    raise RuntimeError("Acknowledgement arrived before intended interruption")
                (args.output / (phase + "-manifest.json")).write_text(json.dumps(manifest, indent=2))
                subprocess.run(["xcrun", "simctl", "terminate", simulator, BUNDLE], check=True, env=env)
                gate.set()
                prepared_exit = process.wait(timeout=90)
                if prepared_exit == 0:
                    raise RuntimeError("Prepared test completed normally instead of being interrupted")
                final_manifest = json.loads((container / f"spec003-interrupt-{run}.json").read_text())
                if final_manifest["processID"] != manifest["processID"]:
                    raise RuntimeError("Interrupted test unexpectedly prepared again in another process")
            verify = run_config(run, phase, "verify")
            verify_log = args.output / (phase + "-verify.log")
            with verify_log.open("w") as log:
                verified = subprocess.run(command(verify, "ProcessInterruptionTests/testVerifyInterruption"), stdout=log, stderr=subprocess.STDOUT, env=env, timeout=300)
            if verified.returncode:
                raise RuntimeError("Restart verification failed: " + str(verify_log))
            require_one_pass(verify)
            current = subprocess.check_output(["xcrun", "simctl", "get_app_container", simulator, BUNDLE, "data"], text=True, env=env)
            container = owned_documents(current, simulator)
            result = json.loads((container / f"spec003-interrupt-{run}.verified.json").read_text())
            result["interruptedPrepareExit"] = prepared_exit
            results.append(result)
            (args.output / "results.json").write_text(json.dumps(results, indent=2))
            print(json.dumps(result), flush=True)
    finally:
        try:
            if process is not None and process.poll() is None:
                process.terminate()
                process.wait(timeout=20)
        finally:
            try:
                gate.set()
                server.shutdown()
                server.server_close()
            finally:
                if simulator:
                    delete_owned_simulator(simulator, env=env)


if __name__ == "__main__":
    main()
