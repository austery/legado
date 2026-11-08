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

This is a small scanner, not a full CommonMark parser. It handles inline links
and images (multi-line labels, nested parentheses, titles, angle brackets),
reference definitions, autolinks, block quotes, fenced and indented code, code
spans, entities and backslash escapes, and ATX and Setext headings. Known
limits: HTML <a> tags, link labels that contain brackets nested more than once,
and indented code inside list items (four-space list continuations are read as
code). Adopt a real parser if the documents outgrow these limits.
"""
from __future__ import annotations

import html
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from typing import Optional
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[2]
ARCHIVE = 'docs/_archive/'
# Markdown that upstream (huajideshutiao/legado) owns; see docs/agents/impact-radius.md.
UPSTREAM_FILES = frozenset({'README.md', 'English.md', 'api.md'})
UPSTREAM_DIRS = (
    'app/', 'benchmark/', 'core/', 'data/', 'desktop/', 'desktop-core/', 'foundation/',
    'headless/', 'iosApp/', 'modules/', 'ohosApp/', 'ui/',
)
QUOTE = re.compile(r'^\s{0,3}(?:>\s?)+')
FENCE = re.compile(r'^\s{0,3}(`{3,}|~{3,})')
INDENTED = re.compile(r'^(?: {4}|\t)')
LIST_ITEM = re.compile(r'^\s*(?:[-*+]|\d+[.)])\s')
CODE_SPAN = re.compile(r'(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)', re.DOTALL)
REFERENCE = re.compile(r'^\s*(?:(?:[-*+]|\d+[.)])\s+)?\[([^\]\n]+)\]:\s*(<[^>\n]*>|\S+)',
                       re.MULTILINE)
AUTOLINK = re.compile(r'<([A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\s]*)>')
ESCAPE = re.compile(r'\\([!-/:-@\[-`{-~])')
WINDOWS_PATH = re.compile(r'^(?:[A-Za-z]:[\\/]|\\\\)')
LINE_SUFFIX = re.compile(r'\.[^:/#?]+:\d+(?:-\d+)?(?:[#?].*)?$')
ATX = re.compile(r'^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$')
SETEXT = re.compile(r'^\s{0,3}(?:=+|-+)\s*$')


def maintained(path: str) -> bool:
    """Return whether this project maintains the Markdown file at a repository path."""
    if not path.endswith('.md') or path in UPSTREAM_FILES or path.startswith(UPSTREAM_DIRS):
        return False
    if not path.startswith(ARCHIVE):
        return True
    # Archived payloads stay byte-for-byte; only the indexes are maintained.
    return len(PurePosixPath(path[len(ARCHIVE):]).parts) <= 2 and path.endswith('/README.md')


def prose(content: str) -> list[str]:
    """Return the non-code lines, with block-quote markers removed."""
    lines: list[str] = []
    fence: Optional[str] = None
    previous_blank = True
    for raw in content.splitlines():
        line = QUOTE.sub('', raw)
        marker = FENCE.match(line)
        if marker:
            token = marker.group(1)
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = None
            lines.append('')
            continue
        if fence is not None:
            lines.append('')
            continue
        blank = not line.strip()
        if INDENTED.match(line) and previous_blank and not LIST_ITEM.match(line):
            lines.append('')  # Indented code block; previous_blank stays true.
            continue
        lines.append(line)
        previous_blank = blank
    if fence is not None:
        raise ValueError('Unclosed Markdown fence')
    return lines


def paragraphs(lines: list[str]) -> list[str]:
    """Join prose lines into paragraphs and remove code spans inside each."""
    blocks = '\n'.join(lines).split('\n\n')
    return [CODE_SPAN.sub('', block) for block in blocks]


def label_start(text: str, close: int) -> Optional[int]:
    """Return the index of the '[' that matches the ']' at close, or None."""
    depth = 0
    for index in range(close, -1, -1):
        char = text[index]
        if index > 0 and text[index - 1] == '\\':
            continue
        if char == ']':
            depth += 1
        elif char == '[':
            depth -= 1
            if depth == 0:
                return index
    return None


def inline_targets(text: str) -> list[str]:
    """Return destinations of inline links and images in one paragraph."""
    found: list[str] = []
    for match in re.finditer(r'\]\(', text):
        if label_start(text, match.start()) is None:
            continue
        index = match.end()
        while index < len(text) and text[index] in ' \t\n':
            index += 1
        if text.startswith('<', index):
            end = text.find('>', index)
            if end > 0 and '\n' not in text[index:end]:
                found.append(text[index:end + 1])
            continue
        depth, end = 0, index
        while end < len(text):
            char = text[end]
            if char == '\\':
                end += 2
                continue
            if char == '(':
                depth += 1
            elif char == ')':
                if depth == 0:
                    break
                depth -= 1
            elif char in ' \t\n':
                break
            end += 1
        if end > index:
            found.append(text[index:end])
    return found


def targets(content: str) -> list[str]:
    """Return link destinations outside code: inline, reference definitions and autolinks."""
    found: list[str] = []
    for block in paragraphs(prose(content)):
        found.extend(inline_targets(block))
        found.extend(AUTOLINK.findall(block))
        found.extend(target for label, target in REFERENCE.findall(block)
                     if not label.startswith('^'))  # [^1]: is a footnote, not a link.
    unwrapped = [target[1:-1] if target.startswith('<') else target for target in found]
    return [html.unescape(ESCAPE.sub(r'\1', target)) for target in unwrapped]


def slug(title: str) -> str:
    return re.sub(r'[^\w\- ]', '', title.strip().lower()).replace(' ', '-')


def anchors(content: str) -> set[str]:
    """Return GitHub-style anchors for ATX and Setext headings and explicit ids."""
    lines = prose(content)
    titles: list[str] = []
    for index, line in enumerate(lines):
        atx = ATX.match(line)
        if atx:
            titles.append(atx.group(1))
        elif (index + 1 < len(lines) and line.strip() and SETEXT.match(lines[index + 1])
              and not LIST_ITEM.match(line)):
            titles.append(line.strip())
    result: set[str] = set()
    counts: dict[str, int] = {}
    for title in titles:
        base = slug(title)
        count = counts.get(base, 0)
        counts[base] = count + 1
        result.add(base if count == 0 else f'{base}-{count}')
    result.update(re.findall(r'(?:id|name)=["\']([^"\']+)', content))
    return result


def check_target(root: Path, path: str, target: str) -> Optional[str]:
    """Return a message when a relative target does not resolve, otherwise None."""
    parsed = urlsplit(target)
    source = root / path
    filename = unquote(parsed.path)
    destination = (source.parent / filename).resolve() if filename else source.resolve()
    if not destination.is_relative_to(root.resolve()):
        return f'{path}: link leaves repository: {target}'
    if not destination.exists():
        return f'{path}: missing link: {target}'
    if parsed.fragment and destination.suffix.lower() == '.md':
        if unquote(parsed.fragment) not in anchors(destination.read_text()):
            return f'{path}: missing heading: {target}'
    return None


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
        message = check_target(root, path, target)
        if message:
            found.append(message)
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
