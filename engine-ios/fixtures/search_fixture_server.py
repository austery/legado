#!/usr/bin/env python3
"""Deterministic loopback-only search fixture. No third-party source traffic."""
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from html import escape
from threading import Event, Lock
from urllib.parse import parse_qs, urlparse
import json
import time


class State:
    def __init__(self) -> None:
        self.lock = Lock()
        self.counts: Counter[str] = Counter()
        self.releases: dict[str, Event] = {}

    def release(self, namespace: str) -> None:
        with self.lock:
            event = self.releases.setdefault(namespace, Event())
        event.set()

    def wait(self, namespace: str) -> bool:
        with self.lock:
            event = self.releases.setdefault(namespace, Event())
        return event.wait(20)


state = State()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format_string: str, *arguments: object) -> None:
        pass

    def send(self, status: int, body: str, content_type: str = 'text/html; charset=utf-8') -> None:
        encoded = body.encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        try:
            self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        parts = parsed.path.strip('/').split('/')
        if len(parts) < 2:
            return self.send(404, 'Missing fixture namespace')
        namespace, action = parts[:2]
        if action == 'release':
            state.release(namespace)
            return self.send(200, 'released')
        if action == 'stats':
            with state.lock:
                counts = {key: count for key, count in state.counts.items()
                          if key.startswith(namespace + '/')}
            return self.send(200, json.dumps(counts), 'application/json')
        source = parts[2] if len(parts) > 2 else 'fast'
        if action == 'entered':
            if not state.wait(namespace + ':entered:' + source):
                return self.send(504, 'Request did not enter')
            return self.send(200, 'entered')
        parameters = parse_qs(parsed.query)
        page = int(parameters.get('page', ['1'])[0])
        query = parameters.get('key', ['work'])[0]
        key = f'{namespace}/{action}/{source}/{page}'
        with state.lock:
            state.counts[key] += 1
            count = state.counts[key]
        if action == 'search':
            state.release(namespace + ':entered:' + source)
            if source == 'slow' or (source == 'restart' and count == 1):
                state.wait(namespace)
            if source == 'timeout':
                time.sleep(25)
            if source == 'failure' or (source == 'paged' and page == 2 and count == 1):
                return self.send(503, 'Controlled source failure')
            if source == 'empty' or page > (2 if source == 'paged' else 1):
                return self.send(200, '<main data-more="false"></main>')
            if query not in ('work', 'Shared work', 'Fixture author', 'Shared work Fixture author', 'replacement'):
                return self.send(200, '<main data-more="false"></main>')
            title = 'Second page work' if page == 2 else 'Shared work'
            if query == 'replacement':
                title = 'Replacement work'
            if source == 'restart':
                title = 'Old edition' if count == 1 else 'New edition'
            author = '' if source.startswith('missing') else 'Fixture author'
            books = [('book' if page == 1 else 'page-two', title, author)]
            if source == 'duplicate':
                books.append(('alternate', title, author))
            body = ''.join(f'<article><a class="book" href="/{namespace}/info/{source}/{book}">{escape(name)}</a>'
                           f'<span class="author">{escape(writer)}</span><p class="intro">{source} search result</p></article>'
                           for book, name, writer in books)
            more = str(source == 'paged' and page == 1).lower()
            return self.send(200, f'<main data-more="{more}">{body}</main>')
        if action == 'info':
            book = parts[3] if len(parts) > 3 else 'book'
            return self.send(200, '<h1>Exact ' + escape(source) + '</h1><span class="author">Fixture author</span>'
                             f'<a class="toc" href="/{namespace}/toc/{source}/{book}">Catalog</a>'
                             f'<p class="intro">{source} detail</p>')
        if action == 'toc':
            book = parts[3] if len(parts) > 3 else 'book'
            return self.send(200, f'<a class="chapter" href="/{namespace}/content/{source}/{book}">{source} chapter</a>')
        if action == 'content':
            return self.send(200, f'<div class="content">{source} paragraph one.<br><br>{source} paragraph two.</div>')
        return self.send(404, 'Unknown fixture route')


if __name__ == '__main__':
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    print(f'http://127.0.0.1:{server.server_port}', flush=True)
    server.serve_forever()
