# Incremental search native fixtures

`search_fixture_server.py` serves synthetic HTML over loopback only. It binds port
0 and prints its actual base URL. Each test creates a UUID URL namespace and a
fresh temporary Room database. Tests exercise the public `ReaderEngine` API,
including the real native HTTP, QuickJS, rule parser, catalog, chapter cache and
resume paths. They do not import community sources or inspect reader data.

## Run

Use the repository wrapper, JDK 21, its configured build-logic JDK, Android SDK
and Xcode as described in [the engine setup](../README.md#reproduce). Prepare the
native simulator archives if they are not already available:

```sh
bash scripts/build-ios-native.sh ios_simulator_arm64
./gradlew :engine-ios:linkDebugTestIosSimulatorArm64 \
  -PenableIosTarget=true --no-daemon --no-watch-fs
```

Start the fixture in its own terminal and keep that process running:

```sh
python3 engine-ios/fixtures/search_fixture_server.py
```

Create and boot a dedicated, empty iOS simulator for this test. Use its UUID and
the URL printed by the fixture; do not use an owner reader simulator or device.
In another terminal, from the repository root:

```sh
export SPEC004_SIMULATOR='<dedicated simulator UUID>'
export SIMCTL_CHILD_SPEC004_FIXTURE_BASE='<printed http://127.0.0.1:port>'
xcrun simctl spawn "$SPEC004_SIMULATOR" \
  "$PWD/engine-ios/build/bin/iosSimulatorArm64/debugTest/test.kexe" \
  --ktest_filter='io.legado.engine.IncrementalSearchNativeTest.*'
```

Callbacks run on the main thread; the native test pumps its run loop while
waiting. The source fixture holds selected responses until a release request,
so incremental delivery and stale-response assertions do not depend on source
speed. The timeout case deliberately exceeds the shared 15-second page timeout.
Stop only the fixture process started in its owning terminal when finished.

## Coverage and limits

The fourteen native cases cover blank and uninitialized input, incremental fast
and delayed sources, strict default/selected scope, exact title/author grouping,
missing authors, distinct source counts with multiple candidates from one source,
HTTP failures, empty results, interaction rejection, page retry and termination,
restart generations, Stop and replacement retirement, cross-engine source-lease
fairness under two shared permits, exact-candidate details,
catalog and body access, immutable snapshots, title/author/combined controlled
queries, and a real HTTP timeout. A shelf regression also preserves a loaded
catalog, cached body, stored source, resume revision and nonzero paragraph offset.

The fixture provides synthetic empty default resources because this standalone
test binary does not bundle the UI defaults. Its temporary database provider is
restored only after owned search work has retired; previous temporary artifacts
are retained. Source import and normal runtime cache effects occur only in this
task-created environment. Search does not admit candidates to the shelf.

These checks do not establish physical-device interaction acceptance, compatibility
of the Wanyuan 66-source bundle, community-source availability, or Android/OHOS
runtime behavior. Run the existing C1/C3 suites and native safety gates separately;
this test class is not a substitute for them.
