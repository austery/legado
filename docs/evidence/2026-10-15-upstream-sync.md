# KMP upstream integration, 2026-10-15

## Pinned inputs and review boundaries

- Native base: `bafbc2d1507b0ac89bb9d8375a5255ed1b0e580c`.
- KMP upstream: `04f62774a5406a37979dacaf3b5fd5b87c71fcc9`.
- Common ancestor: `639bf78a7a4bba663848198d4291c3ebf251539f`.
- Upstream contributes 184 commits and changes 869 files; the native branch has
  48 commits after the common ancestor. Sixteen paths overlap, eight conflict.
- This is a merge into a feature branch targeting `native-reader`. Publication
  does not authorize merging, deploying, replacing an installed app, or accessing
  a user's database. The original checkout and its untracked files are preserved.

Review upstream history separately from integration decisions. Compare the merge
against both parents: the native parent shows the complete update; the upstream
parent shows the retained native product and its compatibility adaptations.

## Integration decisions

| Area | Resolution and reason |
| --- | --- |
| Room schemas | Preserve published native schemas 89 and 90 byte-for-byte. Use 91 for upstream's nullable `bookSourceIcon` and updated source view, with Room's 90-to-91 auto migration. Keep native 88-to-89 identity and 89-to-90 resume migrations. Upstream's unrelated schema 89 is not substituted into native migration history. |
| Search | Retain native session ownership, generation checks, source leases, cancellation, retry and Stop controls. Store continuation URLs only with accepted pages; retain them on retry and clear them on source restart/new search. |
| Chapter writes | Keep the native `AtomicChapterWriter`, including staged/final byte verification and failure reporting. Upstream's other atomic file-write improvements remain intact. |
| Transactions | Use upstream's shared `runInImmediateTransaction`, which retains the Room writer connection and immediate transaction used by the native implementation. |
| JavaScript | Preserve operation-local host failure observation and upstream's JavaScript error propagation. Retain native context isolation and cancellation changes alongside upstream recursion/atom-lifetime fixes. |
| Regex | Register upstream's `IosRuleRegex` and JSONPath bridge in the independent engine. Remove the obsolete Kotlin-regex preflight at the replaced call sites; the ICU backend owns those operations. Keep standalone guard coverage for remaining Kotlin-regex callers. |
| Gradle | Combine upstream signal-handler cinterop with native test linker options. |
| Book help | Upstream moved its image-aware provider into Compose UI. A small `EngineBookHelpAccessor` retains the existing text-cache/event/cover-path behavior without introducing a Compose dependency or expanding the native reader into an image reader. |

The migration path covers this application's published databases. Opening an
upstream-only schema-89 database is not an import or compatibility promise.
Rolling application code back after a schema-91 upgrade requires a pre-upgrade
backup or an explicit downgrade plan; do not install old code over upgraded data.

## Regression repairs found by the validation run

A separate checkout of the pinned native base reproduced five failures in the
selected legacy JVM suites: four XPath cases and one explore-option assertion.
The integration run additionally exposed a serializer assertion hard-coding the
old SearchRule field count, and an RSS test assuming missing-author books share
identity, contrary to the accepted native identity policy.

- XPath now excludes the context element from descendant steps, selects direct
  children for relative steps, recognizes function-token `not(...)`, and applies
  numeric predicate results (including `last()`) as positions. Existing public
  XPath tests provide the before/after oracle.
- Serializer coverage compares the delegated descriptor with the real serializer
  rather than fixing the number of fields.
- Explore-option coverage reflects the existing caller contract: supplied values
  are already resolved, including any prefix.
- RSS coverage asserts separate progress for unknown-author feeds and retains the
  original feed's saved position and the new feed's catalog.

- Native EPUB fixtures now include root-level ZIP entries and declare cover images
  in the manifest; the HTML/SVG cover wrapper uses the EPUB 2 guide. No parser
  behavior is changed to accommodate malformed fixtures.
