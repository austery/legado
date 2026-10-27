# E01: software-keyboard acceptance continuation

Date: 2026-10-26 (America/Toronto). Candidate UI test source: a100ae199791f76aaa5af1ce96548d0b632b37c8. Product sources are byte-identical to remote PR59 source84c23a8c0d4befd52434def9a765d64593fd0006. Two fresh native simulator invocations passed all four selected journeys at this source. Publication/required CI is revision-bound and reported on PR59; these UI results do not supply owner H2 or merge approval. The explicit no-merge hold remains.

## Evidence and repair boundary

The [prior callback report](2026-10-25-chapter-find-e01-keyboard.md) identifies an already-deallocated keyboard animation state with unmatched start/stop callbacks, leaving XCTest's animation counter positive. Its creation stack originates in hardware-keyboard-availability changes and keyboard minimization. That observation locates the synchronization mechanism, not the internal UIKit cancellation cause.

The current repair changes the acceptance input route to actual software-keyboard actions. Chinese queries are composed through Pinyin keys, exact candidate cells, number keys and visible Return. Roman queries use their original letters/case/punctuation and visible Return. Every original query is retained, including 第80段, 第120段, missing-phrase and C1-FIRST. Query field values are asserted exactly. The direct-landscape journey rotates BEFORE opening Find or entering text, repeats three times, and asserts typing neither navigates nor saves progress. Original match/count, rejected-save/retry, chapter retirement, source retirement and relaunch assertions remain intact.

There is no direct finder/model mutation, clipboard seeding, app fixture or driver change, timeout increase, test-count relaxation, animation disabling, counter reset or idleness bypass. The24-method declared inventory and strict four-selected-method terminal acceptance remain. This certifies the chosen software-keyboard user workflow; synthetic bulk-text/hardware-keyboard input remains a known diagnostic limitation rather than a certified repaired path. Production reader behavior is unchanged from84.

## Discarded product experiments

- Splitting text injection from a visible Return tap still reproduced idleness on iteration31; it was not retained.
- Keyboard-safe-area overlay attempts produced successful and reversed successful runs, without establishing a repair. Actual existing viewport observations still showed keyboard resizing. All overlay/host/constant-viewport edits were restored.
- Explicit finite-proposal UIViewRepresentable sizing passed a two-method discovery run, while reverting it with the same three-input test reproduced E01 on the third direct query (counter6). However, the sizing candidate itself then reproduced E01 in full-four confirmation (waits73.75s/135.18s). Commit0e3fd4cb1 explicitly reverts candidate e52c11ff4. No unproven production sizing repair is delivered.

## Paired input-route diagnostics

The same standalone SwiftUI/UIKit app, body, panel and12-query assertions were used for both routes. Its private callback recorder was diagnostic-only, forwarded original callbacks once, and is absent from NativeReader/NativeReaderFixture sources.

| Run directory under /private/tmp | Actual result | Limit |
| --- | --- | --- |
| e01-20261026-pinyin-input-4 | One original Chinese query composed through native Pinyin;141 starts/141 stops;0 hardware-keyboard-availability animation states | Locator/mechanism discovery, not product acceptance. |
| e01-20261026-pinyin-repeat-1 |12 original Chinese queries;2150 starts/2150 stops;0 hardware-keyboard-availability animation states; terminal1/1 pass | Actual repeated input on the independent app, not the reader. |
| e01-20261026-hid-origin-control-1 |12 original bulk Chinese+Return queries;6623 starts/6623 stops;24 hardware-keyboard-availability animation states; terminal1/1 pass | This control did not recur in this invocation. The earlier recorded failures establish the intermittent orphan signature; one clean control does not repair it. |
| e01-20261026-measurement-reverse-1 | Actual original reader with three original direct inputs recurred on the third; counter6 before/after inspection; intentionally interrupted after two60-second waits | Diagnostic failure, not a passing aggregate. |

These observations distinguish the source of the previously orphaned animation states: bulk injection exercises transient hardware-keyboard changes, whereas the real software-keyboard route did not. They do not prove every UIKit animation is correct or certify hardware keyboards.

## Execution prerequisites and provenance

