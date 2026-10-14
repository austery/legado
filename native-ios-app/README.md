# Native Reader

An independent SwiftUI/TextKit client of ReaderEngine, with bundle ID
`io.legado.pathc.nativereader`. It does not share a sandbox with existing readers
or the C1 harness. The app covers source import, incremental multi-source search,
contents, scrolling text, chapter navigation, typography, an explicit bookshelf
and durable reading positions with cached reopening. Changing an existing shelf
book's active source remains outside this slice.

## Deliberate UI defaults

These are product defaults awaiting owner feedback, not recovered Wanyuan values:

- System-available PingFang, Songti and Kaiti candidates; unavailable fonts are omitted.
- 22-point initial text; size range 16–36, line spacing 6 (0–18), paragraph spacing
  12 (0–30), margins 24 (12–64). Maximum text column width is approximately 760 points.
- Warm light background; optional dark appearance. Settings last for the view session.
- Explicit show/hide control button instead of guessed tap regions. Long-press text
  selection follows UITextView behavior. No custom pagination engine.
- Text layout keeps a paragraph-based UTF-16 anchor across typography and size
  changes. The reading coordinator saves accepted scroll positions through the
  native engine and finishes a reading session before navigation.

The existing IPA provides static menu, typography and navigation clues. It does
not establish default values, active interaction wiring or physical iPad comfort.
The approved scope and device acceptance are in local `SPEC-002`; its `docs/`
directory is ignored by the inherited repository policy.

## Incremental search (SPEC-004)

Search starts with **All enabled sources**, using the engine's enabled, supported
text-source list. **Selected sources** narrows the scope explicitly; selecting no
sources disables search. Title, author and combined input are passed to source
rules; individual sources determine which input they support.

Results arrive through one owned engine subscription. Exact, nonblank title/author
matches form provisional display groups. Expand a work to see its retained source
candidates, including the exact book URL. The discovered-source count uses distinct
sources, while the candidate count preserves multiple editions from one source.
Missing-author candidates remain separate. These counts do not certify readable
chapters or create persistent work identities.

Candidate selection remains available while peer sources search and opens that
candidate's own details and catalog. Shelf admission is still explicit; adding an
already shelved known-author work preserves its original source and saved progress.

Progress distinguishes successful/empty sources, failures and incomplete searches.
**Stop** retains completed results and marks them incomplete. A new search clears
old candidates and paging state. Query edits, scope changes, refresh, import,
navigation and candidate selection retire the old subscription before proceeding.
**More results** advances each eligible source's own page; failed sources require
an explicit **Retry**. **Source outcomes** also provides source-specific **Restart**.
Idle subscriptions remain available for these commands. Search activity is separate
from foreground loading, so it does not block expanding or selecting a candidate.

## Build

Use the existing repository JDK/Xcode/native-library setup, then:

```sh
./gradlew --no-daemon --no-watch-fs :engine-ios:linkDebugFrameworkIosSimulatorArm64 :engine-ios:linkDebugFrameworkIosArm64
xcodegen generate --spec native-ios-app/project.yml
xcodebuild -project native-ios-app/NativeReader.xcodeproj -scheme NativeReader \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath native-ios-app/build CODE_SIGNING_ALLOWED=NO build
```

The Xcode configuration selects the simulator or device debug framework by SDK.
Device signing requires an explicitly chosen development team; no identity is
hard-coded. Building does not authorize replacing or installing an existing app.

Package a device build for owner-side signing with:

```sh
python3 scripts/path-c/package_native_ipa.py package \
  native-ios-app/build-device/Build/Products/Debug-iphoneos/NativeReader.app \
  /absolute/path/to/new-candidate.ipa
python3 -m unittest discover -s scripts/path-c -p test_package_native_ipa.py
```

Do not use default `ditto` ZIP packaging: it can add `Payload/._NativeReader.app`.
AltSign selects the first Payload entry with an `.app` suffix without checking
whether it is a directory. On the iOS simulator the original package selected
that AppleDouble file and failed application parsing; the clean package selected
the real bundle and passed. macOS Foundation hides this entry from its directory
listing, so a Mac-only bundle check missed the defect. The packaging script omits
metadata, validates the archive, preserves executable permissions and refuses to
overwrite an existing delivery. This check does not prove device signing/install.

After the owner's physical `-1022` failure and explicit HTTP authorization, build
0.1.0 (2) adds ATS exceptions for the 16 exact HTTP hosts in their 20-source bundle
and three separately owner-approved observed redirect hosts (`www.kk169.la`,
`www.xyetianlian.com`, `www.xbotaodz.info`).
`project.yml` is the authoritative host list. There is no global arbitrary-load
override, wildcard/subdomain exception, lowered TLS version, or custom certificate
trust bypass. Other HTTP hosts, including redirects to unlisted hosts, still need
an explicit policy decision. These transport entries do not rewrite source rules.
Import remains independent of transport reachability and live source correctness.

