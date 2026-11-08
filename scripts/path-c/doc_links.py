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

from c1_scope import check_link

ROOT = Path(__file__).resolve().parents[2]
ARCHIVE = 'docs/_archive/'
# Markdown that upstream (huajideshutiao/legado) owns; see docs/agents/impact-radius.md.
UPSTREAM_FILES = frozenset({'README.md', 'English.md', 'api.md'})
UPSTREAM_DIRS = (
    'app/', 'benchmark/', 'core/', 'data/', 'desktop/', 'desktop-core/', 'foundation/',
    'headless/', 'iosApp/', 'modules/', 'ohosApp/', 'ui/',
)
FENCE = re.compile(r'^\s{0,3}(`{3,}|~{3,})')
CODE_SPAN = re.compile(r'(`+)(?:(?!\1).)+?\1', re.DOTALL)
# Inline link or image: [text](destination "optional title").
INLINE = re.compile(
    r'!?\[(?:[^\[\]\n]|\[[^\]\n]*\])*\]\(\s*(<[^>\n]*>|[^\s()]*(?:\([^\s()]*\)[^\s()]*)*)'
    r'(?:\s+(?:"[^"\n]*"|\'[^\'\n]*\'|\([^)\n]*\)))?\s*\)')
# Reference definition: [label]: destination "optional title".
REFERENCE = re.compile(r'^\s{0,3}\[[^\]\n]+\]:\s*(<[^>\n]*>|\S+)', re.MULTILINE)
AUTOLINK = re.compile(r'<([A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\s]*)>')
WINDOWS_PATH = re.compile(r'^(?:[A-Za-z]:[\\/]|\\\\)')
LINE_SUFFIX = re.compile(r'\.[^:/#?]+:\d+(?:-\d+)?(?:[#?].*)?$')


def maintained(path: str) -> bool:
    """Return whether this project maintains the Markdown file at a repository path."""
    if not path.endswith('.md') or path in UPSTREAM_FILES or path.startswith(UPSTREAM_DIRS):
        return False
    if not path.startswith(ARCHIVE):
        return True
    # Archived payloads stay byte-for-byte; only the indexes are maintained.
    return len(PurePosixPath(path[len(ARCHIVE):]).parts) <= 2 and path.endswith('/README.md')


def targets(content: str) -> list[str]:
    """Return link destinations outside code: inline, reference definitions and autolinks."""
    visible: list[str] = []
    fence: Optional[str] = None
    for line in content.splitlines():
        marker = FENCE.match(line)
        if marker:
            token = marker.group(1)
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = None
            continue
        if fence is None:
            visible.append(line)
    if fence is not None:
        raise ValueError('Unclosed Markdown fence')
    text = CODE_SPAN.sub('', '\n'.join(visible))
    found = INLINE.findall(text) + REFERENCE.findall(text) + AUTOLINK.findall(text)
    return [target[1:-1] if target.startswith('<') else target for target in found]


def problems(root: Path, path: str, content: str) -> list[str]:
    """Return one message per broken link in a maintained file."""
    try:
        found_targets = targets(content)
    except ValueError as error:
        return [f'{path}: {error}']
    found: list[str] = []
    for target in sorted(set(found_targets)):
        if (target.startswith('/') or target.lower().startswith('file:')
                or WINDOWS_PATH.match(target)):
            found.append(f'{path}: machine-specific link (use a code span): {target}')
            continue
        if '://' not in target and LINE_SUFFIX.search(target):
            found.append(f'{path}: line suffix makes a missing link target '
                         f'(cite the line outside the link): {target}')
            continue
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
