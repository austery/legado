---
specId: ADR-004
title: Native Bookmark Identity and Storage
status: draft
creationDate: 2026-11-04
lastUpdateDate: 2026-11-04
relatedSpecs: [ADR-001, ADR-002, ADR-003, SPEC-005, SPEC-009]
---

# Native Bookmark Identity and Storage

## Approval and baseline

Lei approved the minimal bookmark outcome on 2026-11-04 and requested identity and storage design before implementation, with final independent review through Copilot Opus 5.5. The requested outcome covers saving the visible paragraph, listing, navigating, deleting and retaining bookmarks across restart and layout changes.

This draft proposes the persistent-data budget and lifecycle choices for owner confirmation. Product implementation and schema migration have not started. Merge approval remains separate.

Baseline is `bfbbc434f70eb31bb0aac5cef1e493b241f07178`, the merged Copy repair. PR-head and merged-head C1 passed. The integrated upstream remains the pinned revision recorded in [MAINTENANCE](../../MAINTENANCE.md).

## Existing contracts

- [Bookmark](../../../data/src/commonMain/kotlin/io/legado/app/data/entities/Bookmark.kt) stores title, author, chapter index and character position. [BookmarkDao](../../../data/src/commonMain/kotlin/io/legado/app/data/dao/BookmarkDao.kt) selects by title and author. Those queries also serve existing annotation and backup consumers.
- [NativeResumeDao](../../../data/src/commonMain/kotlin/io/legado/app/data/dao/NativeResumeDao.kt) owns original-body UTF-16 paragraph coordinates, text version and SHA-256. It validates source, book, chapter and revisions.
- [ReaderEngine](../../../engine-ios/src/iosMain/kotlin/io/legado/engine/ReaderEngine.kt) issues reading tokens for shelf-backed content. The engine retains the exact body and serializes persistence through its process-wide gate.
- [NativeShelfDao](../../../data/src/commonMain/kotlin/io/legado/app/data/dao/NativeShelfDao.kt) retains the book row when removing it from the shelf. Its explicit source-switch transaction deletes the old book row and creates the replacement.
- [AppDatabase](../../../data/src/commonMain/kotlin/io/legado/app/data/AppDatabase.kt) has schema version 91. The existing database is shared by native adaptation and upstream consumers.

These are source observations at the baseline. Migration, interruption and runtime behavior need executable characterization before acceptance.

## Proposed identity

A bookmark has an opaque UUID and two distinct references.

1. Its owner is the current shelf book record. This reference controls which book list contains the bookmark and follows a successful explicit source switch.
2. Its anchor identifies the captured source entry and original chapter body. Store source ID, source book URL, chapter URL, captured chapter index, text version, body SHA-256, UTF-16 length and paragraph-start offset. These values stay attached to the captured text when the active source changes.

Chapter title and a short original-text excerpt are display snapshots. They do not establish identity. Use the existing work-equivalence policy only inside the already guarded explicit source-switch operation. List, save, delete and navigation must use exact identifiers.

The visible offset comes from the existing portrait or spread reading callback. The engine resolves it to a valid paragraph boundary against its retained body. Swift submits a reading token and offset, rather than a trusted body or caller-supplied hash.

## Proposed storage budget

Add one Room entity and table named `native_bookmarks` to the existing database. Upgrade schema 91 to 92 through one additive migration. Add zero external dependencies and zero separate database or preferences stores.

| Stored fields | Purpose |
| --- | --- |
| `id` | Stable UUID for list identity and deletion |
| `ownerBookUrl` | Current owner, foreign key to `books.bookUrl` |
| `sourceId`, `sourceBookUrl`, `chapterUrl` | Exact captured source-entry identity |
| `chapterIndex`, `chapterTitle` | Captured catalog position and display snapshot |
| `textVersion`, `textSha256`, `textUtf16Length` | Compatibility and body-integrity checks |
| `paragraphUtf16Offset` | Canonical paragraph location |
| `excerpt`, `createdAt` | Bounded display text and stable creation order |

Use an owner lookup index and a uniqueness constraint on owner plus exact anchor identity, body version/hash and paragraph offset. Repeated saves of the same anchor return the existing bookmark. Deleting an already removed UUID is idempotent within the validated owner context. A later add gets a new UUID.

The existing `bookmarks` rows and their consumers retain their existing representation. The migration initializes the new table empty. Automatic conversion of title/author-only legacy bookmarks would require an explicit matching contract and is outside this slice.

## Lifetime and source switching

Saving requires an explicitly admitted shelf book and a valid displayed reading token. During trial reading, the UI offers the existing Add to shelf action before bookmark creation. Admission remains a separate explicit user action.

Removing a book from the shelf retains its book row, reading record and bookmarks. Adding that same book again makes its bookmarks available. Group removal or deletion has no effect on bookmark rows.

