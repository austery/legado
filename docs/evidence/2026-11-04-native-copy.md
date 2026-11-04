# Native Copy repair

## Scope and final change

Issue: https://github.com/austery/legado/issues/58.
Base: `97f5808c3bd79f773be81f4b51b736135749150f`.
Final executable candidate: `8c33e84b630e6604a48be02376e1aa5615d4b201`.

Lei authorized reproduction, a minimal repair, validation, and final independent
GitHub Copilot Claude Opus 5.5 review. Owner H2 and explicit PR merge approval
remain pending. This record does not claim physical-device acceptance.

The final production diff adds one `layoutManager` read immediately after the
normal `AnchoredTextView()` initializer. This selects TextKit 1 before the first
layout. The original `restoreAnchor()` algorithm, including full-container
`ensureLayout`, remains byte-for-byte unchanged from base. Gestures, saved-offset
formats, engine/storage interfaces and dependencies do not change.

The UIKit SDK header documents that UITextView defaults to TextKit 2 and falls
back to TextKit 1 when `layoutManager` is read. At base this switch occurred inside
anchor restoration during the first layout. Moving it before layout preserves the
base steady-state mode and avoids the observed missing Copy menu on iOS 27.0.
This is evidence for a repair at the reader boundary, not a claim about UIKit's
internal defect or every supported OS version.

## Reproduction and causal correction

The test-only baseline `183b4a4cea4610191b97cbae3423b7d0c5130576` adds an actual-touch
Copy test without changing product code. Its long press selects original text,
but `app.menuItems["Copy"]` is absent. The screenshot shows handles without a menu.
The test fails after 26.769 seconds; xcodebuild returns 65.

| Comparison | Observed result |
| --- | --- |
| Base product, actual long press | Real selection; Copy menu missing. |
| Remove only the controls recognizer, or move its delegate | Copy still missing. Both experiments withdrawn. |
| Plain UITextView, including a TextKit 1 variant | Copy visible and hittable. |
| Standalone ReadingText without surrounding reader screen | Copy missing. |
| Skip restoration or custom layout | Copy appears. Diagnostic only. |
| Restoration primitive: read manager and force full layout | Copy missing; three other primitive controls retain it. This combines a compatibility switch and layout, so it does not isolate the two. |
| Delete full layout, then explicitly select TextKit 1 early | Copy passes, but the new final-paragraph test fails: offset 4801 instead of bottom limit 5389; last caret not fully visible. This candidate is rejected. |
| Restore original product source with the new geometry tests | 95/95 ordinary tests pass. This confirms that deleting full layout introduced the geometry regression. |
| Select TextKit 1 early and retain original full layout | Portrait and both landscape Copy tests pass 3/3. Full UI follow-up passes 4/4. |

The final repair therefore keeps full layout. Earlier records in this branch and
archive that describe deleting `ensureLayout` are superseded by this result.
The final product diff is only early mode selection, not a layout-engine migration.

## Acceptance tests and probes

Four UI methods cover portrait, both landscape pages, and an open chapter-find
panel. They require real long press, a visible and hittable native Copy menu,
an actual tap, a new clipboard write, and exact selected original UTF-16 text.
They compare selection before and after Copy and preserve reader identity,
anchor, viewport and reading-control availability.

The opt-in test-host observer never sets selection, becomes first responder,
invokes Copy, or writes the clipboard. It leaves existing clipboard text unread
until the change count differs from the first sample. The pre-existing host
layout probe reads `layoutManager`; the product now selects the same TextKit mode
before any host tick, so that probe does not change the product configuration.

The UI inventory changes from 24 to 28 methods. Existing failure, skip, count,
and 900-second timeout gates remain unchanged. Ordinary product discovery adds
one method (94 to 95). The new geometry checks require deep-paragraph top alignment
within 2 points, and a fully visible final caret at the bottom scroll boundary.
The tests do not call `ensureLayout` or read `layoutManager` to prepare the result.

## Final validation

- `early-mode-full-layout-copy`: portrait, landscape-left and landscape-right
  pass 3/3, zero failures/skips, with original full layout retained. The source
  manifest matches the final executable candidate.
