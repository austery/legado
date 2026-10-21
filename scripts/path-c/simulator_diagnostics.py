"""Capture bounded startup diagnostics for an invocation-owned simulator UUID."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
from uuid import UUID


def capture_startup_failure(simulator: str, output: Path) -> None:
    UUID(simulator)
    commands = [
        ["/usr/sbin/sysctl", "hw.memsize", "vm.swapusage"],
        ["/usr/bin/vm_stat"],
        ["/usr/bin/memory_pressure", "-Q"],
        ["xcrun", "simctl", "list", "devices", "--json"],
        ["/usr/bin/log", "show", "--last", "5m", "--style", "compact", "--predicate",
         'process == "CoreSimulatorService" OR process == "launchd_sim" OR process == "simulatord"'],
    ]
    records: list[dict[str, object]] = []
    for command in commands:
        try:
            result = subprocess.run(command, capture_output=True, text=True, errors="replace", timeout=15, check=False)
            records.append({"command": command, "returncode": result.returncode,
                            "stdout": result.stdout[-131072:], "stderr": result.stderr[-8192:]})
        except (OSError, subprocess.SubprocessError) as error:
            records.append({"command": command, "error": str(error)})
    try:
        output.write_text(json.dumps({"ownedSimulator": simulator, "diagnostics": records}, indent=2))
    except OSError as error:
        print(f"Could not preserve startup diagnostics for {simulator}: {error}", file=sys.stderr)
