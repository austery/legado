# In-chapter find implementation evidence (in progress)

Issue57; approved SPEC-009. Basebcf99c6e193e954a586f8d0f8e094c6c25d9bf9d. User explicitly withheld merge. No PR publication or complete feature acceptance is claimed here.

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

9268b1c15 adds a separate landscape save-rejection/retry/chapter-retirement UI journey. It shares the unchanged failure-path assertions with the original Copy-gated journey; that original Copy assertion remains intact. The declared UI inventory increases23 to24 and the selected-count validator remains strict. This adds independent failure-path coverage without weakening or waiving native Copy. Its two-method execution is in progress at/private/tmp/chapter-find-ui-final-independent; no terminal result is claimed yet.

Independent review refreshed at81416a52f: Standards reports0 remaining code findings (manual spread-turn P2 fixed); Spec reports0 code deviations and retains the native Copy acceptance gap. Owner H3 decision, current full regression, exact-head C1, PR publication and H2 remain pending. No merge is authorized.
