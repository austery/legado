"""Exercise the actual required-check shell against all GitHub job outcomes."""
import itertools
import os
from pathlib import Path
import subprocess
import sys

from c1_scope import accepted
import unittest


class C1GateTest(unittest.TestCase):
    def test_process_coverage_is_local_and_both_jobs_pin_the_same_revision(self) -> None:
        workflow = (Path(__file__).resolve().parents[2] / '.github/workflows/c1-engine.yml').read_text()
        engine, process = workflow.split('  engine:\n', 1)[1].split('\n  native-process:\n', 1)
        for job in (engine, process):
            self.assertIn('ref: ${{ github.event.pull_request.head.sha || github.sha }}', job)
            self.assertIn('needs: scope', job)
            self.assertIn("needs.scope.outputs.run_regression != 'false'", job)
            self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", job)
            self.assertNotIn('continue-on-error:', job)
        self.assertIn('runs-on: [self-hosted, macOS, ARM64, legado-macos-local]', process)
        self.assertIn('--process-tests-only --runtime-version 27.0', process)
        self.assertNotIn('--process-tests-only', engine)
        self.assertNotIn('--include-process-tests', engine)
        for required in ('verify_url_tests.py', 'kotlin_native_ci.py', ':data:jvmTest :core:jvmTest :ui:jvmTest',
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

    def test_gate_fails_closed_for_every_job_result(self) -> None:
        outcomes = ('success', 'failure', 'cancelled', 'skipped', '')
        for mode, scope, engine, process, trusted in itertools.product(
                ('docs', 'regression', ''), outcomes, outcomes, outcomes, ('true', 'false')):
            expected = (scope == 'success' and trusted == 'true' and
                        ((mode == 'docs' and engine == process == 'skipped') or
                         (mode == 'regression' and engine == process == 'success')))
            self.assertEqual(accepted(mode, scope, engine, process, trusted), expected)

    def test_workflow_gate_executes_the_tested_policy(self) -> None:
        root = Path(__file__).resolve().parents[2]
        workflow = (root / '.github/workflows/c1-engine.yml').read_text()
        gate = workflow.split('  regression:\n', 1)[1].split('  # Automatic', 1)[0]
        self.assertIn('needs: [scope, engine, native-process]', gate)
        self.assertIn('if: ${{ always() }}', gate)
        self.assertIn('run: python3 scripts/path-c/c1_scope.py gate', gate)
        self.assertNotIn('paths-ignore:', workflow)
        self.assertNotIn('pull_request_target:', workflow)
        for mode, engine, process, passed in (('docs', 'skipped', 'skipped', True),
                                             ('docs', 'success', 'skipped', False),
                                             ('regression', 'success', 'success', True),
                                             ('regression', 'success', 'skipped', False)):
            result = subprocess.run([sys.executable, str(root / 'scripts/path-c/c1_scope.py'), 'gate'],
                env={**os.environ, 'MODE': mode, 'SCOPE_RESULT': 'success', 'ENGINE_RESULT': engine,
                     'PROCESS_RESULT': process, 'TRUSTED': 'true'}, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode == 0, passed)


if __name__ == '__main__':
    unittest.main()
