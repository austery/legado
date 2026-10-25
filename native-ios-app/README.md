# Native Reader

An independent SwiftUI/TextKit client of ReaderEngine, with bundle ID
`io.legado.pathc.nativereader`. It does not share a sandbox with existing readers
or the C1 harness. The app covers source import, incremental multi-source search,
contents, adaptive scrolling/two-page text, chapter navigation, typography, an explicit bookshelf
and durable reading positions with cached reopening. Explicit source switching
prepares replacement text before confirmation and starts the chosen chapter at
its beginning.

## Deliberate UI defaults

These are product defaults awaiting owner feedback, not recovered Wanyuan values:

- System-available PingFang, Songti and Kaiti candidates; unavailable fonts are omitted.
- 22-point initial text; size range 16–36, line spacing 6 (0–18), paragraph spacing
  12 (0–30), margins 28 (12–64). Maximum text column width is approximately 680 points.
- Warm light background; optional dark appearance. Typography and appearance apply globally and persist in this app's preferences across launches. Invalid saved layout values fall back to safe defaults; book progress remains owned by ReaderEngine.
- Tap the central half of the body (excluding its top/bottom fifths) to show or hide
  reading controls; the explicit accessible toggle remains available. Native text
  selection and scrolling remain available. Wide iPad landscape uses TextKit page containers.
- Text layout keeps a paragraph-based UTF-16 anchor across typography and size
  changes. The reading coordinator saves accepted scroll positions through the
  native engine and finishes a reading session before navigation.

The existing IPA provides static menu, typography and navigation clues. It does
not establish default values, active interaction wiring or physical iPad comfort.
The approved scope and device acceptance are in local `SPEC-002`; its `docs/`
directory is ignored by the inherited repository policy.

## Find in the current chapter (Issue #57)

Use **Find in chapter** in the reader controls to search the complete loaded chapter,
including off-screen text. Queries are literal and case sensitive. Typing highlights
matches and shows their count; **Previous match** and **Next match** explicitly
reveal an occurrence and wrap at the ends. **Clear** removes the query. Closing the
panel clears transient find state without undoing an intentional reading jump.

Only explicit navigation follows the existing paragraph-save path; typing, highlights,
rotation and typography do not write reading progress. Portrait and two-page landscape
share original UTF-16 ranges, including matches crossing a page boundary. Manual scrolling or page turning supersedes temporary find reveal focus; reflow
follows the latest accepted reading paragraph until another explicit find jump. Native
selection and Copy remain UIKit-owned. Source/book/chapter/session changes retire old
find state and queued publications. Find reads loaded text without network requests,
new engine exports, dependencies, schema changes or query history. It does not search
other chapters/books. See [SPEC-009](../docs/architecture/specs/SPEC-009-native-in-chapter-find.md)
for the approved H1 and acceptance limits. Owner H2 and merge approval remain pending;
merge is explicitly withheld.

## Two-page iPad reading (Issue #46)

