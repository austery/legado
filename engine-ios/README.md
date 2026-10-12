# ReaderEngine: Path C C1

A narrow Swift-callable iOS framework over the existing Legado runtime. This is an extraction experiment and validation harness, not the C2 reader product UI. The intended product interface takes Wanyuan Reader as its reference.

## Contract

Create `ReaderEngine`, call `initialize`, import original Legado JSON, then call `search`, `loadBook`, `loadToc`, and `loadChapter`. Callbacks arrive on the main thread and return an `EngineReply` subclass. Room entities and Kotlin `Result` do not cross the boundary. Every book/chapter snapshot preserves its source and URL identities.

Each call returns an `EngineRequest`. Cancel the previous request when its result is no longer wanted; a newer search does not implicitly cancel another caller's search. Cancellation returns `CANCELLED`, including when the operation is waiting for the engine lock or its main-thread delivery. `close` cancels the session. Do not throw from a completion callback.

Initialization registers real upstream HTTP, cookies, QuickJS, Room, source cache and chapter storage providers once per process. Top-level calls are serialized across sessions because upstream content processors contain mutable caches. This is a correctness-first C1 boundary, not a concurrent search product API. Books and TOCs must be loaded in the current session before requesting a chapter. Imports invalidate that session's affected entities. Avoid concurrent source editing through multiple sessions in this slice.

Imports parse and validate the whole batch before one DAO insertion. The last object wins for duplicate source IDs; existing IDs are replaced. Malformed input preserves prior valid sources. Only text-book source operations are supported.

`loadChapter(cacheOnly: true)` never fetches. Other chapter calls use existing cached text first and otherwise reuse upstream pagination and formatting. Text is saved through the real upstream provider only after cancellation and interaction checks. A process restart retains imported sources, JS cache and chapter cache; searching/loading the TOC still requires network access in this slice.

Failures have stable codes: invalid input, missing entity, network/HTTP, timeout, rule failure, unsupported capability, interaction required, cancellation, and initialization/internal failure. Browser verification requests return `INTERACTION_REQUIRED`; background WebView returns `UNSUPPORTED`. No login UI is launched. A request-local latch preserves interaction failures even when the legacy JavaScript bridge swallows the provider exception.

## Dependency boundary

`engine-ios -> core -> data -> foundation`. The simulator compile dependency report contains neither `:ui`, Compose UI/foundation/material nor Skiko. Compose runtime remains as an existing data dependency. UIKit remains for the byte-identical relocated ImageOps implementation. The framework's exported header exposes the typed engine boundary, not the Room entities.

The root Gradle build still configures its other projects, including `:ui`; a configuration log entry is not an engine dependency. Run the original UI compilation separately as a regression check.

## Reproduce

Use the repository Gradle wrapper, JDK 21, its configured JDK 17 build-logic toolchain, Xcode, Android SDK and XcodeGen. Set `JAVA_HOME`, `DEVELOPER_DIR`, `ANDROID_HOME` and any required Gradle Java installation paths for your machine. Do not change global configuration.

```sh
bash scripts/build-ios-native.sh ios_simulator_arm64 ios_arm64
./gradlew --no-daemon --no-watch-fs \
  :engine-ios:linkDebugFrameworkIosSimulatorArm64 \
  :engine-ios:linkDebugFrameworkIosArm64 \
  :ui:compileKotlinIosSimulatorArm64
./gradlew :engine-ios:dependencies --configuration iosSimulatorArm64CompileKlibraries
xcodegen generate --spec engine-ios/harness/project.yml
xcodebuild -project engine-ios/harness/PathCEngineHarness.xcodeproj \
  -scheme PathCEngineHarness -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath engine-ios/harness/build ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
```

The native-library script removes its own temporary object directories. The validation run used a temporary copy with that cleanup omitted, preserving those generated objects. A reused Gradle daemon once reported modified files as up-to-date; a fresh process with file watching disabled rebuilt the actual modified sources. Do not accept a green cached task without confirming the staged native bridge matches the source.

