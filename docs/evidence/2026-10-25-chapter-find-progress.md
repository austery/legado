# In-chapter find implementation evidence

Issue57; approved SPEC-009. Current UI source a100ae199: actual software-keyboard chapter-find acceptance passed4/4 twice on fresh simulators, including three direct-landscape Chinese queries each. See the [2026-10-26 continuation](2026-10-26-chapter-find-software-keyboard.md) for source-bound results, input-profile prerequisites and the retained synthetic/hardware-keyboard limitation. Product/required CI evidence remains separate and revision-bound. Owner H2 and explicit no-merge hold remain; historical results below retain their recorded sources.

## Executed feedback loops

- Entry:7a158057d actual UI failed on missing reader.find;2692b9775 selected UI1/1 passed.
- Literal matching:5e58a06f0 real XCTest failed on absent expected original UTF-16 ranges; e9a057aac selected matching1/1 passed. Navigation3246aa4e2 failed on absent selection;2656ed3cb both state tests2/2 passed.
- Off-screen navigation:3888eaafe actual UI found/selected one result but anchor remained0. First implementation1ff7357e2 did not compile because AppKit-only temporary-attribute APIs are unavailable in UIKit. Corrected4f362d2a1 selected main UI journey1/1 passed (typing/no save, explicit position, both layouts, style, close, source-network count equality, reopen/relaunch).
- Reflow:c53c14013 hosted UIKit failed on lost highlights and passive-anchor drift. e1e3624c5 fixed portrait styling/anchor;93924ac20 seeded first spread highlights, hosted tests3/3 passed. Later public stale-context and cross-page-boundary tests brought focused count to5, all passed.
- Independent Standards review at9f135bf23 found P2 stale reveal after manual spread turn; Spec axis reported0 findings. f28059252 real UIKit tracer reproduced old-hit reflow after a newer accepted page turn.5e9e8bcaf clears temporary reveal in the accepted spread-turn path; all6 focused state/real UIKit tests passed, zero failures/skips. Actual UI main journey was extended with the same interleaving; final rerun pending.
- Python orchestration/fixture suite62 passed, including a negative observer check proving real HTTP requests are counted, observation itself is excluded and namespaces are isolated.
- Three-method actual UI run9f135bf23: main find/relaunch and explicit source switching passed; the combined no-match/native-Copy/failure/retirement journey failed at the Copy-menu assertion. This failed aggregate remains failed; later tail assertions were not reached.
- Full ordinary Swift product suite at1bc52d264:93/93 passed, zero failures/skips, output/private/tmp/chapter-find-product-regression. This excludes actual UI and external interruption/restart lanes and is not a waiver of Copy.

## Native Copy investigation and H3 decision pending

The failing actual UI loop observes a genuine native selection, but no visible Copy menu. Repeating a normal tap on the selected text did not restore it. Removing sustained SwiftUI FocusState binding also did not restore it, so that production experiment was reverted. Temporary test-host observation reports firstResponder=true,canCopy=true,selectedLength=2. The correct lower-level cause remains unknown; no product/OS attribution is inferred from those flags.

A separate pre-feature archive atbcf99c6 was created with all10 production Swift source files byte-checked against git objects. Only a minimal UI copy probe, read-only test-host observer and its declared inventory differed; the same unchanged engine framework/toolchain/runtime was used. That baseline probe also failed to expose Copy, with the same first-responder/copy capability and native selection. Output/private/tmp/chapter-find-copy-baseline-result retains exact baseline, source hashes, modified probe sources, logs, xcresult, summary and screenshots. The source archive and generated build were reclaimed after no consumers and hash-verified export. Thus the Copy symptom predates this feature; whether its cause is the baseline native integration, touch/menu interaction or simulator remains unresolved.

The owner has been asked under H3 whether to keep this feature's scope and track native Copy separately, or explicitly expand this task to repair it. No automatic acceptance waiver, skipped Copy assertion or changed timeout/count gate has been applied. Main implementation and unrelated validation continue; whole H1 acceptance and publication remain pending that decision. Temporary [DEBUG-find-copy] observers were removed at10aa4b2e7; none remain in product/test sources.

## Unchanged boundaries

No engine/KMP/export/schema/dependency/format change. Find uses loaded text and original UTF-16 ranges, preserves native selection and the paragraph-save coordinator. Actual UI uses isolated synthetic sources and invocation-owned simulators; no physical-device/live-source/distribution acceptance is claimed. Owner H2 and explicit merge approval remain pending; merge is withheld.