The owner approved [H1](https://github.com/austery/legado/issues/46) on 2026-10-23.
At 900 points of available reader width, iPad landscape presents consecutive left
and right pages. Swipe horizontally to advance one spread. Portrait, narrow windows
and body heights below 160 points retain vertical single-column scrolling. A chapter
ends in its own spread; the right page may be empty. Existing chapter controls remain.

TextKit ranges refer to the original attributed chapter. Pagination is disposable
in-memory presentation state; no dependency, engine contract or storage format is
added. Rotation, window resizing, typography and controls reflow around the accepted
paragraph without saving reflow as user progress. A completed user turn samples the
left page's first paragraph using the existing reading token and save coordinator.
A paragraph spanning multiple pages can reopen at its beginning. Page numbers and
within-paragraph line positions are not persisted.

Validation adds original-text coverage/Unicode/page geometry checks and a real
simulator journey for bidirectional swipes, reflow, directory return, rejected saves
and process relaunch. Existing product and interruption/offline lanes remain required
where applicable. Screenshots and exact revision results belong to the task evidence;
this description is not an assertion that validation or physical acceptance passed.
The formal north star's 14-day iPad use and independent community sources remain
separate owner acceptance. H2 and merge approval remain pending.

## Shelf organization (Issue #51)

Library home shows named groups and ungrouped books together. Groups have one level;
a book may appear in several groups while keeping one active source and reading
record. New shelf admissions are ungrouped. Trial reading and caching remain
independent of shelf admission.

Use **New group** on home, a group's action menu to rename or delete it, and a
book's visible action menu or long press to **Set groups**. The checklist saves
explicit changes; Cancel keeps existing memberships. Batch editing shows mixed
memberships and preserves groups left untouched. **Select all** applies only to
the books in the current home or group, excluding books inside closed groups.
Grid and list views share these operations; the selected view persists globally.
Missing or unsupported cover images use a readable placeholder.

**Remove from this group** keeps the book on the shelf and in its other groups.
Deleting a group keeps its books; those with no remaining group appear on home.
**Remove from shelf** removes every group membership but retains reading records
and cached content. Explicit re-admission preserves the reading record and starts
ungrouped. Group and shelf removal require distinct actions; clearing cached text
remains a separate book operation.

The existing KMP representation supports at most 63 custom groups. Native commands
validate a coherent organization state and commit targeted changes atomically.
A stale editor requires Cancel and reopening to review the current groups; it never
silently reapplies old choices. See [Issue #51](https://github.com/austery/legado/issues/51)
for scope, acceptance and recovery limits. Simulator evidence does not establish
physical-device comfort, live-source acceptance or owner H2.

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

### Automatic native product gate

The `C1 Engine` workflow also runs the existing Swift product suites whenever
`native-ios-app/**` or its shared runtime/build dependencies change. After the C1
engine harness, it runs:

```sh
python3 scripts/path-c/native_product_ci.py --output /absolute/path/to/new-evidence-directory
```

Prerequisites are the already-built simulator ReaderEngine framework, Xcode,
XcodeGen and the repository's Python fixture environment. The runner builds the
actual test host, creates its own iPad simulator, and supplies owned loopback
fixtures. Reading uses port 18769; an occupied port fails instead of reusing or
terminating another server. Search uses an OS-assigned port. Parallel XCTest
workers are disabled because the suites exercise process-wide runtime state.
Only this invocation's simulator is shut down and deleted afterward, including
when a build or test fails. Logs and `.xcresult` evidence remain on the host.

The ordinary gate covers reading journeys, incremental search, restoration, save
coordination, resume engine behavior and reader boundary regressions.
The runner discovers ordinary test methods from the test sources and checks the
XCTest result summary: execution counts that differ from the tests discovered in
the current source, failures, skipped tests and zero-test runs fail the gate.
This does not detect tests deleted from the source. Available logs, the source
commit, selected runtime/simulator, scope manifest, summary and `.xcresult` are
retained locally. Hosted CI prints allowlisted evidence to Actions logs; manually
selected local CI uploads artifacts, excluding build intermediates.

`ProcessInterruptionTests` and `ShelfProcessRestartTests` require external,
multi-process orchestration. CI passes `--include-process-tests` to run them
sequentially after the ordinary fixtures close, using the same built test host
and separate invocation-owned simulators. All four interruption boundaries and
the two-process offline shelf journey must pass. Successful subprocess exits
also require exactly one passed XCTest with no skips. A standalone invocation
without this flag records those suites as not run. These synthetic checks do
not establish physical-device or power-loss acceptance.

### What counts as sufficient regression evidence

- Each required user contract has an observable assertion: exact candidate opens,
  current text survives a failed next chapter, and navigation waits for a saved
  position acknowledgement. Method names or a coverage percentage are not proof.
- Important failures cover state as well as errors: failed writes preserve the
  previous revision; stale callbacks cannot replace new results; cancellation
  does not cancel an already accepted save. A happy-path test is insufficient.
- Exercise the real boundary when that boundary is the risk: real ReaderEngine,
  SQLite/cache and Kotlin/Native bridges for integration; controlled writers and
  clocks for save-coordinator logic. A recording double cannot certify storage.
- A gate must fail when a test fails or tests discovered in the current source
  are missing from execution, run on the candidate source, and retain inspectable
  evidence. This gate compares counts, not stable test identities, and does not
  detect source-test deletion. A previous commit's green run is historical.
- Use separate processes for restart/interruption promises and physical iPad
  checks for touch/layout comfort, system permissions and platform lifecycles.
  Synthetic loopback sources do not certify all community sites or providers.

The stopping rule is risk-based: cover the changed contract, its meaningful
failure/recovery paths and affected existing journeys. Expand testing when a
failure or new dependency reveals additional risk, rather than pursuing 100%
coverage or indiscriminately running every platform. Physical acceptance remains
separate from automated regression.

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
  They do not automate tapping SwiftUI's disclosure rows. Subsequent physical
  iPad checks on commit `9cfd3b4bd` exercised scope, incremental results, an actual
  expansion tap and candidate-to-reader navigation. Overall acceptance remains
  partial: physical Stop/paging/retry/restart were not established. The large
  remote-drag blank was subsequently traced to overscroll and fixed in build 7;
  same-gesture physical checks in two chapters retained visible text. See the
  [dated device evidence](../docs/evidence/2026-10-14-spec004-ipad.md).

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


### Minimal reading UI and actual control validation

#### UI review contract (2026-10-17 candidate)

Keep the existing warm paper, bounded text column, chapter heading and optional
bottom controls. This continuation changes directory return behavior and feedback,
not the visual direction. Design rationale remains in local SPEC-002, persistence
in SPEC-003, and search in SPEC-004; those specs are historical scope documents,
not evidence that this candidate passed device acceptance.

- Already delivered: whole shelf-row taps, paragraph-preserving typography and
  rotation, Contents continuation, save rejection/retry and acknowledged shelf return.
- This candidate: tapping the marked current chapter in Contents uses the same
  return operation as Continue reading: writable shelf sessions reopen their saved
  position through the engine; unshelved or read-only sessions retain their current
  text view and paragraph without reopening an older stored chapter. Other chapters
  still open normally. The retained text view freezes its session anchor while the
  reading route is inactive, including UIKit scroll callbacks during directory layout.
  Shelf/Contents navigation is disabled during loading, while Cancel stays available.
  Save notices put the explanation above clearly separated action buttons.
- Acceptance: both directory return paths preserve the same nonzero paragraph;
  held next-chapter requests disable competing navigation and can be cancelled;
  save rejection retains the text, retry succeeds, and reopening after relaunch
  returns to the same chapter/paragraph. Inspect actual screenshots as well as tests.
- Remaining owner review: visual comfort, physical iPad touch/rotation and compact
  layouts. Session typography persistence remains unchanged. No new providers,
  source rules, database schema, or engine behavior are introduced.

The UI runner now uses PR22's shared cleanup helper on its own newly created
simulator, including failures; host screenshots/logs/results remain available.

Reading keeps the book/chapter heading above a bounded paper-colored text column.
The shelf return and control toggle stay in the toolbar; chapter navigation,
contents and typography sit together below the body. Text size and appearance
are immediately available in the typography sheet, with existing font/spacing
controls under More text options. Contents can continue the saved current chapter
through the real engine, obtaining a fresh writable reading token. A successful
shelf return confirms the acknowledged position; a failed save retains the body
and existing retry/discard choices. Whole shelf rows accept a tap.

The separate synthetic UI host compiles the same reader sources with
`READER_UI_TEST_HOST`, excludes the product app entry point, and uses bundle ID
`io.legado.pathc.ui-fixture`. Its setup imports an owned loopback source through
the real engine and searches its test book. The original journey explicitly shelves
its book; separate scenarios leave it unshelved or seed an unsupported saved-format
record to obtain a real canSave=false reply on a different chapter. Each test starts
with a fresh host database; only the relaunch check preserves it. Test-only controls
hold a chapter request and install/remove a rejecting SQLite trigger solely in
that host database. None of this setup or fault injection is part of NativeReader.

With the simulator engine already built, run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
python3 scripts/path-c/reader_ui_ci.py --output /absolute/path/to/new-ui-evidence
```

This creates a new simulator, operates actual controls with XCUITest, and retains
screenshots and `.xcresult`. It checks row-centre opening, chapter body markers,
first-chapter boundary, cancel/retry, real swipes, contents/continue, controls,
text size and rotation, rejected save without leaving, cancelling discard,
retry, acknowledged shelf return and same-chapter/paragraph reopening, including
process relaunch. The test host observes the actual TextKit paragraph anchor;
only setup and fault injection use test controls. No production provider, physical
device or existing reader data is involved. The ordinary Swift product
gate remains separate; UI tests do not replace it. The UI driver declares the current journey inventory in
[`reader_ui_ci.py`](../scripts/path-c/reader_ui_ci.py). It requires the selected
journeys to pass with no failures or skips; repeat `--only-test <method>` to select
relevant declared methods, or omit it to run the full inventory. Choose scope from
the changed behavior and risk rather than a historical test count. Both directory buttons are exercised
for unshelved and read-only sessions at nonzero anchors, with SQLite assertions for
no implicit shelf row and unchanged full resume/shared projection respectively. XcodeGen's ordinary
`project.yml` generation excludes this host and UI test target.

## Everyday native UI (PLAN-005)

Library, Search and Sources have distinct top-level destinations. Source files are
imported from Sources; search scope remains in Search. Selecting a candidate opens
its details and explicit Read first chapter / Add to shelf / Contents actions.
Returning to Search keeps the retained results and expanded candidates; it does
not restart cancelled source work. Details use only metadata the engine supplies.

Contents supports title filtering, empty-filter feedback and current-chapter
location. Continue reading and the marked chapter preserve the existing session
and paragraph rules. Reading settings group typography and appearance, persist
application-wide in `nativeReader.readingStyle.v1`, and do not introduce another
book/progress store. Removing that one optional preference key restores defaults;
older builds ignore it. Existing database schemas and source execution are unchanged.

The additional UI journey taps Sources, Search, an expanded candidate, Details,
filtered Contents and reading settings, then relaunches to check both saved style
and paragraph. Ordinary preference tests cover corrupt data, invalid layout values
and fresh-store reload. Run results, exact revisions and screenshot inspection are
recorded separately; adding tests is not a claim that they passed.

A separate two-source UI journey verifies catalog-filter reset and global settings
across source entries, without changing the original shelf entry.

## Explicit source switching (SPEC-005)

Change source is available for shelved books with a known title and author. Search
retains exact candidates; only another listing with the same trimmed title and
author is eligible. A unique trimmed chapter-title match is recommended; duplicate
or missing matches require manual selection. Volume headings are excluded.

The replacement chapter is fetched into immutable in-memory preparation before
confirmation. Confirmation validates URL ownership under the database write
transaction, then publishes and verifies the body cache before committing the
shelf record, catalog, and native resume,
preserving user shelf metadata. Reading starts at offset zero. Existing progress,
source-rule, and URL-ownership changes reject stale preparations. Cancel and
pre-commit failures retain the original source; a lost post-commit acknowledgment
is resolved only with this engine's successful commit receipt and matching durable
shelf/resume state. Preparation never overwrites a different book's cache.

The synthetic UI host can withhold only the final switch reply to test termination
after database commit but before UI acknowledgment. This hook is excluded from the
product application. The UI suite also terminates before confirmation and checks
that relaunch retains the old source. Actual results and revision evidence are
recorded separately; these test descriptions are not acceptance claims.


## Source management (SPEC-007)

Sources lists all imported text sources, including disabled ones. Search by name/address,
filter by enabled state and group, or enter selection mode for batch enable/disable,
group membership and JSON export. Selection survives view-only filtering. Source details
also provide individual membership and export actions.

File import first opens a review. New identities and sources with newer update timestamps
are selected by default; timestamps are advisory. Same-ID replacement is visible and optional.
Local name, groups and enabled/discovery-enabled settings are retained by default, and custom
order is always retained for existing sources. Duplicate IDs use the last file entry, with a
count in review. Confirmation compares the preview against current persisted sources inside
the same Room transaction as replacement. Cancel, malformed input, stale confirmation and
failed writes do not partially import sources.

Export serializes supported Legado configuration fields, including configured headers, and
normalizes dangerous API enablement to false, matching upstream export policy. Runtime
cookie stores, books, cached chapters and progress are separate and are not exported.
Disabled sources retain cached reading and shelf/progress data but do not enter new searches.
Rule editing, source login/browser verification and discovery browsing remain later work.

## Reading controls (Issue 48)

Reading starts with controls visible. The heading, shelf action and bottom controls
are overlays; hiding them leaves the text viewport and pagination unchanged. The
explicit Show/Hide controls button stays at the top right. A central-body tap toggles
controls; edge taps do not turn pages. Previous/Next chapter labels distinguish chapter
navigation from horizontal page turns. Returning from another route shows controls.
Loading/cancel, error/retry and save-rejection actions remain outside these overlays
and visible even when ordinary controls are hidden. Such notices may resize the
viewport and retain the established paragraph-recovery behavior.

The two focused UI journeys check actual taps, drags and native selection, stable
viewport/offset/rendered glyph ranges in portrait/spread/narrow modes, and hidden-control
save rejection, cancellation and network retry. Earlier assertions that controls sit
below the text are replaced by the intentional overlay contract, with independent
rendered-geometry comparisons added. No engine contract, stored format or dependency
changes. Physical comfort and owner H2 are separate from these automated checks.

Spread selection uses disposable single-container page views because UIKit disables
selection on the previous shared multi-container views. The original TextKit
pagination still defines every original chapter range; each attached page holds
only its attributed substring and original offset. At most the current spread and
its neighbors are retained. Page copies never enter the engine or saved progress.
Actual-page coverage tests check complete rendered ranges and original attributed
text at supported sizes, including long mixed-script/Unicode paragraphs. UI checks
long-press selection on both visible pages as well as portrait and narrow layouts.
