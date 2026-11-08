"""Check that relative Markdown links in this project's own documents resolve.

Rules (global-skills agents/DOC-LIFECYCLE.md, "Link check"):
- every relative Markdown link resolves to an existing file, and a heading
  fragment to an existing heading;
- absolute paths and file: links fail; write a machine-specific path in a code
  span instead;
- archived files are not checked; the archive indexes are.

Markdown is parsed with markdown-it-py (CommonMark), pinned with hashes in
requirements-doc-links.txt. Run it locally without a system install:
    uv run --no-project --with-requirements scripts/path-c/requirements-doc-links.txt \
        python scripts/path-c/doc_links.py

Upstream-owned Markdown is not checked. Fixing it would edit upstream files,
which adds merge conflicts to every upstream integration, and the help pages
under ui/.../composeResources/ are app content whose links resolve inside the
app, not in this repository. Raw HTML links (<a href>) are not checked.
"""
from __future__ import annotations

from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from typing import Iterator, Optional
from urllib.parse import unquote, urlsplit

from markdown_it import MarkdownIt
from markdown_it.token import Token

ROOT = Path(__file__).resolve().parents[2]
ARCHIVE = 'docs/_archive/'
# Markdown that upstream (huajideshutiao/legado) owns; see docs/agents/impact-radius.md.
UPSTREAM_FILES = frozenset({'README.md', 'English.md', 'api.md'})
UPSTREAM_DIRS = (
    'app/', 'benchmark/', 'core/', 'data/', 'desktop/', 'desktop-core/', 'foundation/',
    'headless/', 'iosApp/', 'modules/', 'ohosApp/', 'ui/',
)
WINDOWS_PATH = re.compile(r'^(?:[A-Za-z]:[\\/]|\\\\)')
HTML_ID = re.compile(r'\b(?:id|name)=["\']([^"\']+)')
LINE_SUFFIX = re.compile(r'\.[^:/#?]+:\d+(?:-\d+)?(?:[#?].*)?$')


def parser() -> MarkdownIt:
    md = MarkdownIt('commonmark')
    # CommonMark renderers drop file: and similar links; keep them so they can fail here.
    md.validateLink = lambda url: True
    return md


PARSER = parser()


def maintained(path: str) -> bool:
    """Return whether this project maintains the Markdown file at a repository path."""
    if not path.endswith('.md') or path in UPSTREAM_FILES or path.startswith(UPSTREAM_DIRS):
        return False
    if not path.startswith(ARCHIVE):
        return True
    # Archived payloads stay byte-for-byte; only the indexes are maintained.
    return len(PurePosixPath(path[len(ARCHIVE):]).parts) <= 2 and path.endswith('/README.md')


def _inline_links(tokens: list[Token]) -> Iterator[tuple[int, str]]:
    for token in tokens:
        if token.type != 'inline' or not token.children:
            continue
        line = token.map[0] + 1 if token.map else 1
        for child in token.children:
            if child.type == 'link_open':
                yield line, str(child.attrGet('href') or '')
            elif child.type == 'image':
                yield line, str(child.attrGet('src') or '')


def targets(content: str) -> list[tuple[int, str]]:
    """Return (line, destination) for inline links, images, autolinks and reference definitions."""
    env: dict = {}
    found = list(_inline_links(PARSER.parse(content, env)))
    # Reference definitions count even when no link uses them.
    for reference in env.get('references', {}).values():
        found.append((reference.get('map', [0])[0] + 1 if reference.get('map') else 1,
                      str(reference.get('href', ''))))
    return found


def slug(title: str) -> str:
    return re.sub(r'[^\w\- ]', '', title.strip().lower()).replace(' ', '-')


def heading_text(inline: Token) -> str:
    """Return the displayed text of a heading, without Markdown markup or link targets."""
    parts: list[str] = []
    for child in inline.children or []:
        if child.type in ('text', 'code_inline'):
            parts.append(child.content)
        elif child.type in ('softbreak', 'hardbreak'):
            parts.append(' ')
    return ''.join(parts)


def anchors(content: str) -> set[str]:
    """Return GitHub-style anchors for headings, plus ids of real HTML elements."""
    tokens = PARSER.parse(content)
    result: set[str] = set()
    counts: dict[str, int] = {}
    for index, token in enumerate(tokens):
        if token.type == 'heading_open':
            base = slug(heading_text(tokens[index + 1]))
            count = counts.get(base, 0)
            counts[base] = count + 1
            result.add(base if count == 0 else f'{base}-{count}')
        html_parts = [token] if token.type == 'html_block' else [
            child for child in token.children or [] if child.type == 'html_inline']
        for part in html_parts:
            result.update(HTML_ID.findall(part.content))
    return result


def check_target(root: Path, path: str, target: str) -> Optional[str]:
    """Return a message when a relative target does not resolve, otherwise None."""
    parsed = urlsplit(target)
    source = root / path
    filename = unquote(parsed.path)
    destination = (source.parent / filename).resolve() if filename else source.resolve()
    if not destination.is_relative_to(root.resolve()):
        return f'link leaves repository: {target}'
    if not destination.exists():
        return f'missing link: {target}'
    if parsed.fragment and destination.suffix.lower() == '.md':
        if unquote(parsed.fragment) not in anchors(destination.read_text()):
            return f'missing heading: {target}'
    return None


def problems(root: Path, path: str, content: str) -> list[str]:
    """Return one message per broken link in a maintained file."""
    found: list[str] = []
    for line, target in sorted(set(targets(content))):
        decoded = unquote(target)
        if decoded.startswith('//'):
            message: Optional[str] = None  # Protocol-relative URL: external, not a local path.
        elif (decoded.startswith('/') or decoded.lower().startswith('file:')
                or WINDOWS_PATH.match(decoded)):
            message = f'machine-specific link (use a code span): {decoded}'
        elif '://' not in decoded and LINE_SUFFIX.search(decoded):
            message = f'line suffix makes a missing link target (cite the line outside the link): {decoded}'
        elif urlsplit(target).scheme or urlsplit(target).netloc or not target:
            message = None
        else:
            message = check_target(root, path, target)
        if message:
            found.append(f'{path}:{line}: {message}')
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
