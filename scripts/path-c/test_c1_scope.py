"""Behavioral coverage for documentation routing and its cheap static checks."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys
import unittest

from c1_scope import changed_paths, check_documents, docs_only, document, plan


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


if __name__ == '__main__':
    unittest.main()