Start each fixture server in a separate terminal:

```sh
python3 scripts/path-c/fixture_server.py --port 18765
python3 scripts/path-c/engine_fixture_server.py
```

Use a dedicated, booted simulator. The harness has its own bundle ID and sandbox. The following only installs/terminates the test harness; it does not alter installed reader apps:

```sh
export PATH_C_SIMULATOR='<dedicated simulator UUID>'
xcrun simctl install "$PATH_C_SIMULATOR" \
  engine-ios/harness/build/Build/Products/Debug-iphonesimulator/PathCEngineHarness.app
python3 scripts/path-c/run_harness.py --simulator "$PATH_C_SIMULATOR" \
  --output /tmp/path-c-full-result.json
python3 scripts/path-c/run_harness.py --simulator "$PATH_C_SIMULATOR" \
  --persistence --output /tmp/path-c-restart-result.json
```

Use new output paths on reruns; the runner refuses to overwrite previous evidence. It requires a terminal suite record and every assertion to pass. The persistence run performs no import and no JS cache write. The harness automatically runs on launch; its list is a diagnostic display.

## Upstream patch inventory and cost review

Seven existing files change, exceeding the proposed target of five by two. This is a reviewed extraction cost, not a claim that the target was met:

| Existing file | Reason and behavior |
| --- | --- |
| `settings.gradle.kts` | Include the additive engine module. |
| `core/build.gradle.kts` | Remove unused iOS Coil networking dependency that pulled in Skiko; UI retains its own image dependency. |
| `ui/src/iosMain/kotlin/io/legado/app/help/image/IosImageOps.kt` | Move unchanged into data iOS, same package and bytes; no copied business subsystem. |
| `data/src/commonMain/kotlin/io/legado/app/model/webBook/WebBook.kt` | Invoke optional request-context response validation after source login recovery. |
| `data/src/commonMain/kotlin/io/legado/app/model/webBook/BookChapterList.kt` | Apply the same policy to additional TOC pages. |
| `data/src/commonMain/kotlin/io/legado/app/model/webBook/BookContent.kt` | Apply it to additional content pages, including parallel pagination. |
| `data/src/nativeMain/kotlin/io/legado/app/model/script/NativeJsExtensionsBridge.native.kt` | Decode integer-tagged QuickJS object handles as integers instead of interpreting their union as a double. |

`WebBookResponsePolicy` is additive. Without its context element, existing clients retain their HTTP status behavior. Raw JavaScript HTTP helpers remain outside the policy, so scripts can inspect status codes and recover. The engine opts in to reject final non-success responses before parsing; otherwise a reproduced HTTP 503 became an empty successful search. The QuickJS correction fixes an independently reproduced upstream defect: handle 42 was decoded as 0, causing cache and browser host methods to disappear silently. It is separate from UI extraction and also affects the original native client.

The additional two-file cost is bounded: complete pagination failure reporting and a small verified bridge correction. No parser grammar fork, navigation copy, second database, or new business subsystem was introduced. C2 remains an owner decision. No Android/OHOS execution, release optimization, whole-source-pool compatibility, or physical-iPad product acceptance is claimed.

## Evidence

Local detailed evidence is under the repository's intentionally ignored `docs/evidence/path-c-c0` and `docs/evidence/path-c-c1` directories. C0 proved the original app's controlled flow plus unchanged Aixiashu and Dingdian samples. C1 simulator execution proves real import/search/detail/TOC/multi-page content, empty search, typed failures, JS cache, cookies, cancellation and persistence. Both device and simulator debug frameworks linked; the original UI recompiled. Consult the final acceptance record for exact run counts and framework digests.

Final 2026-10-12 simulator result: 72/72 records passed (32 behavioral assertions, 39 callback-thread checks, one terminal marker); process-restart result: 16/16. Source and JavaScript caches were not reimported/rewritten in the restart run. No verified owner-controlled remote exists: authenticated account `austery` has no accessible `austery/legado` repository, while both configured remotes are upstream owners. The deliverable is retained on the local task branch.