Resources: /private/tmp/chapter-find-resources-20261025.md. Managed chapter-find workspace retained for the active task. Completed DerivedData directories have been reclaimed with external logs/xcresults/source commands kept; current incremental UI/unit build paths and active UI regression output are protected.

## Latest selected UI regression and handoff

At immutable source1bc52d264, the selected main find/manual-page/reflow/relaunch journey, hidden-controls failure/cancel journey and existing native selection/control journey all passed3/3, zero failures/skips. Output/private/tmp/chapter-find-ui-regressions retains scope, command, commit, summary, xcresult and screenshots. Together with the earlier explicit source-switch pass, four distinct UI methods have passing evidence across the documented runs; the earlier3-method Copy-failing aggregate remains failed, and the combined failed method's later save-failure/chapter assertions remain unexecuted.

Representative unedited images and hashes are in2026-10-25-chapter-find/manifest.json. These bind the executed source, not an invented physical-device/owner acceptance. Only the temporary test-host responder observer is removed after this run; production source is unchanged. The inactive baseline archive has been reclaimed after exporting probe sources/hashes and results. H3 decision remains pending; no complete H1/ready PR/merge claim.


## Exact body identity and independent failure-path coverage

At3c1b1aeab a public state/real UIKit test reproduced the distinction between Swift canonical string equality and original UTF-16 identity (precomposed versus decomposed characters).81416a52f now retires stale result coordinates and replaces rendered text whenever the original UTF-16 body differs. All7 focused ChapterFindTests passed with zero failures/skips in/private/tmp/chapter-find-unicode-context-green. The earlier93-test product result predates this fix and is not presented as current-head full regression.

9268b1c15 adds a separate landscape save-rejection/retry/chapter-retirement UI journey. It shares the unchanged failure-path assertions with the original Copy-gated journey; that original Copy assertion remains intact. The declared UI inventory increases23 to24 and the selected-count validator remains strict. This adds independent failure-path coverage without weakening or waiving native Copy. The two-method run at/private/tmp/chapter-find-ui-final-independent timed out at the unchanged900-second driver deadline. The main journey passed66.401s; the landscape journey executed save rejection, retry, position preservation, chapter retirement and empty reopened state assertions, but repeatedly waited60 seconds for an animation-complete notification and never finished its closing/teardown step. The aggregate is NOT passing acceptance; intermediate assertions do not replace a terminal result. A read-only live simulator screenshot and the full log/result bundle are retained. The lower-level animation/idleness cause remains unknown, and no timeout was increased or assertion removed.

Independent review refreshed at81416a52f: Standards reports0 remaining code findings (manual spread-turn P2 fixed); Spec reports0 code deviations and retains the native Copy acceptance gap. Owner H3 decision, current full regression, exact-head C1, PR publication and H2 remain pending. No merge is authorized.

Review refresh through9268b1c15 (docs8e0a6e451): Standards0 new findings; Spec0 code deviations and the same Copy acceptance gap. Both independently confirmed the added journey preserves original assertions and strict inventory/count gates. Canonical ordinary product regression at8e0a6e451 (production source81416a52f, latest UI tests9268b1c15) completed94/94 passed, zero failures/skips, at/private/tmp/chapter-find-product-final. The current-code run began only after the UI driver exited and released its exclusive fixtures. External process-interruption/restart suites are excluded by the declared ordinary lane. Exact-head C1 and whole actual-UI acceptance remain pending.

The timed-out UI bundle lacks Info.plist; xcresulttool cannot read or export its attachments. It is retained as an incomplete diagnostic artifact, not a valid result summary. The plain test log and independently captured live-landscape-diagnostic.png remain available; do not claim a complete screenshot export or terminal landscape pass.


## Owner H3 decision and continuation

Lei's2026-10-25 answer explicitly keeps this scope and follows up Copy separately. Issue58 preserves baseline reproduction, failed touch-menu evidence and future actual clipboard acceptance. The feature journey now asserts real native selection and retains no-match/clear, save rejection/retry and chapter retirement; it no longer certifies the deferred touch Copy menu. This is an owner-approved acceptance amendment, not an inferred waiver. The previous failed Copy runs remain failed.

The independent landscape timeout is investigated by changing only input order: enter the query in portrait, then rotate into landscape before the unchanged save-rejection/retry/chapter assertions. Main previously passed this input/rotation order. Candidate hypotheses are a landscape keyboard animation, panel layout animation, or simulator idleness reporting; no lower-level cause is claimed. The driver deadline and result/count gates remain unchanged.


