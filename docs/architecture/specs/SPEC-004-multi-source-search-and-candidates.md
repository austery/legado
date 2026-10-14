---
specId: SPEC-004
title: Bounded Multi-Source Search and Candidate Display
status: draft
creationDate: 2026-10-14
lastUpdateDate: 2026-10-14
relatedSpecs: [ADR-001, SPEC-001, SPEC-003]
---

# Bounded Multi-Source Search and Candidate Display

## Goal

Find a readable source across an explicitly selected set of imported sources while preserving the existing bookshelf and reading state.

## Context and fixed baseline

[SPEC-003 C3-A](https://github.com/austery/legado/pull/8) is merged at `7e8c522ead9cf4b3301e8dc6fd87b42a61b2ed7f`. The current Engine exports single-source search with exact source/book identities (`engine-ios/src/iosMain/kotlin/io/legado/engine/ReaderEngine.kt:140`). ReaderModel currently tracks one selected source, one result list and one pagination counter (`native-ios-app/Sources/ReaderModel.swift:40,177`). Engine operations use a process-wide gate (`ReaderEngine.kt:346`). This slice reuses that execution policy rather than assuming independent parallel source sessions.

The local roadmap suggests multi-source candidate display before active-source switching. This document proposes that next slice; the owner has not yet approved its concrete scope or implementation. [ADR-001](../decisions/ADR-001-native-experience-and-upstream-ownership.md) prioritizes a complete bounded journey and existing storage reuse.

## Proposed scope

- Select a bounded set of enabled supported text sources for one query; retain single-source search as the one-source case. Confirm the practical selection limit before implementation.
- Execute the existing source search sequentially and expose per-source pending/loading/results/empty/failed/cancelled state. Deliver useful results as each source completes. Do not redesign the Engine gate or introduce parallel runtime sessions.
- Display results with explicit source provenance. Keep candidates separate by source ID and book ID; do not introduce cross-source work identity or merge missing-author results.
- Keep pagination state per source/query and provide source-specific load-more/retry. Reuse the current pinned runtime's paging contract; do not assume it implements newer upstream continuation capabilities.
- Selecting a candidate follows the existing detail/catalog/reading journey. Shelf admission remains an explicit action using the existing safe-add contract. Re-adding a known identity retains its stored source and progress.
- Cancel or supersede a query without accepting stale callbacks into the new search. Keep already completed results and distinguish unsearched/cancelled sources from verified empty results.

## Exclusions

No schema migration, new persistent candidate store, source switching, automatic shelf insertion, discovery browsing, prefetch, full-book download, cloud sync, per-site rule repair, or source-runtime replacement. Runtime Cookie/variable/cache effects remain governed by the existing source execution contract; this is not a claim of side-effect-free search.

## Acceptance proposal

1. A controlled fixture query searches at least two selected sources; each candidate retains the exact source/book identity through detail and catalog selection.
2. Mixed success, empty, network failure and unsupported/interaction-required results remain distinguishable; one source failure does not discard another source's successful results.
3. Load-more/retry operates on the correct source/query without replacing another source's results or losing paging state.
4. Cancelling and immediately starting a different query cannot add stale results or launch remaining old-query work.
5. Searches and retries do not write shelf membership, active shelf source or saved reading progress. Explicit re-add preserves the existing identity/source/progress under SPEC-003 policy.
6. Missing-author candidates remain separate; no false source counts or cross-source deduplication claims appear in the UI.
7. Existing shelf, cached resume, navigation and cancellation regressions remain green. Actual device acceptance covers the delivered multi-source interaction separately from fixture evidence.

## Decision before implementation

Review this proposed slice and the practical source selection limit. If it demands persistent cross-source identity or wider runtime/state changes, stop and discuss that scope instead of folding it into this MVP. Preserve C3-A acceptance and the source-rule/runtime reuse policy.

## Fixed implementation references

- [ReaderEngine single-source search and exact candidate identity](https://github.com/austery/legado/blob/7e8c522ead9cf4b3301e8dc6fd87b42a61b2ed7f/engine-ios/src/iosMain/kotlin/io/legado/engine/ReaderEngine.kt#L140).
- [ReaderModel search state](https://github.com/austery/legado/blob/7e8c522ead9cf4b3301e8dc6fd87b42a61b2ed7f/native-ios-app/Sources/ReaderModel.swift#L40).
- [ReaderModel current search flow](https://github.com/austery/legado/blob/7e8c522ead9cf4b3301e8dc6fd87b42a61b2ed7f/native-ios-app/Sources/ReaderModel.swift#L177).
- [Engine request serialization](https://github.com/austery/legado/blob/7e8c522ead9cf4b3301e8dc6fd87b42a61b2ed7f/engine-ios/src/iosMain/kotlin/io/legado/engine/ReaderEngine.kt#L346).
