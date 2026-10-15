---
specId: SPEC-004
title: Incremental Multi-Source Search and Expandable Candidates
status: implemented-core-device-accepted
revision: R7
creationDate: 2026-10-14
lastUpdateDate: 2026-10-15
relatedSpecs: [ADR-001, SPEC-001, SPEC-003]
---

# Incremental Multi-Source Search and Expandable Candidates

## Goal

Search a defined source scope using a title, author or combined query; show useful results as they arrive, update displayed works and their discovered source counts, and let the user expand and choose an exact source candidate for details and reading without changing existing shelf membership or progress.

This is incremental result display. It is not necessarily demand-triggered lazy loading: source searches can already be in flight while earlier results become visible. Query interpretation and matching remain subject to source-rule capability; combined input does not imply a new universal query language.

## Status and fixed baseline

R2 replaced the original draft's premature decisions to require sequential search, separate source rows as the main presentation, and a manually selected small source set. The product requirement does not prohibit temporary UI grouping across sources. On 2026-10-14, the owner approved merging this documentation and starting implement-spec execution. R3 records that authorization and removes fresh Wanyuan observation as a prerequisite. ADR-001 is unchanged; implementation PR merging and device installation remain separate approvals.

[SPEC-003 C3-A](https://github.com/austery/legado/pull/8) merged at `7e8c522ead9cf4b3301e8dc6fd87b42a61b2ed7f`. All code findings below use that fixed baseline, not an unverified newer upstream version. The next slice follows [ADR-001](../decisions/ADR-001-native-experience-and-upstream-ownership.md): reuse existing capabilities, keep one authority per category of state, and avoid speculative storage redesign.

## Implementation and acceptance checkpoint (R7)

Implementation merged in [PR #16](https://github.com/austery/legado/pull/16)
(`8fd9921c4`); the physical reader overscroll follow-up merged in
[PR #17](https://github.com/austery/legado/pull/17) (`eba022605`). The product
behavior and exclusions below remain unchanged. The fixed-source analysis below
is historical rationale, not a claim that implementation has yet to begin.

Build 7 physical checks on 2026-10-14 passed the observed Stop-to-narrowed-scope
and Stop-to-replacement-query sequences. On 2026-10-15, the isolated two-source
physical check also passed expansion and candidate selection while a slow peer
was unfinished, followed by details, catalog and visible chapter body. The
original build 7 was restored before this check; temporary permission diagnostics
were not part of the accepted search implementation.

The previous `Local network prohibited` blocker was resolved for the isolated
installation by obtaining the system local-network permission prompt during a
Bonjour diagnostic flow. This is an observed recovery, not a proven OS root cause
or a production networking change. See [permission recovery and timed evidence](../../evidence/2026-10-14-spec004-ipad.md#follow-up-local-network-recovery-and-in-flight-selection-passed).

On 2026-10-15, a further isolated physical sequence passed source-local paging,
failed-page retry and completed-source restart. Request logs confirmed that retry
repeated only the failed page, exhausted peers were skipped, and restart replaced
only the selected source's candidates. This exercised the nonempty-page fallback,
not explicit `hasMoreRule` termination or restart during an in-flight request.
See [paging/retry/restart evidence](../../evidence/2026-10-14-spec004-ipad.md#follow-up-isolated-paging-retry-and-restart-passed).

The isolated search/shelf-resume round trip also passed on 2026-10-15: after
searching and reading a different candidate, the original synthetic shelf book
retained its source, chapter 2 and the same visible numbered paragraph region.
See [resume evidence and limits](../../evidence/2026-10-14-spec004-ipad.md#follow-up-isolated-search-and-shelf-resume-round-trip-passed).

This completes this round's core physical search acceptance. The next step is
review closeout of PR #18 and ordinary use, not another automatically expanded
test cycle. Merge still requires explicit owner approval. The accepted scope is
the observed build 7 journeys, not universal device/source certification.
Rotation, split view, offline process restart, in-flight source restart and
explicit `hasMoreRule` physical coverage remain follow-up coverage. Importing or
certifying the 66-source bundle and changing Loading are not prerequisites for
this MVP search slice. Core-flow regressions discovered later remain actionable.

## Existing shared capability

The shared SearchModel already provides substantial orchestration that the narrow ReaderEngine export does not expose:

| Capability | Fixed-source evidence | Qualification |
| --- | --- | --- |
| Controlled concurrent source searches | SearchModel:114-117,150-183; mapParallelSafe:63-76 | A configured concurrency limit bounds in-flight work. It is not a product cap on total searchable sources. |
| Incremental result delivery | SearchModel:184-185,214-239 | Each completed source page updates results; it does not wait for every source to finish. |
| Temporary work grouping and source counts | SearchModel:308-346; SearchBook:50-55 | Exact name/author pairs are grouped; origins is a set of source IDs, not a full list of independently selectable candidate records. |
| Source-local pagination and restart | SearchModel:99-109,202-207,249-299 | Existing next-page/exhausted/generation state should be evaluated for reuse, not rebuilt without reason. |
| Raw source candidate groups | SearchModel:354-378,406-407 | These retain exact source/book records and can support expansion plus a conservative presentation projection. Export immutable values; do not expose mutable upstream entities. |
| Scope resolution | SearchScope:115-165 | Empty scope resolves all enabled sources; group/single-source modes and fallbacks exist. This describes Legado, not Wanyuan's default or our approved default. |

Multi-source mapParallelSafe suppresses non-cancellation failures when the scope has more than one source (FlowExtensionsShared:69-74). Existing callbacks alone therefore do not establish a faithful per-source failed-versus-empty contract. Necessary outcome reporting must be validated or narrowly adapted rather than inferred from absence of results.

## Reference application evidence

The retained 2026-10-13 iPad walkthrough records grouped search results, expandable source editions and counts increasing while results arrive. Screenshot 03 shows the All sources switch enabled at that observed moment. These support incremental grouped presentation, but do not establish a clean-launch default, the actual number of sources requested, Wanyuan's concurrency algorithm, exact grouping normalization, or its missing-author policy.

The observed search used an existing author-history chip because keyboard forwarding did not enter the requested text. The successful reading example was subsequently entered through discovery, not through a proven uninterrupted search-to-reader journey. No fresh device experiment or 66-source request audit is claimed by this revision. Detailed screenshots remain in the local evidence archive; the behavior and limitations needed for this proposal are stated here.

## Proposed product behavior

- Show the active search scope clearly. Use all enabled, supported text sources as the initial product default, with explicit narrowing to selected sources. This is our MVP choice, not a claim about Wanyuan's factory default; do not assume all 66 imported Wanyuan configurations exist or are eligible in this app. Allow source-scope selection without requiring users to handpick a small set before every query.
- Show results as source pages arrive and update the displayed work list and discovered source counts. A discovered candidate is not proof that its chapters are readable. Show necessary overall progress, partial-failure and cancellation information without turning the main result list into a per-source diagnostic console.
- Group exact, nonblank title/author matches provisionally for display. Keep missing/blank-author candidates separate by exact source/book identity. Do not invent author values or normalize title/author beyond a reviewed policy. Placeholder-author treatment remains an explicit decision if observed data require it.
- Expand a displayed work into its currently retained candidates, with source name and exact source/book identity. Candidate records, not only upstream origins IDs, must survive the projection. Derive source counts from distinct source IDs among retained candidates in the current session; restart/removal must not leave stale counts or unselectable entries.
- Selecting any candidate follows its own details/catalog/reading path. Grouping does not persist a new work identity, replace a shelf record, or switch an existing shelf book's active source. Shelf admission remains explicit and preserves SPEC-003's safe re-add behavior.
- Retain source-local pagination, retry/restart and stale-response protection where supported by the shared implementation. Show an explicit incomplete/error outcome instead of presenting a failed source as successfully empty.
- Cancelling or replacing a query retires that session's future callbacks and work. Completed results may remain visible after cancellation with an incomplete-search indication. A new query must never inherit old results or paging state.

## Reuse and host integration gate

Prefer reusing SearchModel's orchestration through a narrow native contract. Do not commit to sequential execution or directly bypass the host gate before evaluating actual iOS behavior.

Current ReaderEngine requests hold EngineHost.gate around an action (ReaderEngine:336-377). SearchModel.search starts child work and returns before its complete search lifetime. Wrapping that launch alone in the existing action lock does not protect all subsequent work. EngineHost also holds a process-wide interaction-failure marker (EngineHost:34-47); simultaneous sources cannot be assumed to have independent errors merely because HTTP supports concurrency.

As the first implementation gate, review and verify scope/provider registration, coroutine lifetime, cancellation, JavaScript host state, Cookie/variables, interaction errors, result ownership and coexistence with shelf/resume operations. A concurrency-safe adapter must preserve per-source outcomes and complete session ownership. If existing reuse cannot satisfy this with a bounded change, report the concrete limitation and compare options before changing the runtime. Serialization is a possible evidence-based fallback, not the preselected product design.

## Exclusions

No schema migration, persistent cross-source work/candidate database, active-source switching, automatic shelf insertion, discovery browsing, prefetch, full-book download, cloud sync, per-site rule repair or runtime replacement. Search's normal runtime Cookie/variable/cache effects are not represented as side-effect-free; shelf membership and saved reading state remain protected.

## Execution gates and optional reference observation

1. Optional targeted Wanyuan behavior check (not an implementation prerequisite): record app/version, initial search scope, any remembered setting, query and incremental updates; expand a grouped work and observe candidate selection. Distinguish the observed session from a factory default and avoid changing the owner's shelf/progress. Compare a selected-source scope if safely available; record untested items rather than guessing.
2. Shared-runtime/native integration assessment: establish how SearchModel's concurrent lifetime and callbacks can coexist with EngineHost's global state, including failures and cancellation. Use isolated fixtures and storage for dynamic validation; no owner-data experiment.
3. Implement the stated default scope and conservative exact, nonblank title/author display grouping through a narrow native contract. Missing/blank authors remain separate. Record any host limitation requiring a wider runtime change before proceeding. The owner's 2026-10-14 authorization permits scoped implementation and task-branch PR publication; it does not approve a wider redesign or merge of that implementation PR.

## Acceptance proposal

1. Fast and delayed fixture sources prove that usable results appear before all sources finish. Concurrency stays within its chosen supported limit; no claim of native concurrency safety rests only on reading mapParallelSafe.
2. Same nonblank title/author candidates update one provisional display group and its exact discovered-source count; expansion preserves every selectable source/book record. Missing-author records remain separate. Pagination/restart cannot retain stale candidates or counts.
3. Selecting each expanded candidate obtains its own details and catalog. Existing shelf source/progress is unchanged until an explicit, governed shelf action; re-add keeps the stored source/progress.
4. Success, empty, partial failure, timeout and interaction-required paths have truthful outcomes. A failed source does not erase another source's results or silently become an empty success.
5. Source-local pagination/restart does not corrupt another source's state. Cancellation followed by a new query cannot deliver old results, paging state or misleading source counts.
6. Query input supports the agreed title/author/combined examples on controlled fixtures; source-specific limitations are disclosed rather than promised away.
7. Existing C3-A shelf/cached-resume and relevant C1/C2 regressions remain green. Device acceptance separately verifies the delivered scope control, incremental list, expansion and candidate-to-reader interaction.

## Fixed implementation references

- [SearchModel orchestration and incremental callbacks](https://github.com/austery/legado/blob/7e8c522ead9cf4b3301e8dc6fd87b42a61b2ed7f/data/src/commonMain/kotlin/io/legado/app/model/webBook/SearchModel.kt#L150).
- [SearchModel provisional aggregation](https://github.com/austery/legado/blob/7e8c522ead9cf4b3301e8dc6fd87b42a61b2ed7f/data/src/commonMain/kotlin/io/legado/app/model/webBook/SearchModel.kt#L308).
- [Raw source candidate snapshot callback](https://github.com/austery/legado/blob/7e8c522ead9cf4b3301e8dc6fd87b42a61b2ed7f/data/src/commonMain/kotlin/io/legado/app/model/webBook/SearchModel.kt#L370).
- [Source scope resolution](https://github.com/austery/legado/blob/7e8c522ead9cf4b3301e8dc6fd87b42a61b2ed7f/data/src/commonMain/kotlin/io/legado/app/ui/book/search/SearchScope.kt#L115).
- [Concurrent flow failure behavior](https://github.com/austery/legado/blob/7e8c522ead9cf4b3301e8dc6fd87b42a61b2ed7f/foundation/src/commonMain/kotlin/io/legado/app/utils/FlowExtensionsShared.kt#L63).
- [Candidate origin set and conversion](https://github.com/austery/legado/blob/7e8c522ead9cf4b3301e8dc6fd87b42a61b2ed7f/data/src/commonMain/kotlin/io/legado/app/data/entities/SearchBook.kt#L50).
- [ReaderEngine request serialization](https://github.com/austery/legado/blob/7e8c522ead9cf4b3301e8dc6fd87b42a61b2ed7f/engine-ios/src/iosMain/kotlin/io/legado/engine/ReaderEngine.kt#L336).
- [Process-wide host interaction state](https://github.com/austery/legado/blob/7e8c522ead9cf4b3301e8dc6fd87b42a61b2ed7f/engine-ios/src/iosMain/kotlin/io/legado/engine/EngineHost.kt#L34).