- Concurrent staging reproduced duplicate UUIDs: 8,000 generated identifiers
  produced only 7,267 distinct values in the failing regression. iOS now uses
  Foundation `NSUUID` instead of the shared Kotlin/Native random generator.
  Exclusive staging and both byte-verification checks remain unchanged. OHOS
  retains its previous implementation and is outside this iOS validation claim.
- Uncaught JavaScript bridge errors are translated while the operation-local
  failure context is still available, preserving `INTERACTION_REQUIRED` instead
  of collapsing it into a generic rule error. Cancellation retains precedence;
  tests cover both caught and uncaught JavaScript errors and the next operation.

## Validation

The initial checks below ran against the integration source tree at `6fbe03a6` on macOS with
Xcode's iOS 27 simulator and the repository Gradle wrapper, using the existing
JDK 21 runner runtime (JDK 17 toolchain for requested JVM tasks).

| Check | Observed result |
| --- | --- |
| JVM regression | data 310, core 17, UI 239: 566 passed, zero failures/skips. Foundation has no JVM tests. |
| Native data | 47 passed, including native schema 88/89/90 upgrade to 91, preserved resume records, identity and cache/EPUB checks. |
| Native core | 8 passed, including concurrent UUID uniqueness, atomic staging/final verification and failure paths. |
| Native engine | 35 passed, including typed host failures, cancellation, context isolation and session ownership. |
| Swift application | 29 passed: reading journey, incremental search, restoration, save coordinator and resume engine. Includes continuation-URL retry and restart. |
| C1 real-engine fixture harness | 82/82 initial observations, 22/22 across process restart, 82/82 repeat observations. |
| Compilation | Simulator/device engine frameworks, original Compose UI simulator compilation, Swift test host, harness and unsigned device app all succeeded. |
| Fixture tooling | Two Python unit tests passed. |

All four opt-in interruption cases passed: before file publication, after file
publication, before database commit, and after database commit. Each verification
used a different process ID, and the interrupted preparation exited as expected
without acknowledging a completed save. Separate shelf prepare/verify processes
also passed, preserving the cached chapter and visible paragraph position after
disabling its source.

Test inputs are synthetic SQLite databases and loopback HTTP fixtures in
task-owned simulators. No installed user app or user database was
modified. These checks do not establish physical-device acceptance, live
community-source compatibility, or Android/OHOS build/runtime acceptance.

Separate standards and contract reviews inspected the integration hotspots and
follow-up fixes; neither reported a blocking finding. This is a bounded review
of compatibility adaptations, not a claim of exhaustive review of 184 upstream
commits.


## Independent review follow-up

The independent report `pr-19v1.md` reviewed `6fbe03a6` and retained eight blockers
and thirteen improvements. Its wider platform review supersedes the earlier
bounded review's absence of findings; passing C1/Web checks did not cover these
behaviors. Each retained item is treated as a claim checked against its callers.

