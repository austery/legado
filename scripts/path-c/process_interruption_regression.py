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

SIMULATOR = "C6BC346D-0C34-4CB9-B93C-706F38DAB7F6"
BUNDLE = "io.legado.pathc.nativereader"
PlistValue = Union[str, int, float, bool, bytes, datetime.datetime, List["PlistValue"], Dict[str, "PlistValue"]]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xctestrun", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--case", choices=("before-file", "after-file", "before-db", "after-db"), action="append")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
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
    template = plistlib.loads(args.xctestrun.read_bytes())

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
                "-destination", "platform=iOS Simulator,id=" + SIMULATOR,
                "-only-testing:NativeReaderTests/ProcessInterruptionTests/" + method,
                "-parallel-testing-enabled", "NO"]

    results = []
    process: subprocess.Popen[bytes] | None = None
    try:
        for phase in args.case or ["before-file", "after-file", "before-db", "after-db"]:
            gate.clear()
            run = str(uuid.uuid4()).upper()
            phase_by_run[run] = phase
            prepare = run_config(run, phase, "prepare")
            log_path = args.output / (phase + "-prepare.log")
            with log_path.open("w") as log:
                process = subprocess.Popen(command(prepare, "testPrepareInterruption"), stdout=log, stderr=subprocess.STDOUT, env=env)
                container = None
                deadline = time.monotonic() + 90
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError(f"Prepare exited before boundary: {phase}; see {log_path}")
                    found = subprocess.run(["xcrun", "simctl", "get_app_container", SIMULATOR, BUNDLE, "data"],
                                           capture_output=True, text=True, env=env)
                    if found.returncode == 0:
                        container = Path(found.stdout.strip()) / "Documents"
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
                subprocess.run(["xcrun", "simctl", "terminate", SIMULATOR, BUNDLE], check=True, env=env)
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
                verified = subprocess.run(command(verify, "testVerifyInterruption"), stdout=log, stderr=subprocess.STDOUT, env=env)
            if verified.returncode:
                raise RuntimeError("Restart verification failed: " + str(verify_log))
            containers = Path.home() / "Library/Developer/CoreSimulator/Devices" / SIMULATOR / "data/Containers/Data/Application"
            artifacts = list(containers.glob(f"*/Documents/spec003-interrupt-{run}.verified.json"))
            if len(artifacts) != 1:
                raise RuntimeError("Expected one exact-run verification artifact in the dedicated simulator")
            result = json.loads(artifacts[0].read_text())
            result["interruptedPrepareExit"] = prepared_exit
            results.append(result)
            (args.output / "results.json").write_text(json.dumps(results, indent=2))
            print(json.dumps(result), flush=True)
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            process.wait(timeout=20)
        gate.set()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
