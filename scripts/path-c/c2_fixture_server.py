"""Controlled C2 fixture with one recoverable chapter failure per URL namespace."""

from urllib.parse import urlsplit
from fixture_server import FixtureServer, Handler


class C2Handler(Handler):
    failed_paths: set[str] = set()

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        if path.endswith("/chapter/2"):
            paragraphs = "".join(f"<p>第{index}段：春天的风吹过窗前，读者继续阅读。标点与中文应保持完整。</p>" for index in range(200))
            body = f'<div id="content"><p>C2-FIRST</p>{paragraphs}<p>C2-MIDDLE</p></div><a class="next" href="{path}/part2">Next</a>'
            payload = body.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if path.endswith("/chapter/3") and path not in self.failed_paths:
            self.failed_paths.add(path)
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        super().do_GET()


if __name__ == "__main__":
    FixtureServer(("127.0.0.1", 18769), C2Handler).serve_forever()
