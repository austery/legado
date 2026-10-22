# KMP upstream integration — 2026-10-22

## Pinned boundary

- Product base B: `0ec7c618250e1c4acce8a8143053ccad9ec0798f`.
- Last integrated upstream U0: `c62a3c678c8a7d3f2f042a3fcbcad7ab74ade02e` (verified merge-base).
- Incoming upstream U1: `c66940d6a91916fa5fdf43a4dfe9ae63e2b7ea8b`.
- Fourteen commits, 48 upstream paths. Preserve all upstream ancestry.
- Branch: `codex/sync-kmp-upstream-20261022`; host-managed isolated checkout:
  `/Users/leipeng/.codex/worktrees/sync-upstream-oct22/legado-native-ui`.
- Mainline C1 run `39763533497` succeeded on B; Test Build `39763533498` was skipped.
  These are baseline evidence, not validation of this integration.

## Disposition and risk matrix

| Commits | Change | Disposition / required evidence |
| --- | --- | --- |
| `8174cc335` | Binary request bodies in source scripts, shared charset transport and Native dispatch | Integrate; actual QuickJS tests must preserve unsigned/signed/all-byte arrays, Native-returned bytes and text overloads. Loopback HTTP must verify raw-byte and Unicode round trips. |
| `8807e0309` | Android/desktop challenge solver and JVM timeout budget | Integrate with platform boundary explicit: this does not add Cloudflare solving to iOS/OHOS. Inspect timeout/retry and cancellation behavior; no live challenge acceptance claimed. |
| `459c5937f`, `ad3d1e6a4` | QRC word timing, translation and offset handling | Integrate; upstream parser tests execute through data JVM tests. Check offset and mixed-format behavior. |
| `1d4a40852`, `36be0bf29`, `6949b2566`, `bc11490ac`, `70be45934` | Audio spectrum, palette, edge glow, lyric animation and pause decay | Integrate as original-client behavior; inspect shared state and retain local source/catalog return fixes. Native compilation required; no playback/device visual acceptance claimed. |
| `259f50764`, `10d08cd99` | Shelf badges, search suggestions/history and keyboard dismissal | Integrate original Compose client changes; inspect shelf lookup and navigation boundaries. Existing catalog regressions remain required. |
| `ab0e451cf` | Android pre-12 blur fallback | Integrate Android implementation; outside Swift product UI acceptance. |
| `f7d4b208c` | Help changelog | Integrate documentation. |
| `c66940d6a` | Portable PI constant | Integrate. Sole merge conflict was obsolete ColorUtils/PI imports; upstream already includes kotlin.math.PI. No behavior selection by blanket ours/theirs. |

No schema, migration, entity, Swift product, dependency or CI routing file changes occur in the upstream range. Existing schemas and migration lineage remain untouched. Tests use synthetic fixtures; existing app/user databases are not opened.

## Validation status

- Merge rehearsal and resolved staged diff whitespace checks passed.
- Final JVM: data 355, core 17, UI 262 = 634 tests; zero failures/errors/skips.
- Both simulator/device native static libraries built with the existing Xcode installation.
- Initial Native run: 118 passed (data 66, core 8, engine 44), including real QuickJS and loopback HTTP upload; its invocation-owned simulator was removed by teardown. This predates the two subsequent lyric/spectrum repairs. Final Compose iOS compilation and both framework builds passed. Repaired-tree Native: 118 passed with no failures/errors/skips; exact-head CI remains pending.
- CI harness/report guard suite: 44 passed.
- Binary bridge regressions live in the already-required `NativeJsRuleBridgeTest` suite.
  The HTTP echo endpoint is part of the existing invocation-owned loopback fixtures.

## Reproduced upstream defects

- SYNC22-01: AudioSpectrum populated a private array instead of returned Frame.bands. A 187.5 Hz/6 kHz sine-wave regression failed on the merge snapshot. Write measurements directly into the reused frame, and clear its values on reset. Preserve the allocation-free frame contract.
- SYNC22-02: QRC offset clamped the start before computing the end. `[offset:200]` with `A(100,200)` returned end 200 instead of 100; the focused parser test reproduced that failure. Shift start/end independently before clamping. The display consumer also distinguishes explicit zero end from absent end (-1), preserving completed-before-zero words and Enhanced LRC fallback. Parser-to-progress tests cover both.

Independent Standards review identified these two defects; Spec review found no actionable preservation/scope finding on the initial merge and upload tests. Focused final re-review accepted the spectrum, parser and rendering repairs with no remaining actionable finding. Final JVM, Compose iOS compilation and both framework builds passed. Final Native: 118 passed (66 data, 8 core, 44 engine). Exact-head CI remains pending.

## Resource inventory

The isolated checkout belongs to this synchronization task. Its recovery base is B and upstream input U1; unpublished adaptations must be preserved until remotely published. Build outputs under this checkout are reproducible via the checked-in build/CI scripts. Keep the checkout while its PR is active; after delivery follow RESOURCE-LIFECYCLE ownership, recovery, unique-content and consumer checks. Native CI creates and tears down its exact simulator UUID through the existing harness. No other task worktree, baseline simulator, shared cache or primary checkout is disposable under this task.

## Deferred scope and limitations

PR27 F03/F04/F05/F06/F07/F09 and PR19 F15/F16 remain historical follow-ups; do not infer closure from this merge. Reassess only findings reached by the new changes. No live-provider, rendered Compose, full asynchronous ScreenModel lifecycle, physical-device, Android/OHOS or desktop playback acceptance is claimed. Publication and CI do not authorize merging the PR into native-reader.

## L35-F01 review repair

The external v1 review identified successful binary POST responses registered in the global handle table without scope ownership. Three real Native/QuickJS/loopback regressions reproduced retained HttpResponse objects after evaluation cleanup, direct scope close, and closing concurrent scopes. This is dynamic handle-retention evidence, not an RSS growth measurement.

Only method 312 now uses the existing NativeJsPropertyBridge.registerScopedHandle mechanism. No global clear, response wrapper redesign, or old request dispatch changes. Repeated analyzer evaluations check immediate release; direct scope tests prove response usability across evaluations before close; two independently executing scopes prove closing a peer does not invalidate the live response and both handles are gone after their owners close. The tests reside in existing required Native suites.

Historical unscoped GET/HEAD/text POST registration (methods 309–311) remains a separate follow-up, L35-F02: assess scope ownership and compatibility before repairing those old paths. This bounded fix does not claim that all registry leaks are resolved. Review and final exact-head validation evidence are maintained in PR35.

Local repair validation: Native 121 tests passed (data 69, core 8, engine 44), zero failures/errors/skips. The same three added regressions failed on the original registration with retained HttpResponse objects. Exact revised-head C1 evidence is recorded in the PR after publication.
