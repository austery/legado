"""Controlled C2 fixture with one recoverable chapter failure per URL namespace."""

from urllib.parse import urlsplit
import json
from fixture_server import FixtureServer, Handler, source


class C2Handler(Handler):
    failed_paths: set[str] = set()

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        if path.endswith("/regex-sources.json") or path.endswith("/regex-search"):
            base = f"http://127.0.0.1:{self.server.server_port}" + path.rsplit("/", 1)[0]
            if path.endswith("/regex-sources.json"):
                rule = source(base + "/regex")
                rule["searchUrl"] = base + "/regex-search?key={{key}}"
                rule["ruleSearch"]["name"] = r"class.name@text##.*\]|小说全文阅读|小说全集"
                body = json.dumps([rule], ensure_ascii=False)
                content_type = "application/json; charset=utf-8"
            else:
                body = '<div class="book"><a class="name" href="/book/1">[剑来]小说全文阅读</a><span class="author">Fixture Author</span></div>'
                content_type = "text/html; charset=utf-8"
            payload = body.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
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