| Review item | Evidence and decision | Follow-up |
| --- | --- | --- |
| F01 | Accept: Android player preparation releases its current file. | Release the old player before adopting the newly downloaded file, entirely on the main thread and after generation validation. |
| F02 | Accept: system-tree selection bypassed export persistence. | Use the same export-aware completion as the manual picker. |
| F03 | Accept: title callbacks synchronously reentered their ArkTS event thread. | Publish URL/back-navigation state in events before listeners; foreground getters read the snapshot without a round trip. |
| F04 | Accept: a component remount retained the prior load deduplication key. | Reset that key when binding the newly mounted component. |
| F05 | Accept: a hidden `.part` name cannot prove an extension writer has died. | Host startup no longer deletes unpublished extension files. Orphan files are retained rather than risking a live transfer; writer-owned cleanup remains local. |
| F06 | Accept: finally signals completion, not persistence success. | Share a suspending import operation between manual and automatic import; database exceptions propagate to the automatic caller. |
| F07 | Accept: failed local-file checks never published the terminal current chapter. | Publish a message chapter only for the still-current chapter/job, allowing the existing headless session to close and retry. |
| F08 | Accept: three default templates silently truncated paragraphs. | Send complete text; provider rejection is an explicit failure rather than silently skipped speech. Live provider length limits are not certified. |
| F09 | Accept: generation rejection preceded guard cleanup. | Move rejection inside the existing try/finally ownership region; controlled dispatch regression schedules, pauses, drains and retries. |
| F10 | Accept: the caller already extracts the first match. | Provider replace-first replaces within its supplied text without a second extraction, preserving context-sensitive unmatched text. |
| F11 / S01 | Accept: Foundation does not expand Java named templates. | Expand named/numeric/escaped references against native match ranges; reject nonexistent names and preserve unmatched optional groups as empty. |
| F12 | Accept: a fixed `.bak` sibling is not operation-owned. | Allocate a unique backup for each replacement; never remove an unrelated fixed-name sibling, including explicit target deletion. |
| F13 | Accept: clearing the active token reused its sequence. | Separate the monotonic generation counter from the active loading owner. |
| F14 | Accept: continuing after a block timeout can omit preceding text. | Propagate the timeout and abort the complete TOC scan. |
| F15 | Defer: software-delivered signals do need different forwarding from repeating hardware faults. | Do not change Android signal disposition without a subprocess/device oracle for ART/debuggerd and restored custom handlers. This nonblocking item remains open. |
| F16 | Defer: queue policy duplication is real, but extraction changes native lifecycle boundaries. | Separate architectural follow-up; no behavior failure established by duplication alone. This nonblocking item remains open. |
| F17 | Accept: the palette callback captured a discarded state holder. | Include cover identity in callback lifetime keys. |
| F18 | Accept: failed defaults advanced versions and could remove old rows. | Strictly read resources before deletion, replace transactionally, advance versions only on success, and retry independently of release-notes app-version bookkeeping. |
| F19 | Accept: failed shelf deletion was reported as navigation success. | Exit only on successful removal; preserve state and route on failure. |
| F20 | Accept: unshelved RSS refresh used the previous in-memory index. | Update the in-memory selection before conditionally persisting it. |
| F21 | Accept: cancelled initialization could mutate the process-wide audio session. | Rethrow cancellation before fallback resolution and global writes. |

Follow-up validation observed on the repaired source tree:

- JVM: data 315, core 17, UI 241; **573 passed**, zero failures/errors/skips.
  New regressions exercise a queued load followed by pause/retry, context-sensitive
  first-match rules, an unrelated backup sibling on successful/failed replacement,
  automatic import database failure/retry, strict default-resource parsing and
  transactional rollback/version retry, and first-block TXT timeout propagation.
- Native simulator: data **47**, core **8**, engine **36 passed**. The added engine
  test invokes the actual Kotlin/Foundation bridge for named, numeric, escaped,
  unmatched optional, nonexistent and extended-comment replacement groups.
- Swift application: all **29** reading/search/restoration/save tests passed again.
- Android `:app:compileAppDebugKotlin`, original Compose UI simulator compilation,
  simulator/device engine frameworks, Swift test host, C1 harness and unsigned
  device application built.
- Offline evaluation of all three default TTS URL templates preserved the complete
  input in **30** boundary cases (around 200/300/900 characters and longer text).
  This evaluates the templates with an encoding stub, not a live speech provider.
- Standards review found no blocking issue. Spec review identified a neighbor-page
  publication hazard and invalid named-group handling in the first repair draft;
  both were corrected and the follow-up review found no remaining blocking issue.

Android playback/picker runtime, OHOS build/device behavior, native share-extension
cross-process timing and rendered palette/navigation outcomes were not exercised.
Those fixes have source/control-flow evidence and applicable compilation, not
platform acceptance. F15 and F16 remain explicitly open recommendations. No user
app, real provider, or user database was used by these fault-injection tests.
The four interruption cases and shelf restart evidence in the initial section
belong to `6fbe03a6`; they were not rerun for this follow-up.
