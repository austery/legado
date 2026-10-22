"""Deterministic discovery pages; served only through the owned loopback fixture."""
from __future__ import annotations

from collections import Counter
from html import escape
import json
from threading import Lock
from urllib.parse import parse_qs
from fixture_server import source

_counts: Counter[str] = Counter()
_lock = Lock()


def discovery_response(base: str, route: str, query: str) -> tuple[int, str] | None:
    if not route.startswith('/discover/'):
        return None
    if route == '/discover/sources.json':
        item = source(base)
        item.update(bookSourceName='Discovery Fixture Source', bookSourceGroup='Discovery', enabledExplore=True,
                    jsLib="var listingRule='" + base + "/discover/dynamic-options?order=<Order(Broken:broken,Working:working)>';",
                    lastUpdateTime=1, exploreUrl=json.dumps([
                        {'title': 'Browse', 'type': 'title'},
                        {'title': 'Popular', 'url': base + '/discover/normal?page={{page}}'},
                        {'title': 'Retry pages', 'url': base + '/discover/retry?page={{page}}'},
                        {'title': 'Held pages', 'url': base + '/discover/held?page={{page}}'},
                        {'title': 'Options', 'url': base + '/discover/options?order=<Order(Hot:hot,New:new)>&page={{page}}'},
                        {'title': 'Dynamic options', 'url': '@js:listingRule'},
                        {'title': 'Empty', 'url': base + '/discover/empty?page={{page}}'},
                        {'title': 'Unavailable action', 'type': 'button', 'url': "java.startBrowser('https://fixture.invalid');"}]),
                    ruleExplore={'bookList': 'class.discovery-book', 'name': 'class.name@text',
                                 'author': 'class.author@text', 'intro': 'class.intro@text',
                                 'bookUrl': 'class.name@href', 'nextPageUrl': 'class.next@href',
                                 'hasMoreRule': "result.indexOf('data-more=' + String.fromCharCode(34) + 'true') >= 0"})
        return 200, json.dumps([item])
    key = route + ('?' + query if query else '')
    with _lock:
        _counts[base + key] += 1
        count = _counts[base + key]
        stats = {k[len(base):]: v for k, v in _counts.items() if k.startswith(base)}
    if route == '/discover/stats':
        return 200, json.dumps(stats)
    if route == '/discover/categories':
        return 200, json.dumps([{'title': 'Late categories', 'url': base + '/discover/normal?page={{page}}'}])
    values = parse_qs(query)
    page = int(values.get('page', ['1'])[0])
    kind = route.rsplit('/', 1)[-1]
    if kind == 'failure' or (kind == 'cursor-retry' and count == 1) or (kind == 'dynamic-options' and values.get('order') == ['broken']):
        return 503, 'Controlled discovery failure'
    if kind == 'empty' or page > 2:
        return 200, '<main data-more="false"></main>'
    second = page == 2 or kind in ('cursor-retry', 'cursor')
    repeat = kind == 'repeat'
    order = values.get('order', ['hot'])[0]
    tags = values.get('tags', [''])[0]
    title = ('Discovery second' if second and not repeat else 'Discovery first')
    book = '2' if second and not repeat else '1'
    if kind in ('options', 'option-held', 'dynamic-options'):
        title = order + (' ' + tags if tags else '')
        book = '2' if order == 'new' else '1'
    more = (not second or repeat) and kind not in ('options', 'dynamic-options', 'cursor', 'cursor-retry')
    if kind == 'option-held':
        more = page == 1 and order == 'hot'
    next_link = ''
    if kind == 'retry' and page == 1:
        next_link = f'<a class="next" href="{base}/discover/cursor-retry?cursor=second">Next</a>'
    body = (f'<article class="discovery-book"><a class="name" href="{base}/book/{book}">{escape(title)}</a>'
            '<span class="author">Fixture Author</span><p class="intro">Discovery fixture introduction</p></article>')
    # A conflicting search-only element proves the engine selected ruleExplore.
    return 200, f'<main data-more="{str(more).lower()}">{body}{next_link}</main><p id="search-only">Wrong search rule</p>'