## Canonical amended-scope acceptance

Source388731d1294ee6d74aeb8a69fd0b1274568496b4, canonical scripts/path-c/reader_ui_ci.py, Xcode27.1/iOS27.0 owned iPad Pro11(M4), output/private/tmp/chapter-find-ui-approved-scope:4/4 passed, zero failures/skips. Executed methods: testChapterFindAcrossLayoutsAndDurablePosition70.119s; testChapterFindLandscapeRejectedSaveAndChapterRetirement24.694s; testChapterFindNoMatchesSelectionFailureAndChapterRetirement32.471s; testExplicitSourceSwitchAndRelaunch (exact timing in retained test log). This covers offscreen match/count/no typing-save, explicit next/previous, both layouts, typography/manual-page interleaving, accepted paragraph relaunch, real native selection, no-match/clear, rejected save/retry, chapter/source retirement and no find-triggered network requests. Raw screenshots were visually inspected and hash-copied into the adjacent evidence directory; manifest binds source and attachments. This is synthetic simulator evidence, not owner H2, physical-device comfort or Copy certification.

Changing only query input order (portrait input then rotation) allowed the independent landscape journey to finish24.694s without changing its assertions or900-second driver deadline. This narrows the prior idleness symptom to the interaction sequence but does not establish its lower-level cause. The earlier timed-out aggregate remains failed. No product workaround or timeout relaxation was added.

The first lightweight62-test run accidentally overlapped the actual UI listener; test_occupied_reading_port_is_not_reused_or_terminated failed to bind its deliberately occupied-port fixture with EADDRINUSE. It did not terminate/reuse the running UI listener. Its failed log is retained/private/tmp/chapter-find-python-final.log. After canonical UI teardown, the identical command ran sequentially:62/62 passed in9.254s, log/private/tmp/chapter-find-python-serial.log. No source/test changes were made to obtain that rerun.

Review source388731d12: Standards0 code/validator findings, Spec0 deviations under the explicit H3 amendment. The Standards P3 stale current-status document was fixed and independently rechecked at88935f85f. Production remains81416a52f, covered by the94/94 ordinary-product run at8e0a6e451. No engine/KMP/persistence/schema/dependency change. Exact-head C1 will run on the published task revision; subsequent CI/PR records belong to Issue57 and the exact commit check suite. No merge is authorized; owner H2 remains pending.


## External review E01 — direct landscape input reopened

PR59 review-v1 at84c23a8c0 correctly distinguishes a successful portrait-input-then-rotation journey from the earlier timed-out direct-landscape-input sequence. Disposition: accept the evidence gap; no confirmed code defect or speculative production repair. Review source: https://github.com/austery/legado/pull/59#issuecomment-6405269726. Copy remains Issue58; H2 and explicit no-merge hold remain.

Restore the existing landscape recovery test to rotate before opening Find and typing. Run it after the existing main find journey, matching the previous failed two-method sequence, with the same literal query, real save rejection/retry/chapter retirement assertions, strict selected count and900-second driver deadline. No driver/fixture gate or production code change. A fresh run must finish before any claim that E01 is closed; old4/4 and C1 evidence certify their recorded revisions/orders only.


## E01 reproduction and bounded diagnostic outcome — still open

Local source5ed53621d89c767aecb020be7b29db3b5ed7314f restores landscape rotation BEFORE opening Find and typing. No production/driver/fixture/assertion/deadline change. This local test/evidence continuation is not pushed; remote PR remains84c23a8c0 with its own completed C1, and PR59 has returned to DRAFT under the existing no-merge hold.

| Execution | Exact provenance | Result / limit |
| --- | --- | --- |
| chapter-find-direct-landscape-review | Clean5ed; canonical main then direct-landscape |2/2 passed,0 failure/skip;66.934s and25.201s. |
| chapter-find-direct-landscape-confirm | Clean5ed at launch; canonical4-method confirmation | Main72.684s passed; direct-landscape recurred repeated60s animation waits and hit unchanged900s deadline. Remaining methods were not reached. After recurrence, the exact app was sampled and briefly debugger-inspected/detached; this instrumented run is diagnostic, not a new accepted aggregate. |
| chapter-find-panel-only-diagnostic |5ed plus saved panel-diagnostic patch SHA in diagnostic-provenance.json; temporary existing-host route, same real Find panel, no reader body/engine preparation/timer |1/1 passed14.784s; not full reader acceptance. |
| chapter-find-panel-after-reader-diagnostic | Same saved dirty patch, main reader then panel-only contrast |2/2 passed64.699s/12.507s; not a production fix or E01 closure. |
| chapter-find-hidden-layout-diagnostic |5ed plus saved hidden-layout patch SHA; only skips observing the occluded portrait layout in spread mode |2/2 passed66.696s/25.021s. Causality NOT established. |
| chapter-find-original-observer-control | Restored clean5ed; original observer and same main/direct sequence |2/2 passed68.412s/24.319s. The diagnostic monitor did not interrupt (record says false, driver exit0). This reverse control prevents attributing a fix to the experimental observer change. |

