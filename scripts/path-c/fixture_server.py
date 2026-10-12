"""Serve original, deterministic text for the real Legado iOS runtime."""

from __future__ import annotations

import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


def source(base: str) -> dict[str, object]:
    return {
        "bookSourceName": "Path C Controlled Source",
        "bookSourceUrl": base,
        "bookSourceType": 0,
        "bookSourceGroup": "Path C",
        "enabled": True,
        "searchUrl": base + "/search?key={{key}}&page={{page}}",
        "ruleSearch": {
            "bookList": "class.book",
            "name": "class.name@text",
            "author": "class.author@text",
            "bookUrl": "class.name@href",
        },
        "ruleBookInfo": {
            "name": "tag.h1@text",
            "author": "class.author@text",
            "intro": "class.intro@text",
            "tocUrl": "class.toc@href",
        },
        "ruleToc": {
            "chapterList": "class.chapter",
            "chapterName": "text",
            "chapterUrl": "href",
        },
        "ruleContent": {
            "content": "id.content@text",
            "nextContentUrl": "class.next@href",
        },
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        request = urlsplit(self.path)
        query = parse_qs(request.query)
        base = f"http://127.0.0.1:{self.server.server_port}"
        # Each full harness run gets new book/chapter URLs without deleting old caches.
        prefix = ""
        parts = request.path.split("/")
        if len(parts) >= 4 and parts[1] == "runs":
            prefix = "/".join(parts[:3])
            request = request._replace(path="/" + "/".join(parts[3:]))
            base += prefix
        status = 200
        content_type = "text/html; charset=utf-8"
        body = ""
        if request.path == "/sources.json":
            body = json.dumps([source(base)], ensure_ascii=False)
            content_type = "application/json; charset=utf-8"
        elif request.path == "/search":
            key = query.get("key", [""])[0]
            if key == "slow":
                time.sleep(8)
            if key == "http-error":
                status = 503
            elif key != "missing" and query.get("page", ["1"])[0] == "1":
                body = '<div class="book"><a class="name" href="/book/1">Path C Book</a><span class="author">Fixture Author</span></div>'
        elif request.path == "/book/1":
            body = '<h1>Path C Book</h1><span class="author">Fixture Author</span><p class="intro">Original test text.</p><a class="toc" href="/toc/1">Contents</a>'
        elif request.path == "/toc/1":
            body = ''.join(f'<a class="chapter" href="/chapter/{n}">Chapter {n}</a>' for n in (1, 2, 3))
        elif request.path in ("/chapter/1", "/chapter/2", "/chapter/3"):
            number = request.path.rsplit("/", 1)[1]
            body = f'<h1>Chapter {number}</h1><div id="content"><p>C{number}-FIRST: The reader opens a quiet book.</p><p>C{number}-MIDDLE: Every paragraph must survive parsing.</p></div><a class="next" href="/chapter/{number}/part2">Next page</a>'
        elif request.path in ("/chapter/1/part2", "/chapter/2/part2", "/chapter/3/part2"):
            number = request.path.split("/")[2]
            body = f'<h1>Chapter {number}</h1><div id="content"><p>C{number}-LAST: The second web page ends this chapter.</p></div>'
        else:
            status = 404
            body = "Not found"
        if content_type.startswith("text/html"):
            body = body.replace('href="/', f'href="{prefix}/')
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=18765)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Fixture source: http://127.0.0.1:{args.port}/sources.json", flush=True)
    server.serve_forever()
