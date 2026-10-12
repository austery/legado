"""Additional deterministic probes for the independent Swift engine harness."""
from __future__ import annotations

import json
import time
from urllib.parse import parse_qs, urlsplit

from fixture_server import FixtureServer, Handler, source


class EngineHandler(Handler):
    def do_GET(self) -> None:
        request = urlsplit(self.path)
        base = f"http://127.0.0.1:{self.server.server_port}"
        if request.path == "/engine-sources.json":
            variants = []
            for name in ["js-write", "js-read", "interaction", "webview", "rule-error", "page-error", "toc-error", "content-interaction", "cookie"]:
                item = source(base)
                item["bookSourceUrl"] = base + "/" + name
                item["bookSourceName"] = "Engine probe: " + name
                if name == "js-write":
                    item["ruleSearch"]["name"] = "@js:cache.put('path-c-proof','JS-CACHE-OK'); cache.get('path-c-proof');"
                elif name == "js-read":
                    item["ruleSearch"]["name"] = "@js:cache.get('path-c-proof');"
                elif name == "interaction":
                    item["ruleSearch"]["name"] = "@js:java.startBrowser('https://example.com','Verification'); 'must-not-succeed';"
                elif name == "webview":
                    item["searchUrl"] = base + '/search?key={{key}}, {"webView":true}'
                elif name == "rule-error":
                    item["ruleSearch"]["bookList"] = "@js:throw new Error('PATH-C-RULE-FAILURE');"
                elif name == "page-error":
                    item["ruleContent"]["nextContentUrl"] = "@js:'" + base + "/unavailable';"
                elif name == "toc-error":
                    item["ruleToc"]["nextTocUrl"] = "@js:'" + base + "/unavailable';"
                elif name == "content-interaction":
                    item["ruleContent"]["content"] = "@js:java.startBrowser('https://example.com','Verification'); 'must-not-cache';"
                    item["ruleContent"]["nextContentUrl"] = ""
                elif name == "cookie":
                    item["enabledCookieJar"] = True
                    item["searchUrl"] = base + "/cookie/search?key={{key}}"
                variants.append(item)
            self.respond(200, json.dumps(variants).encode(), "application/json")
        elif request.path == "/unavailable":
            self.respond(503, b"Unavailable")
        elif request.path == "/cookie/search":
            self.respond(200, b'<div class="book"><a class="name" href="/cookie/book">Cookie Book</a><span class="author">Fixture Author</span></div>', cookie=True)
        elif request.path == "/cookie/book":
            if "pathc=session" not in self.headers.get("Cookie", ""):
                self.respond(403, b"Cookie missing")
            else:
                self.respond(200, b'<h1>Cookie Book</h1><span class="author">Fixture Author</span><p class="intro">Cookie was received.</p><a class="toc" href="/toc/1">Contents</a>')
        elif request.path == "/search" and parse_qs(request.query).get("key") == ["timeout"]:
            time.sleep(25)
            self.respond(200, b"late response")
        else:
            super().do_GET()

    def respond(self, status: int, body: bytes, content_type: str = "text/html", cookie: bool = False) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type + "; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if cookie:
            self.send_header("Set-Cookie", "pathc=session; Path=/; HttpOnly")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    FixtureServer(("127.0.0.1", 18767), EngineHandler).serve_forever()
