# SPEC-007 native source management acceptance

Date: 2026-10-21. Base: `daa5ce0e5f96f36bc0bdac805d1f1cda4a1ca9a0`.
Review-fix implementation: `559995773641a56bfbf9d5f1f2de61b94cc1e1b9`.
The task PR's final-head checks are authoritative for required C1. Historical passing
runs do not substitute for that gate. PR #33 must remain unmerged pending owner direction.

## Delivered behavior

- All imported text sources, including disabled sources; name/address search, status/group filters,
  selection retained through filtering, individual/batch enablement, and group membership.
- Reviewed JSON import with upstream new/newer defaults, visible identities/duplicate last-wins handling,
  local-setting retention and transactional persistence. Compare only selected identities with their
  preview snapshots; reject selected-source changes without losing concurrent unselected changes.
- Selected Legado JSON export, supported-rule/configuration round trip, configured headers retained,
  runtime data excluded and dangerous API enablement normalized to false as upstream does.
- Disabled sources retain cached reading. External source mutation stops stale search publication and
  delivers one cancelled snapshot to the original subscriber: completed candidates remain, pending
  source rows become cancelled and pagination clears. Query replacement/engine close remain silent.
  Read-only source listing/export preserves the displayed reading token and durable progress.

## Review feedback and counterexamples

Both review-v2 findings were reproduced independently on `4a37e4672` using real Swift/KMP:
`review-v2-repro-01` recorded two expected failures with no skips. Cross-engine disable left
`searchRunning=true; searchIncomplete=false`; changing unselected B made selected A fail `STALE_UPDATE`.
The defects originated in the earlier source-management implementation, not the subsequent CI policy
change. Earlier broad merge-readiness statements are superseded by this follow-up.

The fix keeps presentation state confined to the search event consumer. Source invalidation closes
publication immediately, cancels workers and sends a final immutable snapshot from cleanup. Atomic
lifetime transitions suppress duplicate terminal callbacks and obsolete notifications after silent
retirement. The import fix filters expected snapshots before the existing DAO transaction; nullable
snapshots for selected new sources, selected conflict rejection and atomic rollback remain intact.

## Executed evidence

Artifacts are retained on the acceptance host under
`/Users/leipeng/Documents/Projects/legado-native-ui/docs/evidence/2026-10-21-source-management/`.
Large logs, screenshots, xcresults and build outputs are local evidence, not committed artifacts.

| Run | Observed result |
| --- | --- |
| `review-fixes-product-01` | 61 real Swift/KMP tests passed; zero failures/skips. Both regression paths passed; selected stale rejection and injected transaction rollback remained green. This local build preceded a readability-only lifecycle cleanup and a stronger retained-result assertion; final-head C1 must run the final sources. |
| `review-fixes-ui-01` | 11 actual iPad UI journeys passed; zero failures/skips, at implementation commit `559995773`. The new journey holds a real search, disables its source through a second engine and verifies Stop disappears and Incomplete search appears. The ten previous source/reading/switch/cache journeys remain green. |
| `legado-pr33-fix-python-02.log` | All 44 Python harness/gate tests passed. The initial sandboxed invocation could not bind sockets; the loopback-enabled rerun passed without test changes. |
| `legado-pr33-fix-build3.log` | Final simulator Kotlin framework build passed with the verified local toolchain. |
| Final automatic C1 | Follow PR #33's associated run at its final head. Both original regression jobs and the required aggregate must succeed, including Native, Swift, harness, distinct-PID interruption and offline restart tests. |

New before/after search screenshots and all eleven journeys are mapped in
`review-fixes-ui-01/screenshots/manifest.json`. The new search transition screenshots were visually inspected.
Independent Standards/correctness and Spec reviews of `559995773` found no actionable defects;
those reviews did not claim to execute runtime tests. Receipts are in `review-fixes-independent-review.json`.

## Scope and resources

No physical-device acceptance or whole-source/live-source compatibility certification was performed.
Discovery browsing, rule editing/debugging and browser/login interaction remain later work.
Hosted simulator startup failures remain unresolved. Automatic C1 uses the owner-approved complete
local profile; original assertions, suites, timeouts and required both-job-success aggregate remain unchanged.
Existing offline UI runtime/orientation warnings are not represented as fixed or warning-free.

Run-owned simulators are removed in runner teardown and exact UUID absence is audited independently.
Keep logs, xcresults, summaries, screenshots and concise provenance. Build-output cleanup requires
verified ownership, recovery, unique-evidence preservation and inactivity. Where the host's unrelated
SMB mount makes inactivity inspection incomplete, retain the affected directory and record the gap.
The active PR worktree, primary checkout and its untracked Xcode project, unrelated worktrees and
shared runner/cache resources remain intact. No merge, service restart or global configuration change.
