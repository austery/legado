"""Behavioral coverage for documentation routing and its cheap static checks."""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import threading
from pathlib import Path
import subprocess
import tempfile
import sys
import unittest

from c1_scope import ACTIONS_APP_ID, TESTED_CHECKS, changed_paths, check_documents, docs_only, document, plan

FULL = {name: 'success' for name in TESTED_CHECKS}


class ScopeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q')
        self.git('config', 'user.email', 'c1-fixture@example.invalid')
        self.git('config', 'user.name', 'C1 Fixture')
        self.write('README.md', '# Reader\n\nOriginal.\n')
        self.write('docs/architecture/guide.md', '# Guide\n')
        self.write('src/main.kt', 'val x = 1\n')
        self.write('scripts/path-c/c1_scope.py', Path(__file__).with_name('c1_scope.py').read_text())
        self.base = self.commit()

    def git(self, *args: str) -> str:
        return subprocess.check_output(['git', *args], cwd=self.root, text=True).strip()

    def write(self, path: str, text: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self) -> str:
        self.git('add', '-A')
        self.git('commit', '-qm', 'fixture')
        return self.git('rev-parse', 'HEAD')

    def event(self, head: str, event: str = 'pull_request') -> dict[str, object]:
        if event == 'push':
            return {'before': self.base, 'after': head}
        return {'pull_request': {'base': {'sha': self.base}, 'head': {'sha': head}}}

    def test_explanatory_docs_on_pr_and_push_skip_heavy_regression(self) -> None:
        self.write('README.md', '# Reader\n\n[Guide](docs/architecture/guide.md#guide)\n[Top](#reader)\n')
        head = self.commit()
        for name in ('pull_request', 'push'):
            mode, paths, _ = plan(self.root, self.event(head, name), name)
            self.assertEqual(mode, 'docs')
            self.assertEqual(paths, ['README.md'])

    def test_code_tests_configs_and_unknown_markdown_require_full_regression(self) -> None:
        for path in ('src/main.kt', 'scripts/path-c/test_example.py', 'fixtures/source.json',
                     '.github/workflows/c1-engine.yml', 'gradle.properties',
                     'test/data/source.md', 'docs/evidence/fixture.md'):
            self.assertFalse(document(path), path)
        self.write('README.md', '# Updated\n')
        self.write('src/main.kt', 'val x = 2\n')
        head = self.commit()
        self.assertEqual(plan(self.root, self.event(head), 'pull_request')[0], 'regression')

    def test_markdown_issue_template_skips_heavy_regression(self) -> None:
        self.write('.github/ISSUE_TEMPLATE/03-slice.md', '# Slice\n\n[Guide](../../README.md)\n')
        head = self.commit()
        mode, paths, _ = plan(self.root, self.event(head), 'pull_request')
        self.assertEqual(mode, 'docs')
        self.assertEqual(paths, ['.github/ISSUE_TEMPLATE/03-slice.md'])

    def test_issue_template_forms_config_and_nested_markdown_require_full_regression(self) -> None:
        for path in ('.github/ISSUE_TEMPLATE/01-bug.yml', '.github/ISSUE_TEMPLATE/config.yml',
                     '.github/ISSUE_TEMPLATE/nested/slice.md', '.github/workflows/notes.md',
                     '.github/pull_request_template.md'):
            self.assertFalse(document(path), path)

    def test_agent_guidance_markdown_skips_heavy_regression(self) -> None:
        self.write('docs/agents/impact-radius.md', '# Radius\n\n[Guide](../architecture/guide.md#guide)\n')
        head = self.commit()
        mode, paths, _ = plan(self.root, self.event(head), 'pull_request')
        self.assertEqual(mode, 'docs')
        self.assertEqual(paths, ['docs/agents/impact-radius.md'])

    def test_agent_guidance_non_markdown_requires_full_regression(self) -> None:
        for path in ('docs/agents/radius.json', 'docs/agents/check.py', 'docs/agentsx/notes.md'):
            self.assertFalse(document(path), path)

    def test_more_than_api_page_of_paths_is_fully_classified(self) -> None:
        for number in range(105):
            self.write(f'docs/architecture/{number}.md', '# Note\n')
        self.write('src/main.kt', 'val x = 2\n')
        head = self.commit()
        paths = changed_paths(self.root, self.base, head, True)
        self.assertEqual(len(paths), 106)
        self.assertFalse(docs_only(self.root, paths, self.base, head))

    def test_rename_from_code_to_document_is_not_exempt(self) -> None:
        self.git('mv', 'src/main.kt', 'docs/architecture/renamed.md')
        head = self.commit()
        paths = changed_paths(self.root, self.base, head, True)
        self.assertEqual(set(paths), {'src/main.kt', 'docs/architecture/renamed.md'})
        self.assertEqual(plan(self.root, self.event(head), 'pull_request')[0], 'regression')

    def test_doc_delete_is_exempt_but_broken_inbound_reference_fails(self) -> None:
        (self.root / 'docs/architecture/guide.md').unlink()
        head = self.commit()
        self.assertEqual(plan(self.root, self.event(head), 'pull_request')[0], 'docs')
        self.git('reset', '--hard', self.base)
        self.write('README.md', '# Reader\n\n[Guide](docs/architecture/guide.md#guide)\n')
        self.base = self.commit()
        (self.root / 'docs/architecture/guide.md').unlink()
        head = self.commit()
        with self.assertRaisesRegex(ValueError, 'missing link'):
            plan(self.root, self.event(head), 'pull_request')

    def test_changed_heading_breaking_inbound_link_fails(self) -> None:
        self.write('README.md', '# Reader\n\n[Guide](docs/architecture/guide.md#guide)\n')
        self.base = self.commit()
        self.write('docs/architecture/guide.md', '# Renamed\n')
        head = self.commit()
        with self.assertRaisesRegex(ValueError, 'missing heading'):
            plan(self.root, self.event(head), 'pull_request')

    def test_removed_heading_breaks_unchanged_same_document_link(self) -> None:
        self.write('README.md', '# Reader\n\n[Jump](#old)\n\n## Old\n')
        self.base = self.commit()
        self.write('README.md', '# Reader\n\n[Jump](#old)\n\n## New\n')
        head = self.commit()
        with self.assertRaisesRegex(ValueError, 'missing heading'):
            plan(self.root, self.event(head), 'pull_request')

    def test_new_missing_link_or_heading_and_unclosed_fence_fail(self) -> None:
        for text, message in (('# Reader\n[bad](missing.md)\n', 'missing link'),
                              ('# Reader\n[bad](docs/architecture/guide.md#absent)\n', 'missing heading'),
                              ('# Reader\n```text\nunfinished\n', 'Unclosed')):
            self.git('reset', '--hard', self.base)
            self.write('README.md', text)
            head = self.commit()
            with self.assertRaisesRegex(ValueError, message):
                plan(self.root, self.event(head), 'pull_request')

    def test_unrelated_legacy_broken_link_does_not_block_changed_docs(self) -> None:
        self.write('README.md', '# Reader\n[old](missing.md)\n')
        self.base = self.commit()
        self.write('docs/architecture/guide.md', '# Guide\n\nUpdated.\n')
        head = self.commit()
        self.assertEqual(plan(self.root, self.event(head), 'pull_request')[0], 'docs')

    def test_symlink_document_is_not_exempt(self) -> None:
        (self.root / 'README.md').unlink()
        (self.root / 'README.md').symlink_to('src/main.kt')
        head = self.commit()
        self.assertEqual(plan(self.root, self.event(head), 'pull_request')[0], 'regression')

    def test_empty_unknown_unavailable_range_and_manual_dispatch_are_full(self) -> None:
        cases = [(self.event(self.base), 'pull_request'),
                 ({'before': '0' * 40, 'after': self.base}, 'push'),
                 ({'before': 'f' * 40, 'after': self.base}, 'push'),
                 ({}, 'pull_request'), ({}, 'unknown'), ({}, 'workflow_dispatch')]
        for payload, name in cases:
            self.assertEqual(plan(self.root, payload, name)[0], 'regression')

    def test_head_mismatch_cannot_exempt(self) -> None:
        self.write('README.md', '# New\n')
        self.commit()
        self.assertEqual(plan(self.root, self.event(self.base), 'pull_request')[0], 'regression')

    def test_shell_syntax_in_filename_is_not_executed(self) -> None:
        path = 'docs/architecture/$(touch marker).md'
        self.write(path, '# Note\n')
        head = self.commit()
        self.assertEqual(plan(self.root, self.event(head), 'pull_request')[0], 'docs')
        self.assertFalse((self.root / 'marker').exists())

    def test_whitespace_error_is_not_swallowed_as_classification_fallback(self) -> None:
        self.write('README.md', '# Reader  \n')
        head = self.commit()
        with self.assertRaises(subprocess.CalledProcessError):
            plan(self.root, self.event(head), 'pull_request')

    def test_cli_failed_docs_still_skip_heavy_jobs_but_fail_the_scope_job(self) -> None:
        for text, passed in (('# Updated\n', True), ('# Reader\n[bad](absent.md)\n', False)):
            self.git('reset', '--hard', self.base)
            self.write('README.md', text)
            head = self.commit()
            event = self.root / '.git/event.json'
            output = self.root / '.git/output.txt'
            output.write_text('')
            event.write_text(json.dumps(self.event(head)))
            result = subprocess.run([sys.executable, str(self.root / 'scripts/path-c/c1_scope.py'), 'plan'],
                env={**os.environ, 'GITHUB_EVENT_NAME': 'pull_request', 'GITHUB_EVENT_PATH': str(event),
                     'GITHUB_OUTPUT': str(output)}, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode == 0, passed, result.stderr)
            self.assertIn('run_regression=false', output.read_text())
            # Invalid docs fail the scope job; they never schedule heavy runtime work.

    def merge(self, branch_change: str = 'val x = 2\n', main_change: str = '') -> str:
        """Merge a code-changing branch into the base line with --no-ff; return the merge SHA."""
        main = self.git('rev-parse', '--abbrev-ref', 'HEAD')
        self.git('checkout', '-qb', 'feature')
        self.write('src/main.kt', branch_change)
        self.commit()
        self.git('checkout', '-q', main)
        if main_change:
            self.write('src/other.kt', main_change)
            self.commit()
        self.git('merge', '-q', '--no-ff', '--no-edit', 'feature')
        return self.git('rev-parse', 'HEAD')

    def test_push_of_merge_with_fully_tested_identical_tree_skips_regression(self) -> None:
        head = self.merge()
        tested = self.git('rev-parse', 'HEAD^2')
        seen: list[str] = []
        mode, _, reason = plan(self.root, self.event(head, 'push'), 'push',
                               lookup=lambda sha: seen.append(sha) or FULL)
        self.assertEqual(mode, 'merged')
        self.assertEqual(seen, [tested])
        self.assertIn(tested, reason)
        self.assertIn(self.git('rev-parse', 'HEAD^{tree}'), reason)

    def test_merge_skip_requires_full_regression_success_on_the_pr_head(self) -> None:
        head = self.merge()
        for conclusions in ({}, {'C1 engine regression': 'success'},
                            {'C1 engine regression': 'success', 'C1 builds and regular regressions': 'skipped'},
                            {**FULL, 'C1 engine regression': 'failure'},
                            {**FULL, 'C1 builds and regular regressions': 'cancelled'}):
            with self.subTest(conclusions=conclusions):
                self.assertEqual(plan(self.root, self.event(head, 'push'), 'push',
                                      lookup=lambda _sha, c=conclusions: c)[0], 'regression')

    def test_merge_skip_fails_closed_when_the_lookup_fails(self) -> None:
        head = self.merge()
        def broken(_sha: str) -> dict[str, str]:
            raise OSError('network down')
        mode, _, reason = plan(self.root, self.event(head, 'push'), 'push', lookup=broken)
        self.assertEqual(mode, 'regression')
        self.assertIn('OSError', reason)

    def test_untested_merge_trees_pull_requests_and_plain_pushes_run_regression(self) -> None:
        moved = self.merge(main_change='val y = 1\n')  # Base moved: merge tree differs from the PR head.
        self.assertEqual(plan(self.root, self.event(moved, 'push'), 'push', lookup=lambda _: FULL)[0],
                         'regression')
        self.git('reset', '-q', '--hard', self.base)
        self.git('branch', '-qD', 'feature')
        head = self.merge()
        pull = {'pull_request': {'base': {'sha': self.base}, 'head': {'sha': head}}}
        self.assertEqual(plan(self.root, pull, 'pull_request', lookup=lambda _: FULL)[0], 'regression')
        self.git('reset', '-q', '--hard', self.base)
        self.write('src/main.kt', 'val x = 3\n')
        plain = self.commit()
        self.assertEqual(plan(self.root, self.event(plain, 'push'), 'push', lookup=lambda _: FULL)[0],
                         'regression')

    def test_docs_only_merge_stays_docs_without_a_lookup(self) -> None:
        main = self.git('rev-parse', '--abbrev-ref', 'HEAD')
        self.git('checkout', '-qb', 'feature')
        self.write('README.md', '# Reader\n\nChanged.\n')
        self.commit()
        self.git('checkout', '-q', main)
        self.git('merge', '-q', '--no-ff', '--no-edit', 'feature')
        head = self.git('rev-parse', 'HEAD')
        def unexpected(_sha: str) -> dict[str, str]:
            raise AssertionError('docs-only pushes must not query checks')
        self.assertEqual(plan(self.root, self.event(head, 'push'), 'push', lookup=unexpected)[0], 'docs')

    def test_cli_merged_push_reads_github_checks_and_skips_heavy_jobs(self) -> None:
        head = self.merge()
        tested = self.git('rev-parse', 'HEAD^2')
        for app_id, expected in ((ACTIONS_APP_ID, 'false'), (1, 'true')):
            requests: list[str] = []

            class Checks(BaseHTTPRequestHandler):
                def do_GET(self) -> None:  # noqa: N802
                    requests.append(self.path + ' ' + self.headers.get('Authorization', ''))
                    body = json.dumps({'check_runs': [
                        {'id': index, 'name': name, 'conclusion': 'success', 'app': {'id': app_id}}
                        for index, name in enumerate(TESTED_CHECKS)]}).encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(body)

                def log_message(self, *_args: object) -> None:
                    pass

            server = HTTPServer(('127.0.0.1', 0), Checks)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            event = self.root / '.git/event.json'
            output = self.root / '.git/output.txt'
            output.write_text('')
            event.write_text(json.dumps(self.event(head, 'push')))
            result = subprocess.run([sys.executable, str(self.root / 'scripts/path-c/c1_scope.py'), 'plan'],
                env={**os.environ, 'GITHUB_EVENT_NAME': 'push', 'GITHUB_EVENT_PATH': str(event),
                     'GITHUB_OUTPUT': str(output), 'GITHUB_REPOSITORY': 'owner/repo', 'GITHUB_TOKEN': 'fixture',
                     'GITHUB_API_URL': f'http://127.0.0.1:{server.server_port}'},
                capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f'run_regression={expected}', output.read_text())
            self.assertEqual(requests, [f'/repos/owner/repo/commits/{tested}/check-runs?filter=latest&per_page=100 '
                                        'Bearer fixture'])


if __name__ == '__main__':
    unittest.main()