All outputs above are /private/tmp/<execution-name>, with commands, source/patch provenance, logs and available xcresults/screenshots. The900s timeout result is not converted to a passing aggregate. Public UIKit/Core Animation read-only debugger expressions, detach log and a3-second sample are preserved in direct-landscape-confirm. At the sampled moment the app main thread was predominantly waiting in its run loop and no app-window layer animation keys were found. These momentary observations neither establish an OS/XCTest defect nor rule out every reader/UI interaction. The prior PosterBoard boot crash is a separate process/time signature and is not asserted to cause E01.

All temporary panel scenes, extra diagnostic method/inventory and observation changes were exported with SHA provenance and restored byte-for-byte. No speculative production or test-host fix is retained. The original direct-input test remains in local5ed so future work cannot substitute portrait input then rotation. E01 remains OPEN: successful terminal direct-order evidence now exists, but the intermittent idleness recurrence remains unexplained. No unrestricted landscape or performance claim, acceptance waiver, timer/count relaxation, Copy certification or owner H2/merge approval follows from these runs. Independent narrow reviews of5ed found0 Standards and0 Spec code deviations; their initial2/2 inspection does not certify the later failed confirmation. Remote C1 success is only84c23a8c0, not this unpublished continuation.


## E01 continuation — keyboard synchronization mechanism located

User resumed diagnosis without merge authorization. The [callback-pair report](2026-10-25-chapter-find-e01-keyboard.md) records the independent and actual-reader reproductions: one already-deallocated keyboard animation state lacks one stop callback, exactly matching XCTest active-animation count1 and repeated60-second waits. Both creation stacks originate in hardware-keyboard availability changes and keyboard minimization. The reader recurrence occurs on the original first direct-landscape query, before added diagnostic repetitions. Earlier pristine portrait recurrence means this signature is not landscape-exclusive.

This is a confirmed synchronization failure mechanism, not proof of the internal cancellation cause or an accepted repair. Material/focus controls reverse cleanly, so no speculative production change is retained. All native temporary recorder/host/test/config edits were hash-exported and restored to local2f4a. See the diagnostic report for exact source hashes, interrupted-run limits, keyboard-dismissal controls and remaining acceptance gap. Remote PR59 remains draft84c23a8c0; this local continuation has no new-head C1 and supplies no H2 or merge approval.

Restored-source final check at/private/tmp/e01-native-clean-restored-final-1 rebuilt clean2f reader/test sources with recorder symbols absent: main68.191s passed, original direct-landscape input again waited repeatedly and showed XCTest active-animation count2. Intentionally stopped after the second wait; no2/2 acceptance is claimed. All24 owned invocation UUIDs are absent after teardown. Local documentation checks19/19 and changed links/fences/whitespace passed; no new runtime-C1, H2, push or merge claim.

## 2026-10-26 — software-keyboard direct-input evidence

The [software-keyboard continuation](2026-10-26-chapter-find-software-keyboard.md) records two fresh canonical four-method passes at a100ae199, with original Chinese/Latin queries, visible Return, three direct-landscape repetitions and every failure/recovery assertion retained. No60-second wait occurred, neither run was observed/interrupted, and the strict four-selected count/no-skip gate passed. Isolated paired diagnostics found0 hardware-availability animation states for actual Pinyin input versus24 for original bulk injection across12 queries each. This addresses the real software-keyboard acceptance gap, not UIKit's internal callback defect or hardware-keyboard certification.

Unproven sizing/keyboard-overlay changes were restored; production sources are identical84. Current input helpers use only actual controls; no fixture, driver, deadline, count gate, clipboard or finder-state backdoor was introduced. Pinyin/Roman profile prerequisites and0/0 independent code review findings are explicit in the continuation. Local ordinary-product verification completed94/94 without failures/skips at a100ae199; the separate process suites and required aggregate remain published-head C1 gates. Copy58, owner H2 and no-merge hold57 remain.
