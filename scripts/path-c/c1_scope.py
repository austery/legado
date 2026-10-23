"""Choose C1 evidence from a complete Git diff and enforce its final result."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
from typing import Callable, Mapping, Optional, Sequence
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[2]
DOCUMENTS = frozenset({
    'README.md', 'English.md', 'AGENTS.md', 'docs/VALIDATION.md', 'docs/MAINTENANCE.md',
    'engine-ios/README.md', 'native-ios-app/README.md', 'scripts/path-c/README.md',
})
LINK = re.compile(r'!?\[[^\]\n]*\]\(([^\s)]+)(?:\s+"[^"]*")?\)')


def git(root: Path, *args: str) -> bytes:
    return subprocess.check_output(['git', *args], cwd=root, stderr=subprocess.PIPE)


def document(path: str) -> bool:
    parts = PurePosixPath(path).parts
    return (not any(part in ('.', '..') for part in parts)
            and (path in DOCUMENTS or
                 (path.startswith('docs/architecture/') and path.endswith('.md'))))


def changed_paths(root: Path, base: str, head: str, pull_request: bool) -> list[str]:
    for revision in (base, head):
        if not re.fullmatch(r'[0-9a-f]{40}', revision) or revision == '0' * 40:
            raise ValueError('Missing or invalid comparison revision')
        git(root, 'cat-file', '-e', revision + '^{commit}')
    if git(root, 'rev-parse', 'HEAD').decode().strip() != head:
        raise ValueError('Checkout does not match selected head')
    start = git(root, 'merge-base', base, head).decode().strip() if pull_request else base
    # Disable rename detection: both old and new paths participate, without API limits.
    paths = git(root, 'diff', '--name-only', '--no-renames', '-z', start, head).decode().split('\0')
    return [path for path in paths if path]


def docs_only(root: Path, paths: Sequence[str], base: str, head: str) -> bool:
    if not paths or not all(document(path) for path in paths):
        return False
    for revision in (base, head):
        for path in paths:
            record = git(root, 'ls-tree', revision, '--', path).decode()
            if record and not record.startswith('100644 blob '):
                return False
    return True


def headings(content: str) -> set[str]:
    result: set[str] = set()
    counts: dict[str, int] = {}
    for title in re.findall(r'^#{1,6}\s+(.+?)\s*#*$', content, re.MULTILINE):
        slug = re.sub(r'[^\w\- ]', '', title.lower()).replace(' ', '-')
        count = counts.get(slug, 0)
        counts[slug] = count + 1
        result.add(slug if count == 0 else f'{slug}-{count}')
    return result


def links(content: str) -> set[str]:
    # Exclude fenced examples; only inline Markdown links are checked.
    visible: list[str] = []
    fence: Optional[str] = None
    for line in content.splitlines():
        marker = re.match(r'^\s{0,3}(`{3,}|~{3,})', line)
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
    return set(LINK.findall('\n'.join(visible)))


def check_link(root: Path, source: Path, target: str) -> None:
    parsed = urlsplit(target)
    if parsed.scheme or parsed.netloc or target.startswith('/'):
        return  # Remote and machine-local paths are outside repository static checks.
    filename = unquote(parsed.path)
    destination = (source.parent / filename).resolve() if filename else source
    if not destination.is_relative_to(root.resolve()):
        raise ValueError(f'{source.relative_to(root)}: link leaves repository: {target}')
    if not destination.exists():
        raise ValueError(f'{source.relative_to(root)}: missing link: {target}')
    if parsed.fragment and destination.suffix.lower() == '.md':
        content = destination.read_text()
        anchors = headings(content)
        anchors.update(re.findall(r'(?:id|name)=[\"\x27]([^\"\x27]+)', content))
        if unquote(parsed.fragment) not in anchors:
            raise ValueError(f'{source.relative_to(root)}: missing heading: {target}')


def check_documents(root: Path, paths: Sequence[str], base: str) -> None:
    affected = set(paths)
    for path in paths:
        if not document(path) or not (root / path).is_file():
            continue
        content = (root / path).read_text()
        try:
            previous = git(root, 'show', f'{base}:{path}').decode()
        except subprocess.CalledProcessError:
            previous = ''
        try:
            old_links = links(previous)
        except ValueError:
            old_links = set()
        for target in links(content) - old_links:
            check_link(root, root / path, target)
    # Detect inbound links broken by a deleted/renamed document or removed heading.
    tracked = git(root, 'ls-files', '-z').decode().split('\0')
    for path in tracked:
        if not document(path) or not (root / path).is_file():
            continue
        try:
            targets = links((root / path).read_text())
        except ValueError:
            if path in affected:
                raise
            continue  # Existing unrelated fence defects do not block this diff.
        for target in targets:
            parsed = urlsplit(target)
            if parsed.scheme or parsed.netloc or target.startswith('/'):
                continue
            destination = ((root / path).parent / unquote(parsed.path)).resolve()
            if destination.is_relative_to(root.resolve()) and destination.relative_to(root.resolve()).as_posix() in affected:
                check_link(root, root / path, target)


def accepted(mode: str, scope: str, engine: str, process: str, trusted: str) -> bool:
    if scope != 'success' or trusted != 'true':
        return False
    if mode == 'docs':
        return engine == process == 'skipped'
    return mode == 'regression' and engine == process == 'success'


def plan(root: Path, event: Mapping[str, object], event_name: str,
         on_classified: Optional[Callable[[str], None]] = None) -> tuple[str, list[str], str]:
    if event_name == 'workflow_dispatch':
        return 'regression', [], 'Manual validation always runs full regression'
    try:
        if event_name == 'pull_request':
            request = event['pull_request']
            if not isinstance(request, dict):
                raise ValueError('Invalid pull request')
            base_data, head_data = request['base'], request['head']
            if not isinstance(base_data, dict) or not isinstance(head_data, dict):
                raise ValueError('Invalid pull request revisions')
            base, head = str(base_data['sha']), str(head_data['sha'])
        elif event_name == 'push':
            base, head = str(event['before']), str(event['after'])
        else:
            raise ValueError('Unknown event')
        if event_name == 'pull_request' and re.fullmatch(r'[0-9a-f]{40}', base) and re.fullmatch(r'[0-9a-f]{40}', head):
            base = git(root, 'merge-base', base, head).decode().strip()
        paths = changed_paths(root, base, head, False)
        mode = 'docs' if docs_only(root, paths, base, head) else 'regression'
    except (KeyError, subprocess.CalledProcessError) as error:
        return 'regression', [], f'Comparison unavailable; full regression required ({type(error).__name__})'
    except ValueError as error:
        if str(error).startswith(('Missing or invalid', 'Checkout does not', 'Unknown event', 'Invalid pull request')):
            return 'regression', [], f'{error}; full regression required'
        raise
    if on_classified is not None:
        on_classified(mode)
    check_documents(root, paths, base)
    git(root, 'diff', '--check', base, head)
    return mode, paths, 'Complete pinned diff classified and documentation checked'


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('plan', 'gate'))
    args = parser.parse_args()
    if args.command == 'gate':
        passed = accepted(os.environ.get('MODE', ''), os.environ.get('SCOPE_RESULT', ''),
                          os.environ.get('ENGINE_RESULT', ''), os.environ.get('PROCESS_RESULT', ''),
                          os.environ.get('TRUSTED', ''))
        if not passed:
            raise SystemExit('C1 failed: invalid scope/static checks or required job results')
        print('Documentation static checks passed; runtime regression not applicable.'
              if os.environ['MODE'] == 'docs' else 'All C1 regression suites passed.')
        return
    mode = 'regression'

    def classified(selected: str) -> None:
        nonlocal mode
        mode = selected

    try:
        payload = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        if not isinstance(payload, dict):
            raise ValueError('Event must be an object')
        mode, paths, reason = plan(ROOT, payload, os.environ['GITHUB_EVENT_NAME'], classified)
        report = f'C1 mode: {mode}\n\n{reason}\n\nChanged files: {len(paths)}\n'
        print(report)
        summary = os.environ.get('GITHUB_STEP_SUMMARY')
        if summary:
            with Path(summary).open('a') as stream:
                stream.write(report)
    finally:
        output = os.environ.get('GITHUB_OUTPUT')
        if output:
            with Path(output).open('a') as stream:
                stream.write(f'mode={mode}\nrun_regression={str(mode != "docs").lower()}\n')


if __name__ == '__main__':
    main()
