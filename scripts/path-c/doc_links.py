"""Check that relative Markdown links in this project's own documents resolve.

Rules (global-skills agents/DOC-LIFECYCLE.md, "Link check"):
- every relative Markdown link resolves to an existing file, and a heading
  fragment to an existing heading;
- absolute paths and file: links fail; write a machine-specific path in a code
  span instead;
- archived files are not checked; the archive indexes are.

Upstream-owned Markdown is not checked. Fixing it would edit upstream files,
which adds merge conflicts to every upstream integration, and the help pages
under ui/.../composeResources/ are app content whose links resolve inside the
app, not in this repository.
"""
from __future__ import annotations

from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from typing import Optional
from urllib.parse import urlsplit

from c1_scope import check_link, links

ROOT = Path(__file__).resolve().parents[2]
ARCHIVE = 'docs/_archive/'
# Markdown that upstream (huajideshutiao/legado) owns; see docs/agents/impact-radius.md.
UPSTREAM_FILES = frozenset({'README.md', 'English.md', 'api.md'})
UPSTREAM_DIRS = (
    'app/', 'benchmark/', 'core/', 'data/', 'desktop/', 'desktop-core/', 'foundation/',
    'headless/', 'iosApp/', 'modules/', 'ohosApp/', 'ui/',
)
# An editor-style line suffix (ReaderEngine.kt:130) looks like a URI scheme to urlsplit.
FILE_LINE = re.compile(r'^([^:#?]*[^:/#?]\.[^:/#?]+):\d+(?:-\d+)?(#.*)?$')


def maintained(path: str) -> bool:
    """Return whether this project maintains the Markdown file at a repository path."""
    if not path.endswith('.md') or path in UPSTREAM_FILES or path.startswith(UPSTREAM_DIRS):
        return False
    if not path.startswith(ARCHIVE):
        return True
    # Archived payloads stay byte-for-byte; only the indexes are maintained.
    return len(PurePosixPath(path[len(ARCHIVE):]).parts) <= 2 and path.endswith('/README.md')


def problems(root: Path, path: str, content: str) -> list[str]:
    """Return one message per broken link in a maintained file."""
    try:
        targets = links(content)
    except ValueError as error:
        return [f'{path}: {error}']
    found: list[str] = []
    for target in sorted(targets):
        if target.startswith('/') or target.lower().startswith('file:'):
            found.append(f'{path}: machine-specific link (use a code span): {target}')
            continue
        line_link = None if '://' in target else FILE_LINE.match(target)
        if line_link:
            target = line_link.group(1) + (line_link.group(2) or '')
        parsed = urlsplit(target)
        if parsed.scheme or parsed.netloc:
            continue
        try:
            check_link(root, root / path, target)
        except ValueError as error:
            found.append(str(error))
    return found


def check(root: Path, paths: Optional[list[str]] = None) -> list[str]:
    """Check every maintained tracked Markdown file, or the given paths."""
    if paths is None:
        listed = subprocess.check_output(['git', 'ls-files', '-z', '--', '*.md'], cwd=root)
        paths = [path for path in listed.decode().split('\0') if path]
    files = [path for path in paths if maintained(path)]
    if not files:
        raise ValueError('No maintained Markdown files found')
    found: list[str] = []
    for path in files:
        found.extend(problems(root, path, (root / path).read_text()))
    return found


def main() -> int:
    found = check(ROOT)
    for message in found:
        print(message, file=sys.stderr)
    if found:
        print(f'{len(found)} broken Markdown link(s).', file=sys.stderr)
        return 1
    print('All relative Markdown links in maintained documents resolve.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
