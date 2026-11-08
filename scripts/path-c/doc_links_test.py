"""Behavioral coverage for the repository-wide Markdown link check.

Needs markdown-it-py, so the name avoids the test_*.py pattern that the engine
job discovers with the system Python. Run it with:
    uv run --no-project --with-requirements scripts/path-c/requirements-doc-links.txt \
        python -m unittest discover -s scripts/path-c -p 'doc_links_test.py'
"""
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
        self.write('docs/target.md', '# Target\n\n## Section two\n\nSetext title\n============\n')
        self.write('docs/file(name).md', '# File\n')
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
            '# Top\n\n[t](target.md) [s](target.md#section-two "Title") '
            '[setext](target.md#setext-title) [code](../src/Main.kt) [web](https://example.com) '
            '<https://example.com> [self](#top) [r][ref] [e](target&#46;md) '
            '[esc](file\\(name\\).md) [nest](file(name).md)\n\n[ref]: target.md\n'), [])

    def test_missing_file_reports_its_line(self) -> None:
        found = self.run_check('Intro.\n\n[gone](missing.md)\n')
        self.assertEqual(len(found), 1)
        self.assertIn('docs/page.md:3: missing link', found[0])

    def test_missing_heading_fails(self) -> None:
        self.assertIn('missing heading', self.run_check('[t](target.md#nowhere)\n')[0])

    def test_absolute_file_and_windows_links_fail(self) -> None:
        found = self.run_check(
            '[a](/Users/someone/note.md) [b](file:///tmp/x.md) [c](/app/X.kt) '
            '<file:///Users/someone/y.md> [w](C:/Users/someone/z.md)\n')
        self.assertEqual(len(found), 5, found)
        self.assertTrue(all('machine-specific' in message for message in found))

    def test_other_link_forms_are_checked(self) -> None:
        found = self.run_check(
            '[read\nmore](missing-a.md) [x](missing(a(b)).md) [angle](<missing b.md>) '
            '[titled](missing-c.md "Title")\n\n> [q][ref]\n>\n> [ref]: missing-d.md\n\n'
            '[unused]: missing-e.md\n')
        # The quoted reference is reported at its use (line 4) and its definition (line 6).
        self.assertEqual(len(found), 7, found)

    def test_line_suffix_in_a_link_fails(self) -> None:
        found = self.run_check('[line](../src/Main.kt:1) [bare](Main.kt:12-20)\n')
        self.assertEqual(len(found), 2)
        self.assertTrue(all('line suffix' in message for message in found))

    def test_code_is_not_checked(self) -> None:
        self.assertEqual(self.run_check(
            'Write `[x](/Users/someone/note.md)` as a code span.\n\n'
            '```\n[x](/abs/path.md)\n```\n\nText.\n\n    [y](/Users/example/file.md)\n\n'
            '> ~~~\n> [z](/abs/path.md)\n> ~~~\n'), [])

    def test_heading_anchor_uses_displayed_text(self) -> None:
        self.write('docs/styled.md', '# _Usage_\n\n## [Setup](https://example.com)\n\n'
                   '### `code` and **bold**\n')
        self.assertEqual(self.run_check(
            '[a](styled.md#usage) [b](styled.md#setup) [c](styled.md#code-and-bold)\n'), [])

    def test_html_ids_count_only_outside_code(self) -> None:
        self.write('docs/ids.md', '<a id="real"></a>\n\n```\n<a id="ghost"></a>\n```\n')
        found = self.run_check('[ok](ids.md#real) [bad](ids.md#ghost)\n')
        self.assertEqual(len(found), 1, found)
        self.assertIn('#ghost', found[0])

    def test_protocol_relative_url_is_external(self) -> None:
        self.assertEqual(self.run_check('[remote](//example.com/docs)\n'), [])

    def test_link_leaving_repository_fails(self) -> None:
        self.assertIn('leaves repository', self.run_check('[out](../../outside.md)\n')[0])

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
