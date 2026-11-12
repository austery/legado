"""Exercise the actual required-check shell against all GitHub job outcomes."""
import itertools
import os
from pathlib import Path
import subprocess
import sys

from c1_scope import accepted
import unittest


class C1GateTest(unittest.TestCase):
    def test_process_coverage_runs_locally_in_one_job_and_both_jobs_pin_the_same_revision(self) -> None:
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
        # Local execution (the automatic default) runs the process suites inside the engine job;
        # only manual cloud execution starts the separate local process job.
        self.assertIn("inputs.execution == 'cloud'", process.split('runs-on:', 1)[0])
        self.assertNotIn('--process-tests-only', engine)
        self.assertIn("(inputs.execution || 'local') != 'local' && '--runtime-version 27.0' || "
                      "'--include-process-tests'", engine)
        self.assertIn('bash scripts/ci/ci-machine-lock.sh acquire', engine)
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
        for mode, scope, engine, process, trusted, execution in itertools.product(
                ('docs', 'merged', 'regression', ''), outcomes, outcomes, outcomes, ('true', 'false'),
                ('local', 'cloud', '')):
            expected = (scope == 'success' and trusted == 'true' and
                        ((mode in ('docs', 'merged') and engine == process == 'skipped') or
                         (mode == 'regression' and engine == 'success' and
                          ((execution == 'local' and process == 'skipped') or
                           (execution == 'cloud' and process == 'success')))))
            self.assertEqual(accepted(mode, scope, engine, process, trusted, execution), expected)

    def test_link_check_runs_after_the_scope_step(self) -> None:
        # A failure before the scope step leaves run_regression empty, which starts both heavy jobs.
        workflow = (Path(__file__).resolve().parents[2] / '.github/workflows/c1-engine.yml').read_text()
        scope = workflow.index('id: scope')
        self.assertLess(scope, workflow.index('id: link-python'))
        self.assertLess(scope, workflow.index('scripts/path-c/doc_links.py'))

    def test_workflow_gate_executes_the_tested_policy(self) -> None:
        root = Path(__file__).resolve().parents[2]
        workflow = (root / '.github/workflows/c1-engine.yml').read_text()
        gate = workflow.split('  regression:\n', 1)[1].split('  # Automatic', 1)[0]
        self.assertIn('needs: [scope, engine, native-process]', gate)
        self.assertIn('if: ${{ always() }}', gate)
        self.assertIn('run: python3 scripts/path-c/c1_scope.py gate', gate)
        self.assertNotIn('paths-ignore:', workflow)
        self.assertNotIn('pull_request_target:', workflow)
        self.assertIn("EXECUTION: ${{ inputs.execution || 'local' }}", gate)
        for mode, engine, process, execution, passed in (
                ('docs', 'skipped', 'skipped', 'local', True),
                ('docs', 'success', 'skipped', 'local', False),
                ('merged', 'skipped', 'skipped', 'local', True),
                ('merged', 'success', 'skipped', 'local', False),
                ('regression', 'success', 'skipped', 'local', True),
                ('regression', 'success', 'success', 'local', False),
                ('regression', 'success', 'success', 'cloud', True),
                ('regression', 'success', 'skipped', 'cloud', False),
                ('regression', 'success', 'skipped', '', False)):
            result = subprocess.run([sys.executable, str(root / 'scripts/path-c/c1_scope.py'), 'gate'],
                env={**os.environ, 'MODE': mode, 'SCOPE_RESULT': 'success', 'ENGINE_RESULT': engine,
                     'PROCESS_RESULT': process, 'TRUSTED': 'true', 'EXECUTION': execution},
                capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode == 0, passed, (mode, engine, process, execution))

    def test_superseded_pull_request_runs_cancel_and_the_scope_job_can_read_checks(self) -> None:
        workflow = (Path(__file__).resolve().parents[2] / '.github/workflows/c1-engine.yml').read_text()
        concurrency = workflow.split('concurrency:\n', 1)[1].split('\njobs:', 1)[0]
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", concurrency)
        self.assertIn('github.event.pull_request.number || github.ref', concurrency)
        scope = workflow.split('  scope:\n', 1)[1].split('\n  regression:\n', 1)[0]
        self.assertIn('checks: read', scope)
        self.assertIn('GITHUB_TOKEN: ${{ github.token }}', scope)
        for job in ('  engine:\n', '  native-process:\n'):
            release = workflow.split(job, 1)[1].split('Release the shared Mac heavy-CI lock', 1)[1]
            self.assertIn("if: always() && steps.machine-lock.outcome == 'success'", release.split('\n')[1])


if __name__ == '__main__':
    unittest.main()
