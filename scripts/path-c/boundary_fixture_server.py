"""Owned loopback gates for native reader integration tests."""
from threading import Event, Lock
from urllib.parse import urlsplit
from c2_fixture_server import C2Handler


class BoundaryHandler(C2Handler):
    gates: dict[str, tuple[Event, Event, Event]] = {}
    lock = Lock()

    def reply(self, body: str) -> None:
        payload = body.encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
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