Extend the existing source-switch transaction with bookmark transfer. Read the old owner's bookmarks inside the transaction, run the existing replacement operation, and reinsert them under the replacement owner before commit. Preserve UUIDs and captured anchors. Any failure rolls back the shelf, resume and bookmark changes together. Exercise this using the real native database and fault injection.

After a source switch, old-source bookmarks remain visible with an unavailable-on-current-source explanation and a delete action. Navigation requires the captured source entry to be active. Switching back can make a bookmark usable again after its body passes validation. Cross-source remapping and automatic source switching are separate features.

A true deletion of the underlying book row outside source switching follows the foreign-key cascade. This differs from the existing Remove from shelf action and must be documented and tested at the storage boundary.

## Bridge and interaction budget

Add four public bookmark operations to ReaderEngine with immutable reply values and the existing error model.

- Save from the current reading token and visible offset.
- List for an exact current shelf source/book pair.
- Delete by bookmark UUID within that owner context.
- Open a bookmark after validating owner, active source, chapter and original body.

Use the existing engine gate and database transaction boundary for writes. Capture identity on request and reject stale callbacks when the Swift route or reading session changes. Save/list/delete do not advance reading progress. Explicit bookmark navigation uses the existing reading-save coordinator.

Opening validates the complete body hash, UTF-16 length, version and paragraph boundary before publishing a new reading session. A cache miss may fetch the captured chapter through the existing source runtime. Validation must happen before replacing current UI content or publishing changed text over cache needed by the current reading session. Missing chapters, disabled sources, changed bodies and unsupported versions return actionable unavailable-location states. The current readable session remains available after failure.

Use a compact reader action and current-book sheet. Display chapter title and excerpt, confirm successful save, support retry after failed writes, and preserve selection/Copy, chapter find and reading controls. Both layouts share the same bookmark list and anchor semantics.

## Alternatives

| Option | Benefit | Cost or conflict | Proposed disposition |
| --- | --- | --- | --- |
| Reuse legacy rows as-is | Small apparent schema cost | Title/author lookup cannot prove exact native identity or body compatibility | Reject |
| Add native fields to legacy bookmarks | One nominal bookmark table | Changes annotation, serialization and backup contracts and still needs native-aware filtering | Reject for this slice |
| Put native bookmarks in Swift preferences or a second database | Avoids a shared schema version | Splits storage authority and cannot atomically follow source switching | Reject |
| Add one native table in existing Room database | Reuses native coordinate validation, transactions and migration infrastructure | Adds a shared schema migration and explicit source-switch transfer | Recommend |

## Migration and recovery

Test the current 91-to-92 upgrade and supported earlier migration chains. Seed fixtures with shelf groups, reading positions, legacy bookmarks and unrelated records, then verify their values after migration and restart. Keep the existing failure, count and skip gates.

A schema upgrade makes rollback a data decision. An old schema-91 binary cannot be assumed to open a schema-92 database. Prefer a forward repair. Before a rollout involving persistent user data, create and verify a consistent database snapshot through a supported closed-database or SQLite backup procedure. Retain the newer database if restoring the snapshot is later authorized. Snapshot restoration restores the earlier state, so later bookmarks and reading changes require preservation or explicit loss approval.

Demonstrate the recovery procedure on disposable fixtures. Code reversal alone does not establish data recovery. Risk remains Unknown / Branch until those tests pass. The shared Room schema also affects other configured database consumers and needs the applicable compilation and migration checks.

## Required acceptance

- Exact isolation for same-title books, unknown authors, distinct source entries and distinct chapter URLs.
- Original Chinese, Latin, emoji, CRLF and paragraph-boundary coordinates in both layouts.
- Duplicate add, repeated delete, write failure, lost acknowledgment retry and stale reading tokens.
- Relaunch durability and explicit navigation through the existing save-failure flow.
- Shelf removal/re-admission, group changes, source switch success and transactional rollback with retained bookmarks.
- Changed or missing body and chapter handling without replacing the currently readable session.
- Schema-91 and supported earlier fixture migration, preservation of legacy data, restart, and snapshot recovery.
- Actual simulator add/list/open/delete journeys, portrait/spread rotation, typography changes, native Copy and chapter-find regressions.
- Applicable C1 plus final independent Copilot Opus 5.5 review. Owner H2 and PR merge approval remain explicit delivery steps.

Issue 60's intermittent lock during native rollback-test setup remains a separate defect. Retain its atomicity assertions and investigate an observed recurrence rather than adding retries or longer deadlines to this feature.

## Owner decision requested

Approve the one-table schema-92 budget, four bridge operations, explicit shelf admission before saving, and retention of original-source anchors across source switching. After approval, record the H1 contract in an implementation Issue and implement on the isolated bookmark branch.