ARM64 Mac; process-selected Xcode27.1 build27A9275; available iOS27.0 simulator build24A434; invocation-owned iPad Pro11-inch M4. The UI helpers require full-size Simplified Pinyin/Roman keyboard layouts and English accessibility labels, and fail if the observed controls/candidates are unavailable. No host-global setting or runtime installation was changed. Native reader UI and product suites retain their own fixture/storage evidence boundaries.

Run folders retain exact commands, commit/scope metadata, simulator UUIDs, logs, source hashes/recipe revisions and available xcresults/screenshots. Each owning driver releases its exact UUID in finally. The callback recorder exists only in the marked external diagnostic project /private/tmp/e01-input-repro-20261025; no private-runtime probe is shipped. The resource inventory remains /private/tmp/chapter-find-resources-20261025.md.

## Native acceptance and remaining gates

Both canonical four-method invocations at a100ae199 completed with4 passed,0 failed,0 skipped/expected failures, no60-second animation-wait message and no observer interruption. They used different fresh simulator UUIDs. The declared UI inventory remains24; this is acceptance of the four selected chapter-find-related journeys, not execution of all24 UI methods.

| Journey | software-four-1 | software-four-2 |
| --- | ---: | ---: |
| Main matching, explicit position, rotation/reflow and durable relaunch |74.780s |77.055s |
| Direct landscape, three repeated original Chinese queries, rejected save/retry/chapter retirement |67.447s |67.532s |
| No match/clear, native selection and failure/chapter retirement |59.282s |59.584s |
| Explicit source switch, find retirement and relaunch |49.527s |49.390s |

Artifacts are /private/tmp/e01-20261026-software-four-{1,2}: command.json, commit.txt, scope.json, summary.json, UI.xcresult, tests.log, screenshots/manifest.json and exported PNGs. The separately executed ordinary-product suite in /private/tmp/e01-20261026-product-regression completed94/94 with0 failure/skip at a100ae199. Build-for-testing and test execution both succeeded. ProcessInterruptionTests and ShelfProcessRestartTests were explicitly excluded from this ordinary lane and remain required in the separate published-head C1 process job. Required C1 must be inspected on the actual published head; the prior84 C1 cannot certify this continuation.

Visual QA inspected first-run portrait and direct-landscape keyboard screenshots and the explicit-match synthetic save-rejection screenshot: original Chinese text and count1 are visible before Return; explicit navigation highlights the target original text, and the injected save failure retains that location with Retry available. These are synthetic-host screenshots, not physical-device or live-source acceptance. Examples: screenshots/EAF19241-C76B-45A4-BB21-643DDD79843F.png (first direct input), B0D0076F-8E72-4862-8BB2-AAF97AE67AB5.png (rejected save), CB473DC9-FBD8-442C-A0EC-376A574C8999.png (portrait input).

Independent read-only reviews of84...a100 report Standards0 and Spec0 actionable deviations. They verify that the gesture transport change preserves H1's actual UI criterion and all original literals/failure assertions; no bulk `typeText` API was mandated by that criterion. They did not run the tests, verify C1 or provide H2/merge authorization. The approved acceptance gap is addressed for the actual software-keyboard workflow, while the synthetic/hardware-keyboard limitation remains explicit.

Normal journey: open Find in a loaded chapter, enter text to see count/highlights, then explicitly choose Previous/Next to navigate and save the existing paragraph position. Failure/recovery: a rejected save keeps the selected visible position and exposes the existing Retry flow; chapter/source changes retire the transient query. Query entry/clear alone does not navigate or save. Copy remains the separately approved Issue58 obligation. Owner H2 remains pending until Lei assesses value and maintenance burden; the added test maintenance is the declared Pinyin/Roman accessibility profile, with no new product persistence/upstream adaptation.

## Retained visual evidence

Raw PNGs are copied byte-for-byte from the first four-method run, with source/UUID/SHA256 provenance in [the manifest](2026-10-26-chapter-find/manifest.json). The synthetic host footer is test infrastructure.

- [Direct landscape, original Chinese query and visible Pinyin keyboard](2026-10-26-chapter-find/direct-keyboard.png).
- [After three repeated queries, before any explicit navigation](2026-10-26-chapter-find/direct-query.png).
- [Explicit matched position retained during injected save rejection](2026-10-26-chapter-find/save-rejection.png).
