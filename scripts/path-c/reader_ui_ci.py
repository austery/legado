"""Exercise actual native reader controls in a synthetic-only, independent app."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess

from ci_harness import delete_owned_simulator, simctl
from native_product_ci import fixtures, run, validate_summary

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    runtimes = json.loads(simctl('list', 'runtimes', '--json'))['runtimes']
    available = [r for r in runtimes if r['isAvailable'] and '.iOS-' in r['identifier']]
    if not available:
        raise RuntimeError('No available iOS simulator runtime')
    runtime = max(available, key=lambda r: tuple(map(int, r['version'].split('.'))))
    tablets = [t['identifier'] for t in json.loads(simctl('list', 'devicetypes', '--json'))['devicetypes']
               if t['identifier'].startswith('com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4')]
    if not tablets:
        raise RuntimeError('No iPad Pro 11-inch M4 simulator type')
    (output / 'commit.txt').write_text(subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True))
    (output / 'scope.json').write_text(json.dumps({
        'app': 'io.legado.pathc.ui-fixture', 'expectedTests': 7,
        'fixture': 'owned loopback only', 'physicalDevice': False,
        'suites': ['ReaderUITests/testSourceSwitchProcessLossBeforeCommitAndAfterCommitBeforeAcknowledgment',
                   'ReaderUITests/testExplicitSourceSwitchAndRelaunch',
                   'ReaderUITests/testShelfReadingRecoveryAndResume',
                   'ReaderUITests/testSearchDetailsCatalogAndGlobalPreferences',
                   'ReaderUITests/testCatalogFilterResetsForAnotherSourceAndPreferencesApply',
                   'ReaderUITests/testUnshelvedDirectoryReturnKeepsSession',
                   'ReaderUITests/testReadOnlyDirectoryReturnKeepsSessionAndStoredRecord']}, indent=2))
    with fixtures():
        simulator = simctl('create', 'Native Reader UI', tablets[0], runtime['identifier'])
        try:
            (output / 'simulator.txt').write_text(simulator + '\n' + runtime['identifier'])
            run(['xcodegen', 'generate', '--spec', 'native-ios-app/ui-tests.yml'], output / 'project.log', 60)
            simctl('boot', simulator)
            run(['xcrun', 'simctl', 'bootstatus', simulator, '-b'], output / 'boot.log', 180)
            command = ['xcodebuild', 'test', '-project', 'native-ios-app/NativeReader.xcodeproj',
                       '-scheme', 'NativeReaderUI', '-destination', f'platform=iOS Simulator,id={simulator}',
                       '-derivedDataPath', str(output / 'DerivedData'), '-parallel-testing-enabled', 'NO',
                       '-resultBundlePath', str(output / 'UI.xcresult'), 'CODE_SIGNING_ALLOWED=NO']
            (output / 'command.json').write_text(json.dumps(command, indent=2))
            run(command, output / 'tests.log', 900)
            summary = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                                               '--path', str(output / 'UI.xcresult')], text=True)
            (output / 'summary.json').write_text(summary)
            validate_summary(json.loads(summary), 7)
            run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(output / 'UI.xcresult'),
                 '--output-path', str(output / 'screenshots')], output / 'screenshots.log', 60)
        finally:
            delete_owned_simulator(simulator)


if __name__ == '__main__':
    main()
