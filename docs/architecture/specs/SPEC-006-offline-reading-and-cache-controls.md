---
specId: SPEC-006
title: Offline Reading and Bounded Cache Controls
status: Implemented
priority: P1 - Core Feature
creationDate: 2026-10-20
lastUpdateDate: 2026-10-20
owner: User (AI-Assisted)
relatedSpecs:
  - PLAN-005
  - SPEC-005
tags:
  - native-reader
  - offline-reading
  - cache-management
---

# SPEC-006: Offline Reading and Bounded Cache Controls

## 1. Goal

Let readers prepare a bounded amount of reading for offline use, see which chapters are actually available, and reclaim optional cached text without damaging durable reading position.

## 2. Verified baseline

PR #30 delivered everyday navigation and global presentation preferences. PR #31 delivered explicit source switching and merged as `6fd56ebecd1891a80b7c791d6e6490868a3f0683`. Its exact-head required C1 passed, and post-merge [C1 run 39510877804](https://github.com/austery/legado/actions/runs/39510877804) subsequently passed both regression jobs and the required aggregate check.

- `ReaderEngine.kt:325-382` already opens saved chapters and supports cache-only reads, including saved-body hash/length checks. Normal reading saves downloaded text and verifies readback.
- `BookStorage.kt` exposes chapter listing, reading, writing and individual deletion. `NativeBookStorage.native.kt:117-118` checks only file existence for `hasContent`, so it cannot alone justify an offline-ready label. Deletion also needs post-operation verification.
- `ChapterPreDownloader.kt` provides bounded upstream scheduling, but assumes its caller handles adjacent chapters and shared-reader lifecycle. `CacheBookShared.kt` is a process-global scheduler. Neither is currently a complete native Swift download-management contract.

These are reuse candidates, not evidence that the native app already has a download manager. Keep Swift as the client and KMP/storage as the authority.

## 3. Proposed first delivery

### Visible behavior

1. Add an Offline reading section to shelved-book details. Show cached readable chapters out of the stored catalog's readable chapters; do not promise unmeasured byte totals or whole-book completeness beyond that catalog.
2. Show per-chapter availability in the catalog: checking, available offline, missing, or unavailable after validation. Empty/unreadable files are not available; the saved chapter must also match its recorded body coordinates.
3. Offer Cache next 20 chapters after the current readable chapter, or all remaining chapters when fewer remain. Use the active source only, skip volume headings, and skip already verified bodies. Display completed/target counts, failures, cancel, and retry missing/failed chapters.
4. Offer a global Prefetch next 2 chapters toggle, initially off. Enabling it starts bounded foreground work after the current chapter is ready; ordinary reading has priority. Limit background cache work to one in-flight chapter and deduplicate it with manual cache requests.
5. Offer Clear optional cached chapters with a confirmation showing the concrete chapter count. Preserve the durable saved chapter and every currently displayed chapter backed by an active reading session. Do not clear other books, old-source folders, shelf metadata, catalog or resume. Report verified deletion results and partial failures.

### Lifecycle and persistence contract

- Scope this delivery to shelved text books and the current stored catalog. No whole-book persistent queue, automatic catalog refresh, background-execution promise, image/media download or global purge in this round; those remain later slices of PLAN-005.
- Foreground batches are cancelable. Backgrounding, closing the engine, removing the book or switching source invalidates pending work. Join in-flight work before clear/switch operations where needed; reject stale late publication using source/book/catalog ownership checks.
- Fully published chapters survive cancellation or termination. A batch never advances reading progress, admits a book to the shelf, switches source, or overwrites the currently protected resume body.
- On relaunch, derive availability from validated stored bodies. Do not display a dead in-memory task as running or automatically resume network work. The reader may explicitly retry remaining chapters.
- Use the existing cache write/readback path. A downloaded response is not completed until publication is verified. Cancellation may retain a chapter already published atomically, but must not leave partial text labeled available.
- Audit physical cache-key ownership before writing or deleting. Different source entries can share storage conventions; ambiguous ownership must refuse destructive action. Do not introduce a schema migration or new cache namespace without a separate design decision.
- Persist only the global prefetch preference in the existing presentation/settings mechanism. Book identity and reading position remain in their current authority.

### Reuse choice

Prefer existing source execution, atomic chapter storage and per-source request serialization. Evaluate the shared prefetch scheduler against the native lifetime above before adopting it. A narrow native orchestration adapter is preferable to importing a process-global queue whose ownership conflicts with cancellation or source switching. This draft does not approve a storage redesign.

## 4. Implementation order

- [x] Establish typed availability, batch progress and cancellation results; audit cache-key ownership and failure-safe deletion.
- [x] Implement manual next-20 caching and verified catalog indicators before enabling automatic prefetch.
- [x] Add the opt-in next-2 policy and protected optional-cache clearing.
- [x] Exercise real Swift/KMP behavior with isolated loopback fixtures and complete independent review. Require `C1 engine regression` on the exact PR head before merge.

## 5. Simulator acceptance

- [x] Cache a range, disable fixture networking, relaunch and read every reported available chapter without any network request.
- [x] Empty, unreadable, interrupted and saved-body-mismatched cache files never receive an available label.
- [x] Partial HTTP or storage failure preserves completed bodies and the old reading position; retry requests only missing/failed chapters.
- [x] Cancellation, backgrounding, removal and source switching retire pending work; late results cannot repopulate cleared caches or modify another source entry.
- [x] Prefetch stays within the next two readable chapters and never consumes the last capacity needed for a foreground reading request.
- [x] Clearing optional chapters preserves displayed content, the saved resume body and unrelated entries; offline resume still works after process restart.
- [x] Catalog counts, progress, failure and confirmation controls remain usable in portrait and landscape.
- [x] Existing source switching, preview isolation, shelf admission, resume and global typography regressions remain green. Report simulator and physical-device acceptance separately.

## 6. Approval and history

The owner approved this scope on 2026-10-20 and requested continuous implementation and simulator acceptance under a goal: next-20 manual caching, next-2 opt-in foreground prefetch, and protected cache clearing.

| Date | Status | Note |
| --- | --- | --- |
| 2026-10-20 | Draft | Proposed after PR #31 merge; based on the live native engine and storage interfaces. |
| 2026-10-20 | Ready for Implementation | Owner approved the scope and simulator acceptance. |
| 2026-10-20 | Implemented | Local simulator acceptance and independent review complete; PR publication requires exact-head C1 before merge. |

## 7. Acceptance evidence

[Simulator acceptance record](../../evidence/2026-10-20-offline-reading.md): 52 Swift/KMP tests, 9 iPad UI tests, 107 Kotlin/Native regressions, 42 harness tests, four forced interruption boundaries and a 21-chapter offline process restart. All passed locally; exact-head C1 is checked on the published PR. Physical-device and live-source acceptance are not claimed.

## 8. Related

- [Feature expansion](PLAN-005-native-ui-feature-expansion.md)
- [Explicit source switching](SPEC-005-explicit-source-switching.md)
