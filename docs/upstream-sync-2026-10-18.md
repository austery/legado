# KMP upstream integration — 2026-10-18

## Pinned scope

- Product base B: `6a968ccee3e20a2e4939fb120b776062b742d8ad` (`native-reader`, PR 27).
- Previous upstream U0: `060a9f1cb695dda7a8261b88b5a7b6ac0c0d2aca`.
- Integrated upstream U1: `c62a3c678c8a7d3f2f042a3fcbcad7ab74ade02e` (six commits, 54 files).
- Integration branch: `codex/sync-kmp-upstream-20261018`, isolated from the primary checkout.
- Preserve merge ancestry. Merge-tree and the actual merge found no textual conflicts.
- No database/schema/migration, native identity/resume model, or Swift product changes. No existing app or user data was opened or migrated during validation.

## Upstream intent and disposition

| Upstream commit | Behavior and consumers | Disposition and validation |
| --- | --- | --- |
| `a7efa6a63` | Symmetric decryption accepts cipher bytes through the Native JS bridge, in addition to encoded strings. | Accept; real Native `AnalyzeRuleCore.evalJS` tests cover a known AES vector, signed/unsigned/native-returned arrays, both return forms, hex/Base64, Unicode and invalid-ciphertext recovery. Retain PR 27 numeric-tag and structured-value fixes. |
| `17d29ab06` | Shared URI canonicalization feeds Native HTTP, images, WebDAV, browser and media URLs. | Adapt: fix repeated percent-escape digits. Execute the upstream desktop URI suite via `:data:jvmTest`; add Native request construction and Ktor/Foundation boundary tests. No cache identity or persistence rewrite. |
| `e304498c8` | Shared lyrics rendering/energy, platform audio observation and bounded playback speed. | Adapt the JVM-only `Math.PI` reference to Kotlin `PI`; retain the upstream behavior. Both Native frameworks and original Compose UI compile. Audio rendering/PCM fidelity and Android/OHOS playback are not device-certified. |
| `c9fec7c77` | Shared bottom-sheet expansion/collapse gestures. | Accept as original-client UI; retain existing native product flows. Compilation is not gesture/device acceptance. |
| `c686aa578` | Audio title opens book details and refreshes the returned snapshot. | Accept; existing fork cancellation and failed-removal handling remain intact. This does not implement a new Swift audio journey. |
| `c62a3c678` | Desktop observes whole-band audio level through an analysis-only filter. | Accept upstream platform implementation; no desktop playback acceptance claimed. |

The single integration PR preserves all six upstream commits. Review the upstream changes by the groups above, then the separate compatibility/test adaptation commit. Splitting this snapshot into unrelated feature PRs would obscure the upstream integration boundary; this does not establish equal runtime coverage for every upstream platform.

## Reproduced regressions and repairs

1. **URI escape corruption:** the upstream `encodeKeepEscapes` copied three characters but advanced only one. `a%20b` became `a%2020b`; repeated canonicalization compounded the corruption. The upstream suite reproduced **4 failures out of 12**. Advance by three only for a complete escape; malformed percent characters still advance by one. The same unmodified upstream tests then passed **12/12**.
2. **Native compilation:** `:ui:compileKotlinIosSimulatorArm64` failed on `LrcViewShared.kt` with `Unresolved reference 'Math'`. Use `kotlin.math.PI` with the same numeric semantics. The original Compose iOS compilation then passed.

## Coverage and gates

- `stageUpstreamUriTests` stages only the existing upstream URI test file into `:data:jvmTest`; it does not copy/fork assertions or add desktop application dependencies. `verify_url_tests.py` rejects absent, empty, skipped or failing reports.
- `kotlin_native_ci.py` requires concurrency, analyzer-rule bridge, crypto bridge and Native URL suites, in addition to nonempty successful reports for data/core/engine. Existing lifetime, cancellation, shelf, identity, resume and atomic-file tests remain.
- The cloud job retains both frameworks, Compose, JVM, Kotlin/Native, network/cache harness and ordinary Swift regressions. The local job retains four process-interruption boundaries and offline shelf restart, building its own host at the same PR head.
- Required `C1 engine regression` still requires both jobs to succeed. No skip, failure, cancellation, timeout relaxation or prior-head run can satisfy it. Live ruleset `25305446` remains active for `native-reader`, with strict required `C1 engine regression` and no bypass actors.
- Test fixtures and simulators are invocation-owned and synthetic. Native URL tests construct requests and parse with Ktor/Foundation; they do not claim a live remote Darwin HTTP compatibility test.

## Review and validation

Two independent static reviews of `6a968ccee...4c5e9f321` found no actionable Standards/correctness or Spec/contract findings in the inspected integration boundaries. Review is distinct from executed validation.

Local validation on code commit `4c5e9f321` passed:

- Native libraries, both iOS frameworks and Compose iOS compilation.
- JVM: data 344, core 17, UI 252 (613 total; no failures/errors/skips), including the 12 upstream URI tests.
- Kotlin/Native: data 59, core 8, engine 36 (103 total; no failures/errors/skips), including the new crypto and URL suites.
- Synthetic Swift harness: 82/82 full, 22/22 cache restart, 82/82 fresh-network observations. These include callback observations, not independent test counts.
- Ordinary Swift product suite: 38 passed, zero failures/skips.
- Interruption recovery: before-file, after-file, before-db and after-db all verified after external process termination. Offline shelf restart prepare and offline verify both passed.
- CI/fixture guard suite: 41 tests passed in a serial run. The updated required-gate checks also passed separately.
- Primary checkout stayed at B; its four pre-existing untracked files retained their SHA-256 values.

Only documentation changes follow that code commit. Final exact-head cloud/local/required CI evidence is recorded in the PR after completion. Local evidence is under `/private/tmp/legado-sync18-*`; it is not a substitute for the new PR-head CI.

## Deferred scope

PR 27 F03/F04/F05/F06/F07/F09 remain follow-ups: audio source ownership, Android PiP/controller lifecycle, JVM fatal-log visibility, persisted directory-enum compatibility, backup destination cleanup, and custom chapter export. PR 19 F15/F16 also remain separate. This integration does not relabel these findings as fixed. Reassess any of them if a later change reaches an active native contract.

No physical-device, full source-pool, live provider, Android/OHOS, desktop playback or existing-user-database acceptance is claimed. Merge requires explicit owner approval; this task stops with an unmerged PR and completed CI evidence.
