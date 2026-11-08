"""Behavioral coverage for the repository-wide Markdown link check."""
from pathlib import Path
import tempfile
import unittest

from doc_links import check, maintained


class MaintainedTest(unittest.TestCase):
    def test_project_documents_are_maintained(self) -> None:
        for path in ('AGENTS.md', 'docs/agents/impact-radius.md',
                     'docs/architecture/decisions/ADR-005-x.md', 'native-ios-app/README.md',
                     'scripts/path-c/README.md', '.github/ISSUE_TEMPLATE/03-bounded-slice.md'):
            self.assertTrue(maintained(path), path)

    def test_upstream_markdown_and_app_content_are_skipped(self) -> None:
        for path in ('README.md', 'English.md', 'api.md', 'app/README.md',
                     'ui/src/commonMain/composeResources/files/web/help/md/ruleHelp.md',
                     'modules/web/README.md', 'data/src/commonMain/kotlin/org/jsoup/README.md'):
            self.assertFalse(maintained(path), path)

    def test_archive_payloads_are_skipped_but_indexes_are_checked(self) -> None:
        self.assertTrue(maintained('docs/_archive/README.md'))
        self.assertTrue(maintained('docs/_archive/2026-specs/README.md'))
        self.assertFalse(maintained('docs/_archive/2026-specs/SPEC-004.md'))
        self.assertFalse(maintained('docs/_archive/a/b/README.md'))

    def test_non_markdown_is_skipped(self) -> None:
        self.assertFalse(maintained('docs/notes.txt'))


class CheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.write('docs/target.md', '# Target\n\n## Section two\n')
        self.write('src/Main.kt', 'val x = 1\n')

    def write(self, path: str, text: str) -> None:
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)

    def run_check(self, text: str, path: str = 'docs/page.md') -> list[str]:
        self.write(path, text)
        return check(self.root, [path])

    def test_resolving_links_pass(self) -> None:
        self.assertEqual(self.run_check(
            '[t](target.md) [s](target.md#section-two) [code](../src/Main.kt) '
            '[line](../src/Main.kt:1) [web](https://example.com) [self](#top)\n# Top\n'), [])

    def test_missing_file_fails(self) -> None:
        found = self.run_check('[gone](missing.md)\n')
        self.assertEqual(len(found), 1)
        self.assertIn('missing link', found[0])

    def test_missing_heading_fails(self) -> None:
        self.assertIn('missing heading', self.run_check('[t](target.md#nowhere)\n')[0])

    def test_absolute_and_file_links_fail(self) -> None:
        found = self.run_check('[a](/Users/someone/note.md) [b](file:///tmp/x.md) [c](/app/X.kt)\n')
        self.assertEqual(len(found), 3)
        self.assertTrue(all('machine-specific' in message for message in found))

    def test_link_leaving_repository_fails(self) -> None:
        self.assertIn('leaves repository', self.run_check('[out](../../outside.md)\n')[0])

    def test_fenced_examples_are_not_checked(self) -> None:
        self.assertEqual(self.run_check('```\n[x](/abs/path.md)\n```\n'), [])

    def test_unclosed_fence_fails(self) -> None:
        self.assertIn('Unclosed', self.run_check('```\n[x](target.md)\n')[0])

    def test_archived_payload_is_skipped_and_index_is_checked(self) -> None:
        self.write('docs/_archive/old/SPEC.md', '[gone](missing.md)\n')
        self.write('docs/_archive/README.md', '[old](old/SPEC.md) [gone](old/missing.md)\n')
        found = check(self.root, ['docs/_archive/old/SPEC.md', 'docs/_archive/README.md'])
        self.assertEqual(len(found), 1)
        self.assertIn('old/missing.md', found[0])

    def test_no_maintained_files_is_an_error(self) -> None:
        with self.assertRaises(ValueError):
            check(self.root, ['README.md'])


if __name__ == '__main__':
    unittest.main()