- `early-mode-final-ui`: 4/4, zero failures/skips; find-panel Copy, main
  find/durable journey, controls/selection across layouts, and two-page
  reflow/durable reopening. Final portrait Copy, find/Copy and reopened spread
  screenshots were inspected. Together the two UI runs cover seven distinct
  methods on the same final executable source.
- `early-mode-native-product`: 95/95, zero failures/skips, at `8c33e84b6`.
  Both deep top alignment and final-paragraph visibility/bottom-limit checks pass.
  This closes the demonstrated geometry regression while retaining working Copy.
- Driver/fixture Python discovery: 62/62. No Python executable change followed
  that run. The UI inventory matches 28 distinct declared/source methods.
- Published-head C1 and its separate interruption/offline-restart suites: pending.
  C1 does not execute the UI lane. No full 28-method UI aggregate is claimed.

## Retained failed and intermediate runs

The archive keeps all failures. Passing reruns do not replace them.

- `copy-candidate`: 3/3 on the first deletion candidate; not final acceptance.
- `ui-regressions`: 5/7, with two failures inside software-keyboard helpers before
  target assertions. `find-copy-isolated` passes those same two methods 2/2 on a
  fresh simulator without assertion changes.
- `textkit1-copy`: an inherited `usingTextLayoutManager: false` factory compiles
  but crashes on first chapter configuration. It is withdrawn; 0/5 is retained
  with its source patch and crash logs.
- `textkit1-early-access`: 4/5 on the early-mode/deleted-layout candidate. The
  find-panel method fails in the Pinyin script-switch helper; it passes alone in
  `textkit1-find-copy`. Supplemental diagnostics were stopped only after all five
  tests finished. The failed result bundle remains valid and is not a green run.
- `textkit1-native-product`: 94/94 before the stronger geometry test existed.
- `final-controls-paging`: 2/2 on that intermediate candidate; screenshots checked.
- `final-native-product`: 94/95 after adding geometry coverage; end restoration
  fails. `geometry-original-baseline` passes 95/95 with original product source.

Keyboard-input intermittency remains unexplained. Hidden failure/cancel,
landscape find/rejected-save and no-match/failure/retirement were exercised only
on the initial repair, not rerun on the final candidate. These limits are separate
from the final named journeys and from published-head CI.

## Independent review

GitHub Copilot Claude Opus 5.5 reviewed `08af92ccb` and requested changes because
product and test host selected different text systems. The report is retained
as `copilot-final-review.md`. Early mode selection and the runtime mode assertion
address that gap. Causal wording, post-Copy selection comparison and clipboard
observation were also corrected.

The second report, `copilot-corrected-review.md`, approves code at `89a500c6a` but
asks for stronger geometry evidence. Implementing that suggestion reveals the
real regression above. That approval does not certify the final candidate.
Final independent review on the final fixed head remains pending.

## Provenance, recovery and limits

Execution root: `/private/tmp/legado-copy-20261104-evidence`.
Retained archive: `/Users/leipeng/Documents/Codex/legado-issue-58-20261104`.
Completed logs, commands, source manifests/patches, `.xcresult` bundles and
screenshots are hash-verified against the archive. Reproducible DerivedData is
excluded from the evidence copy; build diagnostics are retained separately.

ARM64 Mac, Xcode 27.1 build 27A9275, iOS 27.0, invocation-owned M4 iPad simulators.
ReaderEngine was rebuilt from the task source with the project wrapper and JDK
21/17. Framework SHA256:
`456003c81586f754f7965f3838053e242a6ab3a1fe6a860cb7f26d288ddffe4a`.
The primary checkout's older framework was not used.

[Baseline selection without Copy](native-copy-20261104/before-missing-menu.png).
[Native Copy with chapter find open](native-copy-20261104/after-find-copy.png).
Images show synthetic simulator UI. Clipboard correctness comes from executed
assertions, not screenshots alone.

Recovery is a normal commit restoring `ReadingText.swift` from the base revision,
or reverting the complete final squash. Do not selectively revert intermediate
experimental commits. Base restoration requires no data migration and restores
the known Copy failure. The affected subsystem is native reader layout/selection;
existing storage and engine contracts remain unchanged.

Physical iPad comfort, other OS versions, live sources, hardware-keyboard input,
owner H2 and explicit merge approval remain unverified or pending.