## Validation status

2026-10-14 SPEC-004 checks on a dedicated task iOS simulator:

- Hosted Swift build succeeded with the actual ReaderEngine debug framework.
- All four `IncrementalSearchTests` passed against the real engine and controlled
  loopback HTTP sources: default-all fast partial candidates and exact selection
  while a peer is held; Stop retaining results and suppressing late updates;
  empty selected scope and query replacement; and idle-session pagination through
  failure, source retry and restart with independent source state/counts.
- All seven existing `ReadingJourneyTests` passed with explicit fixture subsets
  and stream-aware settling. They retain the real reader, shelf/re-add,
  missing-author, saved-position, regex-failure, typography and cancellation
  assertions. The reading save coordinator is unchanged by this search slice.
- The new tests observe the hosted model's work/candidate projection and commands.
  They do not automate tapping SwiftUI's disclosure rows. Physical iPad scope,
  expansion, incremental updates and candidate-to-reader acceptance remain pending.

Earlier 2026-10-12 local candidate checks:

- Device and simulator debug engine frameworks linked; original Compose UI compiled.
- C1 network / restart / fresh-network suites passed 82/82, 22/22 and 82/82
  observations. These include callback checks, not independent test counts.
- The independent app built for the simulator and, unsigned, for iOS devices.
- Three permanent hosted XCTest cases passed using the real engine and controlled HTTP source:
  import/search/detail/TOC/two-page content, startup cancellation recovery, stale
  search cancellation, chapter cancellation/failure preserving content, successful
  retry, file-provider error isolation, real reader view contents round trip, and
  long Chinese text remaining visible after typography and layout changes.
- The initial directory round-trip check used `scrollRangeToVisible` and observed
  a changing offset. Deterministic nonanimated paragraph positioning passed without
  changing product navigation code. The original timing cause was not independently
  instrumented; this is not evidence of a repaired product navigation defect.

Reproduce the app tests on a dedicated simulator with this fixture running:

```sh
python3 scripts/path-c/c2_fixture_server.py
# In another terminal, after generating the project:
xcodebuild -project native-ios-app/NativeReader.xcodeproj -scheme NativeReader \
  -destination 'platform=iOS Simulator,id=<dedicated simulator UUID>' \
  -derivedDataPath native-ios-app/build CODE_SIGNING_ALLOWED=NO \
  -only-testing:NativeReaderTests/ReadingJourneyTests test
```

For the four SPEC-004 hosted cases, also run
`python3 engine-ios/fixtures/search_fixture_server.py`. It binds an OS-assigned
loopback port and prints its base URL. Generate the test runner with
`build-for-testing`, then set `EnvironmentVariables.SPEC004_FIXTURE_BASE` in the
`NativeReaderTests` entry of the generated `.xctestrun` file to that printed URL.
Run that runner with `xcodebuild -xctestrun <generated file> -destination
'platform=iOS Simulator,id=<dedicated simulator UUID>' test-without-building`.
The tests require that environment value; no fixture port is pinned in Swift.
Use a dedicated task app/simulator containing only controlled fixture imports:
default-all intentionally searches every enabled text source. Per-test UUID
namespaces isolate responses, and teardown releases held fixture responses.

The C2 fixture binds loopback port 18769; the third chapter fails once per unique
URL namespace to exercise retry, and the second contains long original Chinese
text. Never terminate another process to take that port. C1 uses its existing
fixture ports and separate runner script.

The owner confirmed physical installation and successful search with a visible book.
Two complete live community-source journeys on the iPad, actual split-view
interaction, and owner comfort acceptance remain pending. Host-view resizing and
an unsigned device build do not satisfy those gates. Controlled loopback success
is not a whole-source compatibility claim. Expand `Import details` to compare the
filename, decoded UTF-8 length and hash when a device import differs from a local
test; source contents and credentials are not shown in those diagnostics.

## Build 3 regex progress guard

Kotlin/Native 2.3.20 can return invalid, regressing match ranges for an unchanged
community-source replacement pattern. Its replacement loop then stalls later
engine requests. Native replacement now preflights match progression and returns
UNSUPPORTED when ranges regress or are invalid; JVM/Android behavior is unchanged.
Valid empty matches and capture replacements retain their existing semantics.
This adds a native match traversal, not a replacement backend or source rewrite.
It does not bound pathological work inside one `find` call or claim full regex
compatibility. The affected source fails safely rather than becoming usable.

A deterministic hosted regression verifies that the failing search releases the
engine and the next source search succeeds. An additional temporary live probe
observed the original source failing safely and Dingdian returning 50 results.
The existing two reading/typography cases also passed. A standalone native probe
compiled with the actual guard verified invalid ranges, empty matches, capture
replacement and cancellation propagation. Gradle nativeTest was not run.
