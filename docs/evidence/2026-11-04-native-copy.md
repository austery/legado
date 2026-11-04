# Native Copy repair

## Scope and authorization

Issue: https://github.com/austery/legado/issues/58.
Base: `97f5808c3bd79f773be81f4b51b736135749150f`.
Test-only baseline: `183b4a4cea4610191b97cbae3423b7d0c5130576`.
Initial repair source: `551569f7fc26eaa4cb9099f071c3d4ab67033bc4`.
First review snapshot: `08af92ccb37a607394cd66ed3a2c90ec19b22247`.

Lei requested reproduction, a minimal repair, validation, and final independent
GitHub Copilot Claude Opus 5.5 review. Owner H2 and explicit PR merge approval
remain pending. This record does not claim physical-device acceptance.

## Failure and causal comparison

The canonical UI driver reproduced the missing native Copy menu on the test-only
baseline. A real long press produced a nonempty original-text selection, but
`app.menuItems["Copy"]` was absent. The screenshot shows selection handles without
an edit menu. The test failed after 26.769 seconds; xcodebuild returned 65 after
supplemental system diagnostics.

Single-variable experiments retained their source patches and result bundles:

| Comparison | Actual native Copy menu |
| --- | --- |
| Baseline reader | Missing |
| Remove only the controls tap recognizer | Missing |
| Move its delegate to a separate object | Missing |
| Plain selectable UITextView | Visible and hittable |
| Plain UITextView after TextKit 1 access | Visible and hittable |
| Standalone ReadingText, without the surrounding reader screen | Missing |
| Suppress repeated pan-enabled writes or omit the text delegate | Missing |
| Skip custom layout, or skip anchor restoration | Visible and hittable |
| Skip equal content-offset writes | Missing |
| Replace only the caret query with an equivalent initial rectangle | Missing |

A four-case restoration experiment then ran one primitive per fresh view.
Clearing the restoration flag, resolving the initial text position, and setting
zero content offset each preserved the menu. Reading `layoutManager` and calling `ensureLayout(for: textContainer)` during
restoration suppressed it. That experiment combines a TextKit compatibility
switch with whole-container layout; it does not isolate those two effects. Trace output
places that call in initial restoration, before the user's selection. This does
not support a claim that repeated scrolling during selection caused the failure.

The repair removes that restoration-time call and explicitly creates the reader
with TextKit 1 by accessing `layoutManager` immediately after its normal
initializer, before any layout or restoration. This preserves the base text
system mode without relying on a later compatibility switch. The existing
`position(from:offset:)`, `caretRect(for:)`, bounds clamp, content-offset update,
and restoration callback remain. The observed causal claim is limited to
Xcode 27.1 / iOS 27.0; it does not identify an internal UIKit defect.

## Test contract

Four named UI tests cover portrait, both landscape pages, and the open chapter-find
panel. They use actual long press, require a visible and hittable native Copy menu,
and tap it. A test-host observer reads selection and clipboard state. It never
sets selection, becomes first responder, invokes Copy, or writes the clipboard.
The observer leaves pre-existing clipboard text unread until its count changes.
The clipboard change count must increase, and its UTF-16 text must exactly equal
the selected original chapter text. Book/source/chapter identity, anchor, viewport,
native selection after Copy, and reading-control availability must remain intact.

The driver inventory changes from 24 to 28 methods. Existing failure, skip, count,
and 900-second timeout gates remain intact. Temporary diagnostic experiments
suppressed supplemental system collection only; the final driver restores its
original collection policy. No dependency, engine interface, or persisted format
changes.

## Executed evidence

Evidence root during execution: `/private/tmp/legado-copy-20261104-evidence`.
Retained archive: `/Users/leipeng/Documents/Codex/legado-issue-58-20261104`.
Completed run files are hash-verified against that archive; reproducible
DerivedData is excluded.
Each run records its command, simulator UUID, log, and available `.xcresult` and
screenshots. `final-source-manifest.json` records source hashes and the relationship
between pre-commit runs and the committed repair. The later source edit only
clarifies the comment; executable production code remains identical.

- `portrait-baseline`: reproduced failure described above.
- `restoration-primitives`: three controls show the menu; whole-container layout
  suppresses it. The aggregate intentionally fails and is diagnostic evidence only.
- `copy-candidate`: portrait, landscape-left, and landscape-right Copy tests pass
  3/3 with zero failures or skips. All three menu screenshots were inspected.
  Production and observer sources equal the repair commit. This run preceded
  adding the fourth, find-panel test.
- C1 scope/gate Python tests: 19/19 pass. Full driver/fixture Python discovery
  also passes 62/62. The UI inventory matches 28 distinct source methods.
