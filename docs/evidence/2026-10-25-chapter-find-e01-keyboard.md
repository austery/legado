# E01: keyboard animation callback imbalance

Historical diagnostic snapshot. The [2026-10-26 continuation](2026-10-26-chapter-find-software-keyboard.md) supersedes execution/acceptance status; the mechanism and failed experiments below remain preserved evidence.

Date: 2026-10-25 (America/Toronto). Investigation baseline: local2f4a1630f55d06eafc58f2d74332e8505d8e1689; remote PR59 remains draft at84c23a8c0d4befd52434def9a765d64593fd0006. No production repair, E01 acceptance waiver, owner H2 or merge approval follows from this report.

## Confirmed mechanism

The repeated60-second message is XCTest waiting for its active-animation counter to return to zero. Two callback-traced reproductions identify the outstanding state as a UIKit **keyboard-minimization animation created by a hardware-keyboard-availability notification**. The animation state was already deallocated with one more `animationDidStart:` than `animationDidStop:finished:` callback. The exact runtime's32-bit `XCTActiveAnimationsCount` remained1 before and after inspection.

| Reproduction | Callback observation | Source / symptom |
| --- | --- | --- |
| e01-standalone-animation-pairs-2 | Total11854 starts /11853 stops; sole unbalanced, deallocated state195/194; duration0.3833s, last key `position` | Copied production Find panel plus plain UITextView, no highlighting/ReaderEngine/network/storage. Failed on iteration21 after a separate36-cycle clean run of the same source. App-window layers had no animation keys at inspection. |
| e01-native-animation-pairs-repeat-1 | Total863 starts /862 stops; sole unbalanced, deallocated state223/222; duration0.3833s, last key `bounds.size` | Actual reader, original main journey passed67.300s. The original first direct-landscape query then stalled at13.67s, with waits at73.70s and137.12s. The additional diagnostic loop had not begun when the imbalance arose. |

Both creation stacks contain this chain (caller to animation):

```text
UIDevice _hardwareKeyboardAvailabilityChanged
UIKeyboardImpl hardwareKeyboardAvailabilityChanged
_UIKeyboardStateManager setInHardwareKeyboardMode:forceRebuild:shouldMoveKeyboard:
UIKeyboardImpl hideKeyboardWithoutPreflightChecks
UIKeyboardSceneDelegate minimize
UITrackingElementWindowController moveFromPlacement:toPlacement:starting:completion:
UIInputViewAnimationStyle launchAnimation:afterStarted:completion:forHost:fromCurrentPosition:
UIViewAnimationState pushViewAnimationState:options:context:
```

The native64-frame stack reaches a notification dispatched through the normal main run loop, rather than a reader match/highlight/storage operation. The standalone result establishes that ReaderEngine, paragraph persistence, spread layout and match highlighting are unnecessary for this signature. A pristine earlier four-method reader run also reproduced the60-second wait during portrait query input, before rotation; the symptom is therefore not exclusive to landscape.

This locates the failed synchronization mechanism in the simulator keyboard-animation / XCTest boundary. It does **not** prove which internal UIKit/Core Animation cancellation caused the missing callback, establish behavior on another runtime or physical iPad, or establish that every app-level focus interaction is irrelevant. A momentary empty layer-key scan alone was insufficient; the paired callbacks and dead-state record supply the stronger evidence.

## Probe validity and limitations

Environment: ARM64 Mac; Xcode27.1 build27A9275, available iOS27.0 simulator build24A434, fresh invocation-owned iPad Pro11-inch M4 devices. No runtime installation or global keyboard configuration change.

Only the standalone project and temporary `UITestHost` contained the callback recorder. It recorded raw addresses, counts and creation backtraces without retaining animation states, called each original callback once, and did not modify XCTest counters, disable animation, change reader deadlines or bypass idle detection. Snapshots confirmed the forwarded original callbacks belonged to the loaded runtime's `XCTAnimationDidStart` / `XCTAnimationDidStop`. Pre-stall tracing can alter timing, so passing traced runs are not product acceptance; the observed recurrence remains useful diagnostic evidence.

Each stalled run was intentionally interrupted after the second observed60-second wait, after the snapshot had detached. Interrupted runs are not green aggregates. The canonical900-second deadline and strict selected/executed-count validators were not weakened. The native diagnostic variant added36 repeated inputs after the original query; failure arose before those repetitions. Its original matching/save-rejection/chapter-retirement assertions remained, but later steps were not reached in that failed invocation.

