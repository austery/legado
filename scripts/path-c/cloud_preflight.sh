#!/usr/bin/env bash
# Read-only checks on the standard hosted VM. No device downloads or creation.
set -euo pipefail
mkdir -p ci-results
exec > >(tee ci-results/cloud-preflight.log) 2>&1
[[ "$C1_RUNNER_ENVIRONMENT" == github-hosted ]]
[[ "$(uname -m)" == arm64 ]]
printf 'run=%s/%s/actions/runs/%s\nattempt=%s\nimage=%s %s\n' \
  "$GITHUB_SERVER_URL" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" \
  "${ImageOS:-unknown}" "${ImageVersion:-unknown}"
date -u '+%Y-%m-%dT%H:%M:%SZ'
git rev-parse HEAD HEAD^{tree} | tee ci-results/checkout-and-tree.txt
test "$(git rev-parse HEAD)" = "${C1_EXPECTED_SHA:-$GITHUB_SHA}"
sw_vers
sysctl hw.ncpu hw.memsize
vm_stat
df -h .
xcodebuild -version | tee ci-results/xcode-version.txt
grep -qx 'Xcode 27.0' ci-results/xcode-version.txt
grep -qx 'Build version 27A266a' ci-results/xcode-version.txt
test "$(xcrun --sdk iphonesimulator --show-sdk-version)" = 27.0
xcrun simctl list runtimes --json > ci-results/runtimes.json
xcrun simctl list devicetypes --json > ci-results/devicetypes.json
python3 - <<'PY'
import json
from pathlib import Path
runtimes = json.loads(Path('ci-results/runtimes.json').read_text())['runtimes']
assert any(r.get('isAvailable') and '.iOS-' in r['identifier'] and r['version'] == '27.0'
           for r in runtimes), 'Available iOS 27.0 runtime is required'
types = json.loads(Path('ci-results/devicetypes.json').read_text())['devicetypes']
assert any(t['identifier'] == 'com.apple.CoreSimulator.SimDeviceType.iPhone-16' for t in types)
assert any(t['identifier'].startswith('com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4')
           for t in types), 'iPad Pro 11-inch M4 device type is required'
print('Required runtime and device types are available')
PY
