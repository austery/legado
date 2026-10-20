# SPEC-006 offline reading acceptance

Implementation base: PR #31 merge `6fd56ebecd1891a80b7c791d6e6490868a3f0683`.
Runtime revision: `6c0518a0044e7a08ffa04eb874a4b9518fc23fa3`; later commits change acceptance tests only.

## Delivered contract

- Verified per-chapter catalog availability and details counts for shelved text books.
- Manual next-20 caching with verified completion, cancellation, partial failures and retry of only missing/failed bodies.
- Global default-off next-2 prefetch, limited to foreground app lifetime and spare source-request capacity.
- Concrete-count optional-cache clearing that protects persisted resume and all active reading-session bodies, with verified partial-deletion reporting.
- Reuse of existing atomic storage and source leases, with physical folder/catalog ownership checks. No schema migration, new cache namespace or progress write by caching.

## Executed evidence

Local raw evidence is retained outside the worktree at `docs/evidence/2026-10-20-offline-reading/` in the owner's primary checkout. These are synthetic loopback simulator results, not live-source or physical-iPad certification.

| Check | Evidence | Result |
| --- | --- | --- |
| Native framework | build-05.log | Passed |
| Swift/KMP ordinary suite | product-04/summary.json | 52 passed, zero failures/skips |
| Forced process interruption | product-03/interruption/results.json | Four commit/file boundaries verified with new PIDs |
| Offline process restart | restart-fixed-01/results.json, restart-verify.log | Prepare and verify passed; all 21 available chapters read with listener stopped, identical body hashes, PID 4692 -> 4894 |
| UI controls | ui-03/summary.json | 9 passed, zero failures/skips |
| Kotlin/Native regressions | native-01/summary.json | 107 passed (data 63, core 8, engine 36) |
| Harness tests | harness-tests-03.log | 42 passed |
| Exact-head required C1 | PR check: `C1 engine regression` | Required after publication; see the PR for the immutable-head result |

The ordinary suite includes immediate pre-dispatch cancellation and closed-engine terminal delivery (201 requests), held-network cancellation, foreground preemption, removal, source switching, protected clearing across engine instances, corrupted/empty bodies, HTTP failure/retry and partial storage/deletion failures. The restart fixture verifies explicit caching works with one network permit while speculative prefetch leaves that permit available.

## Diagnosed acceptance failures

Earlier restart invocations failed before opening the product because a test-only manifest in UserDefaults was absent in the verifier. Diagnostic assertions confirmed both manifests in the preparation process, while exported preference files lacked them. Database rows and all 22 chapter-file hashes were unchanged across host reinstallation. The handoff now uses atomic Documents JSON; new-PID, saved-paragraph, database and body-hash assertions remain unchanged. No timeout or assertion was relaxed. Global prefetch preference persistence is verified separately through app termination/relaunch in UI acceptance.

UI-02 exposed a test interaction error: tapping the full SwiftUI switch row did not change its value. UI-03 targets the native switch control using the existing appearance-toggle interaction pattern and passes the unchanged two-chapter and relaunch assertions. Final screenshots were visually inspected for portrait/landscape controls, confirmation, catalog labels and enabled global prefetch.

## Independent review

Two independent reviewers examined the immutable implementation and fixes. Accepted findings corrected missing terminal delivery when a lazy job was cancelled before dispatch, and accidental reservation of the sole network permit for manual caching. Follow-up review corrected a UI-test race by waiting for real prefetch publication before navigation. Final source review reported no unresolved findings. Reviewers did not execute tests; run evidence is listed above.

## Scope and resource boundaries

No persistent download queue, background execution promise, whole-book downloader, media cache, catalog refresh or global purge is included. Each invocation owns an isolated simulator and synthetic application. Cleanup receipts preserve exact UUIDs, recovery inputs and absence of consumers; logs, result bundles and screenshots are retained. Active PR worktree and shared build caches remain available. Owner's primary branch and unrelated Xcode project are preserved.

## Screenshot index

Final `ui-03/screenshots/manifest.json` maps screenshots to test names. Representative attachments: `652F1DC1-EF18-42F2-B7C6-96B11DECD89E.png` (global prefetch), `DC193812-C7E0-46B9-9361-54BA120B1FCA.png` (landscape controls), `F77F1F03-A650-4868-BC1C-A1FF14B3D44C.png` (protected clear), and `5D5EE878-6D54-4B4A-9721-41A21CF35E9F.png` (catalog after clearing).
