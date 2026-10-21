"""Owned loopback gates for native reader integration tests."""
from threading import Event, Lock
from urllib.parse import urlsplit
from c2_fixture_server import C2Handler


class BoundaryHandler(C2Handler):
    gates: dict[str, tuple[Event, Event, Event]] = {}
    lock = Lock()
    offline_runs: set[str] = set()
    chapter_requests: dict[str, list[str]] = {}
    failed_chapters: dict[str, str] = {}

    def reply(self, body: str) -> None:
        payload = body.encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        run_prefix = '/'.join(path.split('/')[:3])
        route = path[len(run_prefix):]
        if route.startswith('/offline/'):
            with self.lock:
                if route == '/offline/disable':
                    self.offline_runs.add(run_prefix)
                elif route == '/offline/enable':
                    self.offline_runs.discard(run_prefix)
                elif route.startswith('/offline/fail/'):
                    self.failed_chapters[run_prefix] = route.rsplit('/', 1)[1]
                requests = list(self.chapter_requests.get(run_prefix, []))
            self.reply(','.join(requests))
            return
        if route == '/toc/offline':
            self.reply(''.join(f'<a class="chapter" href="{run_prefix}/chapter/offline/{n}">Chapter {n}</a>'
                               for n in range(1, 27)))
            return
        if route.startswith('/chapter/offline/'):
            number = route.rsplit('/', 1)[1]
            with self.lock:
                self.chapter_requests.setdefault(run_prefix, []).append(number)
                unavailable = run_prefix in self.offline_runs or self.failed_chapters.get(run_prefix) == number
                gate = self.gates.get(run_prefix + '/chapter') if number == '2' else None
            try:
                if gate:
                    gate[0].set()
                    if not gate[1].wait(20):
                        self.send_error(504)
                        return
                if unavailable:
                    self.send_error(503)
                else:
                    self.reply(f'<div id="content"><p>Chapter {number} start.</p><p>Offline verified body {number}.</p></div>')
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                if gate:
                    gate[2].set()
            return
        prefix, _, endpoint = path.partition('/control/')
        if endpoint:
            action, key = endpoint.split('/')
            name = prefix + '/' + key
            with self.lock:
                gate = self.gates.setdefault(name, (Event(), Event(), Event()))
            if action == 'hold':
                self.reply('held')
            elif action == 'entered':
                self.reply('entered' if gate[0].wait(15) else 'timeout')
            elif action == 'release':
                gate[1].set()
                self.reply('released')
            elif action == 'completed':
                self.reply('completed' if gate[2].wait(15) else 'timeout')
            else:
                self.send_error(404)
            return
        parts = path.split('/')
        prefix = '/'.join(parts[:3])
        key = {'/book/1': 'detail', '/toc/1': 'toc', '/chapter/2': 'chapter'}.get(path[len(prefix):])
        with self.lock:
            gate = self.gates.get(prefix + '/' + str(key))
        try:
            if gate:
                gate[0].set()
                if not gate[1].wait(20):
                    self.send_error(504)
                    return
            if path.endswith('/toc/empty'):
                self.reply('<p>No chapters</p>')
            elif path.endswith('/toc/single'):
                self.reply(f'<a class="chapter" href="{prefix}/chapter/1">Chapter 1</a>')
            else:
                super().do_GET()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            if gate:
                gate[2].set()
