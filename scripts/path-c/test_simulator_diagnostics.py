import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from simulator_diagnostics import capture_startup_failure


class StartupDiagnosticsTests(unittest.TestCase):
    def test_rejects_broad_selector_before_running_commands(self) -> None:
        with patch('simulator_diagnostics.subprocess.run') as run:
            with self.assertRaises(ValueError):
                capture_startup_failure('all', Path('/unused'))
            run.assert_not_called()

    def test_diagnostic_failure_is_recorded_and_later_commands_continue(self) -> None:
        calls = 0

        def run(command: list[str], **options: object) -> subprocess.CompletedProcess[str]:
            nonlocal calls
            calls += 1
            self.assertEqual(options['timeout'], 15)
            if calls == 1:
                raise subprocess.TimeoutExpired(command, 15)
            return subprocess.CompletedProcess(command, 0, 'observed', '')

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'diagnostics.json'
            with patch('simulator_diagnostics.subprocess.run', side_effect=run):
                capture_startup_failure('11111111-2222-3333-4444-555555555555', path)
            data = json.loads(path.read_text())
            self.assertEqual(calls, 5)
            self.assertIn('error', data['diagnostics'][0])
            self.assertEqual(data['diagnostics'][-1]['stdout'], 'observed')
