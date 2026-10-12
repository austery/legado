# Path C runtime fixtures

Start the deterministic source server with Python 3.9 or newer:

```sh
python3 scripts/path-c/fixture_server.py --port 18765
```

Import `http://127.0.0.1:18765/sources.json` into the isolated iOS simulator app. The server binds only to loopback. It is intended for the simulator on the same Mac, not physical-device testing.

## Expected behavior

1. Search `Path` on page 1: one result, **Path C Book** by **Fixture Author**.
2. Open its details: introduction is **Original test text.**
3. Open the TOC: **Chapter 1**, **Chapter 2**, **Chapter 3**, in that order.
4. Read Chapter 1: `C1-FIRST`, `C1-MIDDLE`, and `C1-LAST` each occur once in that order. The LAST paragraph comes from a second HTTP page.
5. Repeat with Chapter 2: the three corresponding `C2-` markers appear.
6. Search `missing`: empty success, not an error.
7. Search `http-error`: HTTP 503, not empty success.
8. Search `slow`, then cancel or start a newer search: no stale results should overwrite the new state. The server deliberately waits eight seconds before responding.

The fixture contains original test text. HTTP endpoint checks do not establish Legado runtime acceptance. Record actual simulator results independently. The separate `engine_fixture_server.py` adds JavaScript cache, interaction, WebView, rule-error, timeout, cookie, and failed-pagination probes on port 18767. See `engine-ios/README.md` for the Swift harness and process-restart verification. The original C0 client returns an empty search for HTTP 503; the C1 engine opts into explicit status validation.
