# Native UI feature expansion

Date: 2026-10-19
Status: Deliveries through discovery merged; later slices remain candidates (updated 2026-10-23)

## Goal and evidence

The owner now requests progression toward Wanyuan's full user-facing functionality. This expands ADR-001's earlier bounded MVP product scope; it does not select a new runtime, database, or source format. Continue using the native Swift frontend and existing KMP execution boundary. Confirm the feature inventory incrementally: the retained Wanyuan walkthrough is partial, and binary strings do not prove working features.

Inspected checkout: `6a968ccee`; locally available `origin/native-reader`: `1f0dc5ef8b2bbe806122cd4f51afd098007b627e`. The native-ios-app and engine-ios trees have no diff between these revisions. Remote PR discovery failed because GitHub was unreachable; remote currency remains unverified. No builds or simulator tests were run for this proposal.

At the original planning baseline, native capabilities included explicit shelf admission/removal, durable resume, incremental multi-source search, exact candidate selection, chapter navigation, continuous reading and typography controls. Source import is embedded in search; details and the chapter list share one screen. Reading style is view state. At that baseline, native exports did not provide active-book source switching, discovery, bookmarks or whole-book downloads.

## Delivery status (2026-10-23)

The proposal above records the original 2026-10-19 planning snapshot, not the
current checkout. Everyday navigation/global typography (PR #30), explicit source
switching (PR #31), bounded offline reading/cache controls (PR #32), source
management (PR #33) and [discovery / SPEC-008](SPEC-008-native-discovery.md)
([PR #34](https://github.com/austery/legado/pull/34)) have merged into `native-reader`.
Discovery merged as `0ec7c618250e1c4acce8a8143053ccad9ec0798f`, including the separately
approved Native JS context repair. Its simulator and exact-head PR/merged C1
closeout is recorded in SPEC-008; this does not establish live-source or device acceptance.

Subsequent maintenance deliveries also merged: upstream integration PR #35,
validation/H1/H2 documentation PR #36, UI fixture orientation PR #40 and upstream
integration PR #42. Current product snapshot: `61562bc558d76d901a854f79136d28e9077a2781`;
integrated KMP upstream: `d31c0a270e7c8610e9679dbbda5a6bee06927952`.
See [maintenance status](../../MAINTENANCE.md#current-limits-and-completed-pilot).

No feature slice is active under this plan. Bookmarks, in-book search and other
remaining coverage candidates require their own approval and acceptance.
Interactive login remains a follow-up; upstream fields do not establish native
runtime support. Full Wanyuan feature coverage and current-build physical-device
comfort have not been established.

## Original first-delivery proposal: everyday native reading UI (delivered in PR #30)

Make the existing working journey coherent before adding another shared-state operation.

1. Give shelf, search and source import clear navigation. Keep reading immersive and preserve search candidates when visiting a book. Add no placeholder discovery or download buttons.
2. Separate book details from the catalog. Use currently available title, author, introduction and source identity; offer explicit trial reading and shelf admission. Do not invent cover or freshness data.
3. Provide catalog title filtering and current-chapter positioning. Returning without selecting another chapter preserves the displayed paragraph. Selecting another chapter remains an explicit reading action.
4. Organize reader controls into catalog, typography and appearance. Persist application-wide presentation preferences only, with defaults for missing or invalid values. Keep book identity and reading position in their existing authority.
5. Present actionable loading, empty, partial-failure and save-failure states without replacing readable content unnecessarily.

Proposed preference policy: typography/appearance apply globally, survive relaunch and do not write book progress merely because text reflows. Per-book overrides are a later feature.

## Original first-delivery simulator acceptance contract

Use the real native app and KMP bridge with controlled sources and isolated synthetic data. Fixtures make failures reproducible; they are not a replacement production backend.

- Shelf -> search -> expanded candidate -> details -> catalog -> chapter -> shelf -> reopen preserves the selected source and saved paragraph.
- Previewing another candidate does not change an existing shelf entry or its progress.
- Catalog filtering and dismissal preserve the current reading session; an explicit chapter selection opens the selected chapter.
- Typography and appearance survive process relaunch; relayout does not corrupt the paragraph anchor.
- Failed chapter loading and failed position saving retain recoverable readable state, with working retry/cancel actions.
- Portrait and landscape iPad controls remain visible and usable; capture actual screenshots of the principal screens.
- Run focused native UI/journey regressions and required repository gates on the implementation revision. Report simulator evidence separately from physical-device acceptance.

Before implementation, verify the latest branch/PR state and use a task-owned checkout. Preserve the primary checkout's untracked glossary and Xcode project. Record and release only invocation-owned temporary simulator resources under the shared lifecycle rules.

## Coverage backlog and scoped delivery status

This is a coverage backlog, not a claim of an exhaustive observed Wanyuan inventory. Each remaining slice needs a concrete behavior contract and separate acceptance. Merged rows describe bounded deliveries, not every capability implied by the row title.

| Order | Delivery | Status and remaining boundary |
| --- | --- | --- |
| 2 | Explicit active-book source switching | Merged in PR #31 (SPEC-005). Prepare candidate content before commit; chapter matching and ambiguity; failure preserves the old source and resume. Do not copy character offsets across different bodies. |
| 3 | Adjacent-chapter prefetch and download/cache management | Bounded next-two prefetch, next-20 cache and protected controls merged in PR #32 (SPEC-006); whole-book downloads are not claimed. |
| 4 | Source management and discovery | Source management merged in PR #33; discovery in PR #34. Interactive verification remains outside these deliveries. |
| 5 | Bookmarks, text search and richer shelf management | Coordinate semantics, search scope, sorting/groups and persistence authority. |
| 6 | Local books, richer pagination/font options | Verify actual reference behavior and upstream native capabilities before promising formats or modes. |
| 7 | Audio/TTS, backup/sync, RSS and browser-related features | Treat as coverage candidates for the full-function goal; verify reference presence, personal relevance, platform support and data/permission semantics. Do not silently exclude or claim support. |

Maintain a feature inventory with observed reference behavior, native implementation, upstream reuse candidate, missing contract and acceptance evidence. Expand it at each slice rather than interpreting the old MVP exclusions as permanent exclusions.

## Owner approval

On 2026-10-19 the owner approved the first delivery, simulator implementation and acceptance, and globally applied presentation preferences. That first delivery is complete. Remaining coverage candidates require separate approval; this historical authorization does not start another continuous goal. A broader storage redesign remains a separate decision.
