# SPEC-007 native source management acceptance

Date: 2026-10-21. Base: `daa5ce0e5f96f36bc0bdac805d1f1cda4a1ca9a0`.
Runtime implementation was frozen at `541be9f3a`; subsequent commits strengthen test coverage
and full UI discovery without changing runtime source. Final local product test source is `5b9fe0af4`.
Documentation-only closeout commits may follow. This report does not claim hosted C1 success;
the task PR's exact-head checks are authoritative for that gate.

## Delivered behavior

- All imported text sources, including disabled sources; name/address search, status/group filters,
  selection retained through filtering, individual/batch enablement, and group membership.
- Reviewed JSON import with upstream new/newer defaults, visible identities/duplicate last-wins handling,
  local-setting retention, stale-preview rejection and transactional persistence.
- Selected Legado JSON export, supported-rule/configuration round trip, configured headers retained,
  runtime data excluded and dangerous API enablement normalized to false as upstream does.
- Disabled sources retain cached reading; affected background/search work retires before mutation.
  Read-only source listing/export preserves the displayed reading token and durable progress.

## Executed evidence

Artifacts are retained on the acceptance host under
`/Users/leipeng/Documents/Projects/legado-native-ui/docs/evidence/2026-10-21-source-management/`.
Large logs, screenshots, xcresults and backups are local evidence, not included in the checkout.

| Run | Observed result |
| --- | --- |
| `product-10` | 60 real Swift/KMP tests passed; zero failures/skips. Includes held-cache disable, cross-engine held-search retirement, stale import, injected transaction rollback, retained settings, and committed export/import/re-export equality. |
| `ui-07` | 10 actual iPad UI journeys passed; zero failures/skips. Source journey covers same-name/different-ID review, search/status/group filters, retained selection, group add/remove, disable/relaunch and native export dialog. Nine existing reading/switch/cache journeys remain green. |
| `process-01/interruption/results.json` | All four forced interruption boundaries verified with distinct old/new PIDs. |
| `process-01/shelf-restart/results.json` | Prepare and offline verification passed after process restart. |
| `legado-source-python-final.log` | 44 Python harness/gate tests passed. |
| `legado-source-framework-build05.log` | Simulator Kotlin framework build passed with upstream group separator semantics. |

Actual portrait, landscape, import-preview, relaunch and system-export screenshots are mapped in
`ui-07/screenshots/manifest.json`; source landscape and export screenshots were visually inspected.
The source UI initially failed at the Form-based Add action (sheet remained open). The native
confirmation-toolbar action, plus closing only after committed data returns, passed focused and
full UI acceptance. No test assertion or CI timeout was relaxed.

Independent Standards/correctness and Spec reviews at `541be9f3a` found no remaining concrete issues.
Earlier preview identity and read-only export/session findings were fixed and covered by regressions.
Later changes only add held-cache-disable/export-round-trip tests and preserve default full UI discovery.

## Scope and resource disposition

No physical-device acceptance or whole-source/live-source compatibility certification was performed.
Discovery browsing, rule editing/debugging and browser/login interaction remain later work.
Historical merged-head C1 startup timeouts are not claimed fixed by an unreproduced run.
The diagnostic addition preserves original gates and records bounded startup evidence on future failure.

Fourteen completed private build directories were archived and removed after inactivity checks and
verification of 31,110 regular files. Archive hashes and exact paths are in
`completed-build-cleanup.json`. This is not a physical disk-space gain claim. Current run outputs,
xcresults, screenshots and the active task worktree remain for delivery/review until reconciled.
The primary checkout, its untracked Xcode project, unrelated worktrees, user devices and shared caches
were preserved. An old Codex attachment remains under a cross-task ownership guard; its filesystem
path/Git registration are absent. No global app-state workaround was applied.