- `ui-regressions`: 5/7 pass, 2 fail, zero skips. Controls/selection, hidden
  failure/cancel actions, two-page turns/reflow/durable recovery, landscape find
  with rejected save, and no-match/failure/retirement pass. The main find journey
  fails to switch back from numeric keys; the new find/Copy journey fails to
  switch from Roman to Pinyin. Both fail before their target assertions.
- `find-copy-isolated`: a new simulator runs those same two methods unchanged;
  2/2 pass with zero failures or skips. The find-panel Copy menu screenshot was
  inspected. Retain the first failures as keyboard-input intermittency; this
  does not establish their internal cause or a completely green seven-test run.
- `native-product`: canonical ordinary-product driver passes 94/94, zero failures
  or skips. This includes real UIKit restoration, Unicode/delimiter boundaries,
  pagination/reflow, and reading/save journeys. The process-interruption and
  offline-restart external suites are not run in this local lane; published-head
  C1 must run them separately.

The engine framework was rebuilt from this task checkout using the project wrapper,
JDK 21/17, Android SDK, Xcode 27.1, and iOS 27.0 ARM64 simulator target. Binary SHA256:
`456003c81586f754f7965f3838053e242a6ab3a1fe6a860cb7f26d288ddffe4a`.
The primary checkout's older framework was not used.

## First independent review and response

GitHub Copilot Claude Opus 5.5 reviewed `97f5808c...08af92ccb` read-only and
requested changes. The report is retained as `copilot-final-review.md` in the
archive. It found that the old host's layout probe forces TextKit 1, while the
initial repair left the production view on TextKit 2. The initial passing UI
results therefore did not cover the production text-system configuration.

| Item | Evidence and decision | Action |
| --- | --- | --- |
| F1: product/host text-system mismatch | Accepted. The deleted access was the product's compatibility switch; the host still reads `layoutManager`. | Explicitly select TextKit 1 before layout, preserving the base mode. Add a mode assertion to the real restoration test. Rerun four Copy tests and ordinary product tests. |
| F2: TextKit 2 end-of-chapter geometry | Conditional on adopting TextKit 2. That migration is outside this repair. | Keep TextKit 1; retain existing geometry/restoration coverage. |
| F3: combined-variable causal wording | Accepted. Reading the manager and forcing layout were combined. | Narrow the comment and diagnosis wording. |
| F4: selection after Copy | Accepted. The issue asks for before/after selection comparison. | Assert exact selected ranges/text after Copy. |
| F5: pre-existing clipboard content | Accepted as bounded observer hardening. | Read clipboard text only after its count differs from the initial sample. |

The reviewer found no fabricated Copy action or weakened execution gate. It did
not treat the two keyboard-input failures as a blocker for this scoped repair.
The proposed inherited `usingTextLayoutManager: false` factory compiled but the
fixture app crashed on first chapter configuration. Its source patch, crash logs,
and failed result are retained in `textkit1-copy`; no acceptance is claimed.
The candidate instead retains the normal Swift subclass initializer, then reads
`layoutManager` before layout. The SDK documents this compatibility switch.
Corrected source: `4cd2377b8ef6d5ce537b2692f5c9de7d21599071`.

- `textkit1-early-access`: three Copy methods and the main find/durable-position
  journey pass. The find-panel Copy method fails before input at the same Pinyin
  script-switch helper. Result: 4 passed, 1 failed, 0 skipped. All five tests had
  finished before supplemental system diagnostics were stopped; the valid result
  bundle retains the failure and is not reported as a passing aggregate.
- `textkit1-find-copy`: the unchanged find-panel Copy method passes alone on a
  new simulator: 1 passed, 0 failed, 0 skipped. All four corrected Copy menu
  screenshots were inspected. The retained after image comes from this run.
- `textkit1-native-product`: 94/94 ordinary tests pass with zero failures or
  skips, including the new production TextKit 1 assertion and all restoration,
  pagination, find, and save tests. Process suites remain for published-head C1.
- The next commit updates only this record and the retained screenshot; executable
  sources remain identical to `4cd2377b8`. Final independent re-review is pending.

## Retained screenshots

[Baseline selection without Copy](native-copy-20261104/before-missing-menu.png).
[Repaired native Copy with chapter find open](native-copy-20261104/after-find-copy.png).
These images show synthetic simulator UI. Clipboard correctness comes from the
executed assertion and observations, not the image alone.

## Recovery and remaining acceptance

The changed production consumer is the scroll-layout anchor restoration inside
ReadingText. Its effect stays within native reader layout and text selection;
related consumers include chapter find, typography/reflow, and resumed reading.
Existing saved paragraph offsets and engine/storage contracts remain unchanged.
Reverting both production commits (`551569f7f` and `4cd2377b8`) together restores
prior layout behavior without a data
migration; it also restores the observed Copy failure.

Final Copilot review, published-head C1, owner H2, and merge remain pending.
Synthetic simulator results do not establish physical iPad comfort, other OS
versions, live-source behavior, or hardware-keyboard input.
