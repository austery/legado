---
specId: SPEC-005
title: Explicit Active-Book Source Switching
status: Ready for Implementation
priority: P1 - Core Feature
creationDate: 2026-10-20
lastUpdateDate: 2026-10-20
owner: User (AI-Assisted)
relatedSpecs:
  - PLAN-005
  - SPEC-004
  - ADR-002
tags:
  - native-reader
  - source-switching
  - reading-position
---

# SPEC-005: Explicit Active-Book Source Switching

## 1. Goal

Let readers recover from an unavailable or unsuitable source without silently changing their shelf identity or misrepresenting their reading position.

## 2. Background

PLAN-005's first delivery merged through PR #30 at `61e0393071c9af0e329af2746bf46a6b0290be9d`. Its next slice is explicit source switching.

The native engine currently supports search, preview, shelf admission, and durable resume. `NativeShelfDao.addToShelf` intentionally reuses an existing unambiguous known-title/author entry, preserving its active source. Repeating admission therefore cannot implement switching. `BookDao.replace` deletes and inserts a book, but does not establish the native catalog/resume/revision contract required here. Neither operation should be exposed as a complete switch.

The Swift UI remains a client of the KMP engine. Room remains the book, catalog, and resume authority. Global presentation preferences remain unchanged. ADR-002 requires a specific owner decision before changing source equivalence or reading-position interpretation.

## 3. Proposed Design Decision

**Owner-approved approach:** prepare a replacement chapter before an explicit commit; recommend only an unambiguous matching chapter and start the replacement at its beginning.

### User journey

1. Offer Change source for a shelved book from its details and reader controls.
2. Reuse incremental multi-source search. For this slice, eligible replacements require equal trimmed, nonblank title and author; the active listing is identified and cannot be selected as its own replacement. Missing or different authors do not establish equivalence.
3. Selecting a candidate loads its details and catalog without altering the shelf. Recommend a chapter only when its trimmed title uniquely matches the current chapter title in the replacement catalog. Do not remove numbers or punctuation or use chapter index as an automatic fallback.
4. With no unique match, require manual chapter selection. Always allow the reader to choose another chapter.
5. Load and verify the selected chapter body before enabling final confirmation. Show both sources and the replacement chapter, with a clear notice that reading will start at the beginning of that chapter.
6. Commit only on explicit confirmation. Cancellation, search failures, unavailable chapters, and preparation failures preserve the old active source and resume.

The old reader remains recoverable throughout preparation. Flush pending reading progress before capturing the switch's expected state. If saving fails, retain the existing retry/discard decision; do not silently discard progress to continue switching. Changes after preparation make confirmation stale and require preparation again.

### Persistence and concurrency

- Add an engine-owned prepared-switch token bound to the current shelf identity, old source, resume revision, shared progress projection, target catalog, selected chapter, and verified body fingerprint.
- Keep preparation separate from durable shelf admission. Prepared content may populate a verified cache but must not create another shelf entry.
- Commit replacement book identity, catalog, and native resume in one Room transaction. Preserve existing user-owned shelf metadata; take source-owned metadata from the replacement. Explicitly enumerate the field ownership during implementation and review.
- Validate the expected old source, revision, shared projection, candidate identity, target source availability, and target URL conflicts at commit. Reject stale or conflicting requests without partial mutation.
- Replace the old active database record rather than keeping two equal known-title/author records that would make existing admission ambiguous. Retire the old catalog/resume as part of the transaction. Keep unrelated records and user-owned associations intact; audit their URL references before implementation. Any required schema migration or unsupported association transfer is a separate design checkpoint.
- Create a valid native resume for the selected replacement chapter at offset zero, using its actual body hash and coordinate version. Never copy character offsets, percentages, or paragraph numbers between sources.
- Invalidate old reading-session tokens after successful commit. Old tokens must also fail persistent identity/revision checks if invalidation is interrupted.
- If acknowledgment is lost after commit, resolve the durable active entry before reporting success or failure. Never promise that the old source survived an already committed replacement.
- A subsequent reverse switch uses the same explicit chapter selection contract. Automatic restoration of a historical per-source paragraph is outside this slice.

