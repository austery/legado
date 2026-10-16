import plistlib
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest

from process_interruption_regression import BUNDLE, owned_documents, validate_template


class InterruptionOwnershipTests(unittest.TestCase):
    def testRejectsOtherHostsBeforeDeviceCreation(self):
        with tempfile.TemporaryDirectory() as directory:
            host = Path(directory) / 'NativeReader.app'
            host.mkdir()
            (host / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'real.reader'}))
            template = {'TestConfigurations': [{'TestTargets': [{'BlueprintName': 'NativeReaderTests', 'TestHostPath': str(host)}]}]}
            with self.assertRaisesRegex(ValueError, 'bundle'):
                validate_template(template, Path(directory))
            (host / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': BUNDLE}))
            validate_template(template, Path(directory))
            with self.assertRaisesRegex(ValueError, 'TESTROOT'):
                validate_template(template, Path(directory) / 'foreign-root')
            template['TestConfigurations'][0]['TestTargets'][0]['BlueprintName'] = 'OtherTests'
            with self.assertRaisesRegex(ValueError, 'synthetic'):
                validate_template(template, Path(directory))

    def testRejectsOldSimulatorAndPhysicalDeviceContainers(self):
        root = Path.home() / 'Library/Developer/CoreSimulator/Devices'
        owned = '11111111-1111-1111-1111-111111111111'
        container = root / owned / 'data/Containers/Data/Application/test-app'
        self.assertEqual(owned_documents(str(container), owned), container / 'Documents')
        for value in [str(root / 'C6BC346D-0C34-4CB9-B93C-706F38DAB7F6/data/Containers/Data/Application/reader'),
                      '/private/var/mobile/Containers/Data/Application/reader', str(container / '../../other')]:
            with self.subTest(container=value), self.assertRaises(ValueError):
                owned_documents(value, owned)

    def testArbitraryDeviceArgumentIsRejectedBeforeAnyExecution(self):
        script = Path(__file__).with_name('process_interruption_regression.py')
        for device in ['C6BC346D-0C34-4CB9-B93C-706F38DAB7F6', 'physical-device']:
            result = subprocess.run([sys.executable, str(script), '--xctestrun', 'unused',
                                     '--output', 'unused', '--simulator', device], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn('unrecognized arguments', result.stderr)
