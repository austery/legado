"""Exercise the actual required-check shell against all GitHub job outcomes."""
import itertools
import os
from pathlib import Path
import subprocess
import textwrap
import unittest


class C1GateTest(unittest.TestCase):
    def test_process_coverage_is_local_and_both_jobs_pin_the_same_revision(self) -> None:
        workflow = (Path(__file__).resolve().parents[2] / '.github/workflows/c1-engine.yml').read_text()
        engine, process = workflow.split('  engine:\n', 1)[1].split('\n  native-process:\n', 1)
        for job in (engine, process):
            self.assertIn('ref: ${{ github.event.pull_request.head.sha || github.sha }}', job)
            self.assertIn("if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository", job)
            self.assertNotIn('continue-on-error:', job)
        self.assertIn('runs-on: [self-hosted, macOS, ARM64, legado-macos-local]', process)
        self.assertIn('--process-tests-only --runtime-version 27.0', process)
        self.assertNotIn('--process-tests-only', engine)
        self.assertNotIn('--include-process-tests', engine)
        for required in ('kotlin_native_ci.py', ':data:jvmTest :core:jvmTest :ui:jvmTest',
                         'ci_harness.py --output ci-results', 'native_product_ci.py --output'):
            self.assertIn(required, engine)

    def test_preflight_checks_selected_head_and_rejects_mismatches(self) -> None:
        root = Path(__file__).resolve().parents[2]
        script = (root / 'scripts/path-c/cloud_preflight.sh').read_text()
        check = next(line for line in script.splitlines() if line.startswith('test "$(git rev-parse HEAD)"'))
        head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
        for selected, event, passed in ((head, 'merge-sha', True), ('wrong', head, False),
                                        ('', head, True), ('', 'wrong', False)):
            with self.subTest(selected=selected, event=event):
                result = subprocess.run(['bash', '-eu', '-c', check], cwd=root,
                    env={**os.environ, 'C1_EXPECTED_SHA': selected, 'GITHUB_SHA': event},
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, passed)

    def test_only_two_successful_jobs_can_pass(self) -> None:
        workflow = (Path(__file__).resolve().parents[2] / '.github/workflows/c1-engine.yml').read_text()
        gate = workflow.split('  regression:\n', 1)[1].split('\n  engine:', 1)[0]
        self.assertIn('needs: [engine, native-process]', gate)
        self.assertIn('if: ${{ always() }}', gate)
        self.assertIn('ENGINE_RESULT: ${{ needs.engine.result }}', gate)
        self.assertIn('PROCESS_RESULT: ${{ needs.native-process.result }}', gate)
        script = textwrap.dedent(gate.split('        run: |\n', 1)[1])
        outcomes = ('success', 'failure', 'cancelled', 'skipped', '')
        for engine, process in itertools.product(outcomes, repeat=2):
            with self.subTest(engine=engine, process=process):
                result = subprocess.run(['bash', '-e', '-u', '-o', 'pipefail', '-c', script],
                    env={**os.environ, 'ENGINE_RESULT': engine, 'PROCESS_RESULT': process},
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, engine == process == 'success')


if __name__ == '__main__':
    unittest.main()
