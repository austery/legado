# ReaderEngine: Path C C1

A narrow Swift-callable iOS framework over the existing Legado runtime. This is an extraction experiment and validation harness, not the C2 reader product UI. The intended product interface takes Wanyuan Reader as its reference.

## Contract

Create `ReaderEngine`, call `initialize`, import original Legado JSON, then call `search`, `loadBook`, `loadToc`, and `loadChapter`. Callbacks arrive on the main thread and return an `EngineReply` subclass. Room entities and Kotlin `Result` do not cross the boundary. Every book/chapter snapshot preserves its source and URL identities.

Each call returns an `EngineRequest`. Cancel the previous request when its result is no longer wanted; a newer search does not implicitly cancel another caller's search. Cancellation returns `CANCELLED`, including when the operation is waiting for the engine lock or its main-thread delivery. `close` cancels the session. Do not throw from a completion callback.

Initialization registers real upstream HTTP, cookies, QuickJS, Room, source cache and chapter storage providers once per process. Top-level calls are serialized across sessions because upstream content processors contain mutable caches. This is a correctness-first C1 boundary, not a concurrent search product API. Books and TOCs must be loaded in the current session before requesting a chapter. Imports invalidate that session's affected entities. Avoid concurrent source editing through multiple sessions in this slice.

Repeated searches return fresh search snapshots while retaining existing session books, including detail-derived TOC URLs and rule variables. Reload details explicitly with `loadBook`; a lightweight search result does not replace that state or detach it from its loaded chapters.

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

Every normal run imports a fixture under a new `/runs/<UUID>` URL namespace, including its book, TOC and chapter URLs. This preserves earlier caches while ensuring the initial content read must report `fromCache == false`. The harness saves the fixture identity in its own preferences; `--persistence` reuses it and requires `fromCache == true`. Run normal mode before persistence mode. Both modes repeat the search after loading details and the TOC, then require the same chapter identities without reloading details.

## C1 continuous integration

The independent `C1 Engine` workflow runs automatically for relevant `native-reader` pull requests and pushes on the repository-scoped `legado-macmini-local` runner (`self-hosted`, `macOS`, `ARM64`, `legado-macos-local`). Fork pull requests are excluded from this personal host. Feature-branch pushes are covered by their PR event, avoiding duplicate automatic runs. The inherited `Test Build` workflow skips this fork and cannot start upstream packaging or publication from these changes.

Runner installation: `/Users/leipeng/GitHubRunners/legado`; checkout: `_work/legado/legado`. Start `./run.sh` from the installation directory and wait for `Listening for Jobs`. No launch service is installed. If it is offline, jobs queue rather than falling back to cloud. Stop only this runner, after GitHub reports it idle, using Ctrl-C in its owning terminal. Other repository runners are independent and must not be stopped or reconfigured. This is a native process under the logged-in user, not an isolation sandbox.

Manual dispatch accepts `execution=local` (default) or `execution=cloud`. The cloud option uses the standard ARM64 `macos-26` runner and Xcode 26.5; local execution uses `/Applications/Xcode.app` (Xcode 27 at initial validation). Both use JDK 17/21 and a task-local XcodeGen 2.46.0 download. The local runner has its own `android-sdk/` copy for shared Gradle module configuration; the cloud route uses its preinstalled SDK. No Android build or test is added. Manual cloud dispatch has been accepted for `codex/c1-cloud-ci` in this repository without changing its default branch.

```sh
gh workflow run c1-engine.yml --repo austery/legado \
  --ref codex/c1-cloud-ci -f execution=cloud
```

Both routes build the debug device and simulator engine frameworks, compile the original UI, build the isolated Swift harness, and run full network, process-restart cache and fresh network suites against local fixtures. Gradle and Kotlin/Native caches stay under this runner's tool-cache directory. Local caches persist; GitHub Gradle-cache upload/restore is disabled for self-hosted execution. `scripts/path-c/ci_harness.py` creates and shuts down only its own simulator and terminates only its fixture processes. Shutdown simulators are retained for inspection; no existing simulator or reader app is deleted. The script also runs against an already-built harness with `python3 scripts/path-c/ci_harness.py --output <new-evidence-directory>` and an explicit `DEVELOPER_DIR` when needed.

The job uses read-only repository permissions, a 60-minute timeout and seven-day evidence retention. New commits do not automatically cancel a running local job, allowing its owned fixture/simulator cleanup to finish. The single local runner serializes jobs. It does not sign an app, publish a release, use live community sources or implement C2. Standard hosted minutes remain free for this public repository. Required branch checks are a separate setting. Passing either route proves the bounded C1 contract, not physical-device acceptance or equivalence between the two Xcode versions.

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

Initial 2026-10-12 simulator result: 72/72 records passed (32 behavioral assertions, 39 callback-thread checks, one terminal marker); process-restart result: 16/16. PR #1 review follow-up reproduced the repeated-search TOC failure on the original engine (76/77, HTTP 404), then passed 77/77 with the fix, 20/20 after process restart, and 77/77 on another normal run with earlier caches retained. Both normal runs required network content; restart required cached content. Simulator and device debug frameworks and the Swift harness rebuilt successfully. Detailed follow-up evidence is under `docs/evidence/path-c-pr1-review`. These counts include callback observations and are not independent test counts. Source and JavaScript caches were not reimported/rewritten in the restart run. Delivery is tracked in [PR #1](https://github.com/austery/legado/pull/1), on `codex/path-c-engine`; merge and C2 remain separate owner decisions.

## C3 native reading contract

The isolated C3 implementation adds persisted shelf operations and `openReading`.
It reads Book and the saved catalog before consulting a source, resolves a native
resume by exact chapter URL and index, and validates cached text against its saved
SHA-256 and UTF-16 length. Missing saved chapter identities require an explicit
chapter choice. A verified legacy chapter starts at its beginning; a new book
starts at its first non-volume chapter. Book creation time is not evidence of
previous reading because upstream initializes `durChapterTime` on construction.

`ContentReply.reading` is absent for books outside the shelf. Otherwise it contains
an opaque token, revision, normalized UTF-16 paragraph offset, a restore notice,
and whether the record can be saved. Unsupported record versions remain readable
at chapter start without overwriting the unknown format. Swift must wait for
layout/display before reporting a position and suppress layout-generated scroll
samples. It must show restore notices rather than silently interpreting a fallback
as an exact restoration.

`saveReadingPosition` and `finishReading` accept strictly increasing positive event
sequences and return their commit acknowledgement through `ReadingSaved`. They do
not return an `EngineRequest`: accepted persistence outlives cancellation of a
foreground request or session close. Retry and finish use a fresh event sequence,
even after an invalid or failed attempt. Finish invalidates its token only after a
successful commit. `abandonReading` explicitly discards a token without writing.
Flush and await acknowledgement before starting navigation work on the shared
engine gate. Native removal invalidates matching tokens across engine sessions.

Before saving, the engine rechecks current shelf/catalog identity, the shared Book
chapter projection and the exact cached body; the DAO independently checks the
resume revision in its transaction. This prevents a saved revision from attaching
to a destructive legacy replacement. An initial revision-zero token cannot prove
that an identical legacy replacement occurred before the first native save; there
is no persistent row-incarnation marker. Do not describe that case as proven
lifecycle invalidation.

Atomic cache replacement and retaining in-session text after cache-write failure
remain the separate C3 failure-recovery slice. These API changes alone do not prove
cross-process paragraph restoration or physical-device acceptance.
