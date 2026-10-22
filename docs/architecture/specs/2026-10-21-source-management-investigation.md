# Source management investigation

Date: 2026-10-21. Read-only product investigation; no implementation approved by this document.

## Evidence boundary

Product baseline: `daa5ce0e5f96f36bc0bdac805d1f1cda4a1ca9a0` (merged PR #32).
KMP upstream comparison: local tracking ref `c62a3c678c8a7d3f2f042a3fcbcad7ab74ade02e`, dated 2026-10-18; not claimed to be today's upstream tip.
The primary checkout remains at `056b1f19b30d361b5b4135a0f2c036dde6966a5c`; product bridge/UI were read with `git show` at the merged baseline.
The local Android upstream ref contains an announcement-only tree, so it does not establish the older Android implementation.
The owner confirmed that the UI reference is Wanyuan Reader and agreed with the proposed management direction. Historical Wanyuan iPad screenshots were inspected during implementation: `wanyuan-reader/evidence/screenshots/03-all-book-sources.png` and `05-booksource-status.png` (2026-10-10). They show search by name/address, source name/address rows, group/status tags and a separate selection action. These are dated screenshots, not a fresh app walkthrough. Other-app comparisons below are official documentation reviews, not hands-on acceptance.

## Upstream and fork

The KMP source manager already has search, sorting, grouping, selection, single/bulk enablement, separate discovery enablement, group membership changes, import, export/share, source checks, editor/debug navigation and login entry points.

Evidence: `ui/src/sharedUiMain/kotlin/io/legado/app/ui/book/source/BookSourceListScreen.kt:136`, `ui/src/sharedUiMain/kotlin/io/legado/app/ui/route/BookSourceManageRoute.kt:290`, and `ui/src/commonMain/kotlin/io/legado/app/ui/book/source/manage/BookSourceViewModelShared.kt:128`.

Import first compares sources by identity. Default selection is new sources or sources with a newer `lastUpdateTime`, not every same-ID source. Existing name/group/enabled settings can be retained; custom order is retained. Timestamp comparison is not a content-diff proof. Evidence: upstream `ImportBookSourceViewModelShared.kt:356` and its `importSelect` implementation.

The fork leaves `BookSource`, `BookSourceDao`, and the reviewed source-management UI directories unchanged relative to this KMP ref. The shared importer has one relevant fork change: `importSelectAwait` allows callers to await successful persistence and receive errors; it retains the original field-preservation policy. This shared Compose importer is not the importer currently exposed by our native bridge.

Our new Swift/KMP path currently exposes only enabled text sources (`engine-ios/.../ReaderEngine.kt:180`) and immediate JSON import (`:187`). Duplicate IDs within an import use the last object; existing database IDs are replaced. It invalidates affected transient book/chapter handles. The Swift page (`native-ios-app/Sources/NativeReaderApp.swift:220`) has file import, refresh, and source name/ID rows. It lacks the upstream management interactions.

## Capability map

| Interaction | Existing foundation | Native work needed |
| --- | --- | --- |
| All sources, filters, groups | DAO full/filtered queries and group fields | Rich source snapshots and management-only listing |
| Single/bulk enable | DAO enable operations, chunked transaction (`BookSourceDao.kt:227`) | Typed bridge commands, refresh and active-operation policy |
| Add/remove group membership | DAO/group helpers and shared manager | Native controls and validated commands; no new schema indicated |
| Import review | Shared parser/comparison and keep-field policy | Native preview/commit contract, stale-preview policy, tested atomicity |
| Export | Shared selection serializer (`BookSourceExportShared.kt:59`) | Native file/share adapter and round-trip tests; upstream disables dangerous API on export |
| Discovery | `exploreUrl`, `ruleExplore`, `enabledExplore`; `WebBook.getBookListAwait` | Native browse models, navigation, pagination and failure handling |
| Checks, editor, login | Upstream UI/service entry points | Not proven native-ready; platform interactions must be audited |

The native host currently rejects verification/browser interaction and background WebView (`engine-ios/.../EngineHost.kt:144`). A stored login URL or discovery rule is not proof that all upstream sources work in the native product. Existing data capability is sufficient for ordinary management, but it does not certify the entire upstream feature set.

## Other readers

- Mihon separates installing extensions from using sources. Its documented reading path is source → popular/latest/search → details → library, with global search in Browse/Sources. Useful lesson: let ordinary readers use sources without entering a configuration workbench. Its extension packaging is not a reason to replace Legado JSON. Source: https://mihon.app/docs/guides/getting-started
- Readest documents OPDS catalog access alongside file imports and book-library organization. Useful lesson: present a saved content entry point and browse its contents. OPDS catalogs are not arbitrary scraping-rule sources, so their simpler configuration is not evidence that Legado's rule fields can be removed. Source: https://www.readest.com/docs/library

## Agreed direction for revising SPEC-007

Preserve upstream capability while progressively exposing controls. Default page: searchable source list, enabled/all/disabled filter, group filter, import, direct enable switch. Selection mode: batch enable/disable, group membership, export. Details: identity and configuration, then advanced edit/debug/login operations as supported. Discovery is a reading destination distinct from management.

Include ordinary group membership in the next management scope rather than only displaying groups. The approved import policy follows upstream new/newer preview selection and defaults to retaining local settings. This replaces the earlier new-only draft policy and keeps familiar upstream behavior visible in native review. A timestamp is advisory; explicit replacement remains visible. Deletion needs shelf/cache dependency semantics before implementation.

## Closeout findings

PR #32 is merged. Task worktree, Git registration and local task branch are absent; the primary checkout and its untracked Xcode project remain intact. Verified ignored-file backup and cleanup receipts are retained under `docs/evidence/2026-10-20-offline-reading/`.

Codex still lists the removed worktree as an active attachment. Three host archive requests returned queued. App logs repeatedly report inability to locate a source repository for archive recovery, including before this task's archive requests; those log records do not identify the worktree. Correlation and root cause remain unproven. Do not patch global app state or claim successful host archival.

Postmerge run 39524145312 failed twice. Attempt 1 timed out in simulator boot before Kotlin tests. Attempt 2 passed 107 Kotlin Native tests (63 data, 8 core, 36 engine), then timed out in Swift product simulator boot (`bootstatus`, 180 seconds); its Swift test log was not produced and boot log was empty. The local interruption/offline restart job passed. The second run sampled at least 27,491,491,840 free disk bytes. Aggregate RSS is not physical memory consumption and does not prove OOM.

These observations locate the failure at simulator startup, not a product assertion, but do not establish the underlying cause or a green merged baseline. A useful next diagnostic run must retain CoreSimulator startup diagnostics and memory-pressure information; another unchanged retry or a larger timeout alone would not establish a fix. No CI thresholds or gates were changed.


## Implementation follow-up

The owner-approved scope is implemented in SPEC-007. Local acceptance passed 60 product tests,
10 real iPad UI journeys, four process-interruption boundaries, offline restart, and 44 Python
harness/gate tests. These results do not establish the historical hosted startup timeout's root cause.
Startup diagnostics now retain bounded memory-pressure, swap and CoreSimulator logs without changing
timeouts or success criteria. The current PR's exact-head checks remain the hosted acceptance authority.

A later host archive attempt returned `This worktree is owned by another task.` The old path and
Git registration remain absent, while the attachment remains listed. Preserve the host record under
that ownership guard; do not edit global app state or claim the generic archive-queue log is conclusively
this attachment's root cause.