| Alternative | Benefit | Limitation | Proposed disposition |
| --- | --- | --- | --- |
| Prepare, confirm, and begin selected chapter | Predictable position with recoverable failures | Reader may reread part of a chapter | Recommended |
| Copy chapter index and character offset | Fewer interactions | Different catalogs and bodies make the position misleading | Reject |
| Fuzzy text alignment across sources | Potentially closer resume | Requires a separate confidence and ambiguity contract | Defer |
| Reuse ordinary shelf admission or raw book replacement | Small implementation | Does not satisfy source/catalog/resume atomicity | Reject |

## 4. Implementation Phases

### Phase 1: Engine transaction

- [ ] Audit book-key references and field ownership, including existing shared consumers.
- [ ] Add typed preparation, confirmation, cancellation, stale-state, and recovery results.
- [ ] Implement guarded atomic replacement and invalidate superseded reading sessions.
- [ ] Test public engine behavior for successful replacement, conflicts, cancellation, and transaction rollback.

**Acceptance:** reopening observes either a coherent old entry or a coherent replacement, never mixed source/catalog/resume state.

### Phase 2: Native interaction

- [ ] Add source selection, matching/manual chapter selection, preparation, and confirmation UI.
- [ ] Retain readable old content and actionable errors until commit succeeds.
- [ ] Refresh details, shelf, catalog, and reader from the committed engine result.

**Acceptance:** a reader can complete or cancel the journey without hidden source changes or misleading position claims.

### Phase 3: Simulator and delivery

- [ ] Exercise real Swift/KMP flows with controlled synthetic sources.
- [ ] Verify relaunch, interruption, stale tokens, and error recovery.
- [ ] Inspect portrait and landscape screenshots.
- [ ] Run focused regressions and required repository checks on the final revision.
- [ ] Publish reviewed implementation and exact-revision evidence.

## 5. Acceptance Criteria

- [ ] Unique chapter-title match is recommended; duplicate/missing matches require explicit selection.
- [ ] Different/missing author and target URL conflicts cannot silently replace an entry.
- [ ] Preparation and cancellation leave the old shelf/catalog/resume unchanged.
- [ ] Failed body loading or cache verification cannot commit a replacement.
- [ ] Concurrent progress changes, removal, or another switch reject a stale token.
- [ ] Successful commit leaves one active shelf entry, coherent target catalog/resume, and preserved user metadata.
- [ ] The replacement opens at chapter offset zero and survives process relaunch.
- [ ] Old reading tokens cannot overwrite replacement progress.
- [ ] Controlled interruption before commit preserves the old entry; interruption after commit recovers the replacement despite lost acknowledgment.
- [ ] Existing admission, preview isolation, removal, resume, and global preference behaviors remain covered.
- [ ] Simulator evidence is reported separately from physical-device acceptance.

Whole-book downloads, fuzzy body alignment, missing-author equivalence, source history, discovery, and a storage redesign are excluded.

## 6. Status History

| Date | Status | Note |
| --- | --- | --- |
| 2026-10-20 | Draft | Prepared after PR #30 merge; source equivalence and chapter-start policy await owner confirmation. |
| 2026-10-20 | Ready for Implementation | Owner approved the proposed switching rules, simulator implementation and acceptance, and continuous goal execution. |

## 7. Related

- [Feature expansion](PLAN-005-native-ui-feature-expansion.md)
- [Search and candidates](SPEC-004-multi-source-search-and-candidates.md)
- Engine: `engine-ios/src/iosMain/kotlin/io/legado/engine/ReaderEngine.kt`
- Shelf authority: `data/src/commonMain/kotlin/io/legado/app/data/dao/NativeShelfDao.kt`
- Resume authority: `data/src/commonMain/kotlin/io/legado/app/data/dao/NativeResumeDao.kt`
- Existing shared replacement: `data/src/commonMain/kotlin/io/legado/app/data/dao/BookDao.kt`
