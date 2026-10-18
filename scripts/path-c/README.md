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

### Native boundary and process checks

[ADR-002](../../docs/architecture/decisions/ADR-002-engine-boundaries-and-upstream-validation.md)
records the long-lived ownership and upstream validation policy. These checks use
our real Kotlin bridge and synthetic data, and are cross-module integration tests;
some also assert UI-facing compatibility properties. Hosted Swift views establish
selected rendering/control-state evidence, not an end-to-end tapping journey.

`ReaderBoundaryTests` characterizes the real upstream empty-TOC failure as
`RULE: chapter_list_empty`: visible/retryable failure, no successful Contents/body
transition or shelf admission, and unchanged persisted resume/shared projection.
It does not change upstream parsing to return a successful empty catalog.

Real network replacement tests remain in place. Separate deterministic adapter
tests hold an actual successful detail or TOC reply at Swift delivery, complete B
through its body, then replay A after cancellation can no longer rewrite the held
payload. They assert B's identity/catalog/body/route and reject a stale A TOC
follow-up. The internal `ReaderModel` delivery initializer defaults to immediate
application; it is not a new Kotlin/public API or a parser behavior change.
Removing only the completion generation guard must fail those adapter assertions;
HTTP cancellation alone is not sufficient evidence of that protection.

The remaining tests cover shelved-body `cancelLoading` with and without a pending
real save, single/first/last chapters, and SQLite save rejection followed by retry
and navigation. Assert exact source/book/chapter, body, route, token and persisted
position; do not substitute `busy == false` for these properties. Existing suites remain in the ordinary
`native_product_ci.py` run, which rejects failures, skips or missing execution.
The owned reading fixture on 18769 additionally supplies per-run HTTP response
gates; binding an occupied port fails without using or terminating its owner.

After building `NativeReader` for testing with the matching `ReaderEngine`:

```sh
python3 scripts/path-c/process_interruption_regression.py \
  --xctestrun /absolute/DerivedData/Build/Products/NativeReader_NativeReader_iphonesimulator27.0-arm64.xctestrun \
  --output /absolute/new-interruption-evidence
python3 scripts/path-c/process_interruption_regression.py \
  --xctestrun /absolute/DerivedData/Build/Products/NativeReader_NativeReader_iphonesimulator27.0-arm64.xctestrun \
  --output /absolute/new-offline-restart-evidence --shelf-restart
```

Use the actual generated filename for the installed Xcode version. Each invocation
validates the synthetic host bundle and creates a new simulator internally; there
is deliberately no existing-device/UDID argument. All destinations, container
lookups, termination, shutdown and deletion use only its returned UUID. Container
paths must belong directly to that simulator's application directory, and are
refreshed after Xcode reinstalls the host. Only the exact-run manifest/verification artifact is
read. Four interruption phases preserve expected nonzero interrupted prepare exits
and require a successful independent verification process. Offline shelf verification
runs after the driver stops its own 18769 listener. Port 18771 is owned by the
interruption driver. Do not run the ordinary and restart suites concurrently because
they intentionally require the same exclusive reading-fixture port.

Use task-private Gradle/Konan/DerivedData directories, a fixed source revision and
new synthetic simulators. Link the Kotlin test executables first, then execute
only on an owned simulator rather than letting a default test task select an
existing device. Relevant existing suites are `EngineOperationNativeTest`,
`SearchModelSessionTest`, `IncrementalSearchNativeTest`,
`NativeShelfNativeIntegrationTest` and `NativeResumeNativeIntegrationTest`.
Record commands, versions, exit codes, executed counts and any environment failure.
A build is not an executed test. If simulator dyld or XCTest symbolication stalls
opening host Documents paths, inspect the owned process and use task-private `/tmp`
source/build copies; do not claim the stalled test passed.

## Temporary simulator cleanup

The C1, native product and interruption/restart runners shut down and delete only
simulators created by their own invocation, on success and on Python exception
unwinding (including KeyboardInterrupt). Evidence directories, logs and test
results remain on the host; the simulator's installed apps and data are disposable.
A shutdown error does not prevent deletion. A deletion error fails a successful run
or is logged alongside the original test failure, including the UUID to inspect.
Forced termination (for example SIGKILL) cannot execute Python cleanup.


## Required upstream synchronization regressions

C1 builds both iOS engine frameworks, compiles the original Compose iOS UI, and
runs the data/core/UI JVM regression suites. It then runs `kotlin_native_ci.py`. It selects one new
simulator, starts owned reading/search fixtures, and supplies their address plus
its UUID through `C1_NATIVE_SIMULATOR` to the Gradle
`data`, `core` and `engine-ios` simulator test tasks. Test execution cannot be
up-to-date even when compiled artifacts come from cache. Every module must emit
nonempty XML results without failures, errors or skips; the native JS concurrency
suite must be present. No default or pre-existing simulator is selected.

C1 then invokes `native_product_ci.py --include-process-tests`. The ordinary
Swift suite finishes and releases its fixtures before interruption and offline
shelf restart checks start. Process checks honor the selected Xcode and optional
`--runtime-version`; each successful phase verifies XCTest execution counts.

For the 2026-10-17 upstream synchronization, retain product schema 89/90/91 and
migration lineage unchanged. The new shared JS evaluator must inherit the
calling source script's coroutine context, including with and without a jsLib.
Nested/shared cancellation restoration and independent DOM lifetime remain
native regression requirements. Android's removed HandleFileHost is replaced
by upstream's file-dialog and PlatformFileService write paths; do not restore
its obsolete caller or its removed view model.