Native tracked files and temporary added recorder files were exported with hashes, then restored/removed. `/private/tmp/e01-native-pairs-source/restored.json` verifies original files match local2f Git objects byte-for-byte. No private-runtime hook is delivered in the reader.

## Controls that did not establish a fix

- Plain basic field12 cycles passed; adding the original ReadingText reproduced on cycle2, and a plain legacy UITextView reproduced on cycle7. These were native-host diagnostic scenes, not product acceptance.
- Copied real panel without highlighting reproduced on cycle2. Replacing material background with a solid background passed12; restoring the original material also passed12. A material change is not established as a repair.
- Original callback-traced panel passed36 then failed on iteration21 of the next identical run. A single green repetition is insufficient.
- Removing explicit `editing = false` in the standalone panel's Return handler passed36, then another36 with a per-cycle assertion that Return dismissed the keyboard. Restoring the original handler with the same keyboard assertion also passed36. Thus neither a missing keyboard dismissal nor this focus change is established as the cause/repair; no speculative handler change is retained.

## Reproduction and retained evidence

All run directories below are `/private/tmp/<name>`. They contain exact commands, source hashes, simulator UUID/runtime, logs, available xcresults, observer scripts and diagnostic interruption records. They are local retained diagnostics, not portable CI attachments.

- `e01-standalone-animation-pairs-1`, `e01-standalone-animation-pairs-2`.
- `e01-native-animation-pairs-1`: unchanged two original test methods with host recorder,2/2 terminal pass.
- `e01-native-animation-pairs-repeat-1`: actual-reader recurrence and full64-frame creation stack.
- `e01-standalone-no-submit-1`: focus-dismissal contrast,36 cycles terminal pass.
- `e01-standalone-no-submit-keyboard-1` and `e01-standalone-submit-reverse-keyboard-1`:36 cycles each terminal pass, including keyboard-dismissal assertions, so the reverse control did not establish a fix.
- `chapter-find-e01-tracker-four-1`: pristine portrait recurrence; a later broad symbol query itself timed out, so post-observer outcomes are diagnostic only.

The standalone source and revision recipes are in `/private/tmp/e01-input-repro-20261025`; the temporary native recorder and hashes are in `/private/tmp/e01-native-pairs-source`. Run-scoped simulators are deleted by their owning drivers' finally blocks. The resource inventory remains `/private/tmp/chapter-find-resources-20261025.md`.

No94-product-test or new-head C1 run is claimed in this diagnostic continuation. Previously retained results remain tied to their own revisions. Copy remains separately tracked in Issue58. PR59 stays draft/unmerged; a reliable direct-input acceptance path and owner H2 remain outstanding.

## Restored-source final check

`e01-native-clean-restored-final-1` rebuilt the restored original reader and two original UI methods at local2f4a with no pre-stall recorder or diagnostic repetitions. Main passed68.191s; direct-landscape input again entered an idleness wait at13.26s, with notifications at73.29s and134.47s. After the first wait, read-only inspection showed `XCTActiveAnimationsCount=2` before and after detach. This untraced run cannot identify its individual orphan states, so it supports recurrence/positive synchronization count rather than independently proving the same exact per-state callback history. The run was intentionally interrupted after the second observed wait; there is no passing2/2 aggregate.

The rebuilt fixture debug binary contains none of the temporary recorder symbols; source diff for native-ios-app/scripts/engine-ios against2f4a is empty. Verification is retained in `/private/tmp/e01-clean-binary-verification.json`. All24 invocation-owned UUIDs found in this continuation's run manifests are absent from the final simulator inventory; no diagnostic orchestrator remains. Unique source recipes/logs/results and useful task-private incremental builds are retained while E01 is open. Eight generated Python bytecode files were removed only after source recovery and no-open-consumer checks; see `/private/tmp/e01-final-cache-cleanup.json`.

Local documentation checks passed:19 C1 routing/gate unit tests, changed-file Markdown links/fences for these three documents, and diff whitespace. These are documentation checks, not new runtime acceptance or remote CI. PR59 was refreshed live and remains OPEN/DRAFT at84c23a8c0, with no merge. This report/spec/ledger continuation remains local and unpublished.
