## Problem Statement

The native iPad reader already supports finding books, selecting source entries, trial reading, explicit shelf admission and durable resume. Its shelf is a flat text list with single-book removal. Readers cannot organize books into their own groups or switch between a cover grid and a list.

The desired outcome is an everyday novel bookshelf, not the upstream application's broad management console. Organization must preserve book identity, active source, reading position and cached content. The same book appearing in two groups must not become two independent books.

## Solution

Make the shelf the reader's home. Show named group entries alongside ungrouped shelf entries. Open a group to see its books; return to the shelf home to choose another group or ungrouped book. A book may belong to multiple flat groups, but groups never contain groups.

Preserve the complete existing journey: launch into the shelf, search by title or author, inspect source candidates, trial-read without adding, explicitly add to the shelf, read and return, and reopen later at the saved reading position. Newly admitted books appear ungrouped.

Offer a group checklist from each book's context menu, a direct remove-from-this-group action inside groups, basic book multi-selection with select-all, and both cover-grid and list views. Distinguish removal from one group, deletion of a group and removal of a book from the shelf. Shelf removal retains the reading record; explicit re-admission starts ungrouped with the retained record.

## User Stories

1. As a reader, I want the app to open to my shelf, so that I can find books I have chosen to keep.
2. As a new reader, I want an understandable empty shelf and an action to find books, so that I can start without importing shelf data.
3. As a reader, I want to search by title or author, so that I can find a work I want to read.
4. As a reader, I want to inspect a work's source candidates, so that I can choose the source entry I will read.
5. As a reader, I want to inspect details and trial-read without adding to the shelf, so that browsing does not automatically become collecting.
6. As a reader, I want explicit shelf admission, so that I control which books remain on my home.
7. As a reader, I want a newly admitted book to appear ungrouped, so that I can keep it immediately and organize it later.
8. As a reader, I want duplicate admission of an already kept book to preserve its source, progress and memberships, so that finding it again does not reset my organization.
9. As a reader, I want ungrouped books and group entries together on home, so that organized books have a clear place without being repeated outside their groups.
10. As a reader, I want to create a named group, so that I can organize books for purposes such as saving them for later reading.
11. As a reader, I want to rename a group without changing its contents, so that I can refine my organization.
12. As a reader, I want to open a group and return home, so that I can navigate a simple one-level shelf.
13. As a reader, I want one book to belong to several groups, so that I can organize it by more than one purpose.
14. As a reader, I want every appearance of a book to share its active source and reading position, so that groups do not create separate reading histories.
15. As a reader, I want a checklist showing a book's memberships, so that I can see and change its organization in one place.
16. As a reader, I want to cancel group editing without changes, so that I can inspect memberships safely.
17. As a reader, I want to remove a book from the current group directly, so that I can tidy that group without removing the book from my shelf.
18. As a reader, I want a book removed from its last group to return to home as ungrouped, so that it remains easy to find.
19. As a reader, I want deletion of a group to preserve all its books and reading records, so that removing an organizational container does not remove my collection.
20. As a reader, I want books belonging to other groups to remain there after group deletion, so that unrelated organization is preserved.
21. As a reader, I want removal from the shelf to remove a book from home and every group, so that I can stop keeping it through one explicit action.
22. As a reader, I want shelf removal to retain the reading record and leave cached content alone, so that cancellation of collection is distinct from clearing local book data.
23. As a reader, I want trial reading after shelf removal to leave the book off the shelf, so that opening it does not silently restore collection.
24. As a reader, I want explicit re-admission to retain the reading record and start ungrouped, so that old organizational choices are not restored unexpectedly.
25. As a reader, I want to select several visible books and select all visible books, so that I can organize a collection without repeating each action individually.
26. As a reader, I want batch group editing to preserve memberships I leave unchanged, so that unrelated memberships are not accidentally erased.
27. As a reader, I want batch removal from the current group or shelf to have a clear scope, so that I understand exactly which books and relationships are affected.
28. As a reader, I want both a cover grid and an informative list, so that I can browse visually or scan reading information.
29. As a reader, I want the view choice to survive relaunch, so that I do not need to reset it on each visit.
30. As a reader, I want missing or failed cover images to leave the book usable with a readable placeholder, so that an image failure does not prevent reading.
31. As a reader, I want groups, memberships and reading records to survive relaunch, so that my shelf remains useful across sessions.
32. As a reader, I want shelf organization to work without network access, so that collection management does not depend on source availability.
33. As a reader, I want a failed save to preserve the previous committed shelf and offer a useful error, so that a transient failure does not silently damage my organization.
34. As a reader, I want a clear capacity message when no valid custom-group slot remains, so that the app does not create a group it cannot display correctly.

## Implementation Decisions

- Follow the accepted native-experience, engine-boundary and shelf-group-storage decisions and the domain glossary. Swift owns presentation; existing KMP/Room storage remains authoritative for books, groups and reading records. Do not introduce a second shelf store.
- Reuse existing book-group records and the book membership mask. There are zero new database tables, zero schema migrations, zero new third-party dependencies and no source-rule/parser/runtime redesign in this slice. Narrow shelf/group exports, snapshots and guarded native persistence operations are allowed.
- Support at most 63 custom groups using positive single-bit identifiers. Validate allocation and exhaustion inside the write boundary. Never allocate zero or the sign bit, reuse an occupied identifier, or depend only on the upstream nominal count check. Free a deleted group's membership bits before safely reusing its identifier.
- Home presents all user-created group entries, including empty groups, followed by ungrouped shelf entries. Do not expose upstream special-purpose groups such as all media or update errors as additional product features. Books already in a group are represented through their groups rather than repeated ungrouped on home.
- Shelf membership and group membership are distinct. Removing from a group changes only that relationship. Deleting a group removes the group and its memberships, preserving shelf membership, other groups, active sources, reading records and cached content. Removing from the shelf ends all group memberships and shelf visibility while preserving book data needed for reading recovery.
- Explicit re-admission of a removed book starts ungrouped and retains the existing identity/source/resume policy. Duplicate admission of a book already on the shelf is non-destructive and preserves its groups. Fresh admission must not inherit unrelated group bits from source metadata.
- Add narrow operations for reading a coherent shelf/group snapshot, group creation/rename/deletion, membership editing and single/batch shelf removal. Keep source-entry identity checks, stale-request handling and typed storage failures at the existing engine boundary. A URL or stale UI row alone is not authority to change another book.
- Apply membership changes by targeted field updates rather than writing stale whole-book snapshots. Each accepted group deletion or batch mutation commits atomically, including membership cleanup. Validate all targeted current shelf entries and groups before applying the change; stale or invalid targets fail the entire command and trigger a refresh rather than silent partial success. Failed writes leave previously committed data intact.
- Prevent late results from a retired screen or request from overwriting newer state. A lost acknowledgement must be resolved by reloading committed state; creation must not be blindly retried in a way that creates duplicate groups. Reuse existing serialization/transaction boundaries where suitable and characterize their actual behavior.
- Provide a visible single-book action menu accessible without relying only on a long press. Group editing has Save and Cancel. Book actions inside a group distinguish Remove from this group from Remove from shelf; the latter applies to all appearances of that book and requires a clear confirmation. Group deletion confirms that books will be kept.
- Batch selection contains book entries, not group containers. Select-all means the books visible in the current home or group; on home it does not silently include books inside closed groups. Clear selection when changing location and after successful operations. On failure retain a valid selection for retry; do not silently expand it.
- For batch group editing, show all-selected, none-selected and mixed membership states. Untouched groups retain each book's existing membership; explicit add/remove applies that change to every selected book. This supplies precise behavior without converting all selected books to the same groups accidentally. Single-book editing remains a simple checklist.
- Conservative reversible defaults synthesized for implementation: trim group names, reject blank names and exact trimmed duplicates, preserve case for display, and allow rename without changing identity. Keep empty groups visible until explicitly deleted. Order groups by existing group order and books by the current recently-read policy with stable ties; do not add custom sorting controls in this slice.
- Implement both grid and list in the initial delivery. Default new installations to grid and persist the application-wide view choice using existing presentation preferences. Switching mode or rotating the iPad must preserve current group and reading state. The list exposes title, author and last-read chapter where available; grid exposes a cover and readable title. Group entries expose their name and book count.
- Use existing book cover metadata and existing supported image-loading behavior through a narrow export as needed. Cover failure or unsupported protected images show a stable placeholder, with no effect on reading or organization. Do not build a parallel source image-rule execution system. Group cover artwork, exact iconography, spacing and animation are reversible presentation choices rather than new acceptance gates.
- Opening and returning from a book preserves the selected group when it still exists. If that group is deleted, fall back to shelf home. Cold launch starts at shelf home. Renaming or reorganizing a book must not change its reading position.
- Group operations require no source network calls. Preserve current offline chapter reopening and current source-switch behavior, including retention of group membership for an explicitly switched, still-kept book.

## Testing Decisions

- The owner explicitly confirmed the test seams on 2026-10-24: real iPad-simulator UI journeys are the primary feature acceptance, complemented by the existing real storage/engine seams for saving failures, batch atomicity and the 63-group boundary. No new testing framework or parallel harness is planned.
- Test externally observable behavior: visible entries, group contents, saved reading position, committed storage after reopen, explicit error states and unchanged unrelated records. Do not make private helper calls, implementation-shaped mocks, screenshots alone or compile success stand in for behavior.
- Extend the existing NativeReaderUI XCUITest journeys and UI driver with controlled source fixtures. Prior art includes discovery-to-trial-to-shelf/relaunch and shelf-reading-recovery journeys. Inspect screenshots and test results for empty home, mixed home, a group, the membership checklist, multi-selection, both presentation modes and portrait/landscape layouts.
- Exercise a complete journey: empty shelf -> title/author finding -> candidate selection -> trial without admission -> explicit admission -> create groups -> assign a book to two groups -> reopen and read -> return -> relaunch. Assert one identity and preserved progress across group appearances. Reuse existing search/candidate fixtures rather than redesigning search.
- Exercise each removal distinction: remove from one of two groups; remove the last membership; delete a populated group; remove a selected book from the whole shelf; trial-read it without re-admission; explicitly re-add it ungrouped with retained progress. Verify unrelated books, memberships and cached content remain unchanged.
- Exercise multi-selection and select-all separately on home and inside a group, mixed-membership editing, cancel, confirmations and view switching. Verify closed-group books are never silently selected from home.
- Extend NativeShelf native integration coverage and the existing Swift engine/product suites at the public bridge and real Room boundary. Use JVM storage integration where already appropriate, but do not substitute it for Native storage execution. Verify allocation, valid positive bits, exactly 63 valid slots, exhaustion without mutation, deletion and safe ID reuse, invalid/stale inputs and duplicate admission.
- Inject meaningful storage failures using existing controlled seams or the smallest test-only boundary needed. Verify rollback of group deletion, shelf removal and batch membership writes, preservation of progress and active source, and coherent refresh after a lost acknowledgement. No fake transaction may certify real rollback behavior.
- Reuse existing process-restart and interruption drivers to verify committed group/membership state across restart and all-or-nothing interrupted mutations. Retain ordinary offline shelf reopening and protected resume evidence. Use only invocation-owned synthetic databases and simulators.
- Run the applicable full C1 workflow on the actual implementation revision and focused UI journeys chosen from the repository validation map. Record exact local, PR-head and merged-head results separately. Retain original-client compilation and relevant existing regression consumers because shared book/group storage is involved. Do not weaken tests, reporting or aggregate checks.
- Simulator and synthetic source results do not establish physical-device comfort, live community-source compatibility or the separate 14-day natural-use acceptance. Those obligations are not silently satisfied by this slice.

## Out of Scope

- Bookmarks, in-book text search and a new shelf search/filter interface.
- Nested groups, unlimited groups, independent tag systems, custom book/group sorting controls, invert-selection and interval-selection.
- Whole-book download queues, cache-management redesign, export, backup, synchronization and irreversible deletion of reading records or cached content.
- New source-management features, source-format changes, rule editing or a parallel source runtime. Existing source management and explicit source switching remain supported and independent.
- New comic, audio, video, RSS or browser capabilities. This slice serves the existing source-backed novel reader; comic support remains a separate decision.
- Broad upstream bug repair, dependency upgrades, schema/storage redesign, production data experiments, installation on the owner's iPad, signing, distribution and deployment.
- Complete Wanyuan feature parity or recreation of its private implementation. Reference screens inform selected interactions only.

## Further Notes

### H1 — owner-approved boundary

- **Outcome:** An everyday native iPad shelf with flat non-exclusive groups, coherent removal semantics, basic multi-selection and both grid/list views, protecting the already accepted finding/trial/admission/reading/resume journey.
- **Owner decisions:** Lei approved Q1 B and Q2 A; clarified and confirmed Q4-Q6; approved Q7-Q9, Q10 reuse/capacity, Q11-Q12 and Q13 C in this chat on 2026-10-24. Lei then explicitly requested synthesis with to-spec and approved the testing boundary. This is not PR merge authorization.
- **Delivery criteria:** All applicable user stories and the named main/failure/restart journeys above have revision-bound evidence. Both view modes ship together; group/shelf removal semantics are not interchangeable. Reversible defaults above are agent-synthesized details, not claims that the owner individually selected them.
- **Complexity budget:** Zero new schema structures/migrations and third-party dependencies. Reuse existing KMP group/book storage and native presentation preferences; permit narrow exports, targeted guarded writes and focused tests. Do not expand into unrelated shared consumers or core source execution.
- **Recovery:** Preserve product base, pre-change synthetic storage fixtures and a verified snapshot/restore experiment for changed fields. A code revert alone cannot restore cleared memberships or deleted groups. Keep recovery risk Unknown until the restoration experiment succeeds; do not use owner data. Explain limits of reconstructing organization after destructive user actions; book removal is not data erasure.
- **Implementation boundary:** This issue is ready to implement the accepted design within the stated budget after publication. It does not start an unattended continuous goal. New formats, wider shared-contract changes or recovery beyond the declared approach require owner reassessment.
- **Merge:** Lei's explicit approval for the resulting PR is required; spec approval, issue labels and green tests do not authorize merge.

### Current execution state

- Planning base: `3d62b46320c3aba7fd00635d8473804a2c028a3f`; integrated KMP upstream inspected: `d31c0a270e7c8610e9679dbbda5a6bee06927952`. Refresh product/branch/PR state before implementation; do not assume this remains the latest head.
- Source inspection establishes representation compatibility only. No bookshelf feature code, build, runtime characterization or tests were executed for this spec.
- Known gaps: native shelf snapshots/exports omit grouping; re-admission currently restores the shelf flag without clearing old group membership; upstream group deletion is multi-step without a transaction in its view model. These are implementation work, not evidence of completed behavior.
- Risk: Door Unknown until write/recovery experiments; Radius provisionally Branch because shared books/groups, native shelf/resume, source switching and original-client consumers require demonstrated containment.
- Implementation PR/base/head, independent reviewer and reviewed SHA, findings/dispositions, local and exact-head CI, validator changes, explicit merge approval, merge SHA and merged-head CI: pending. No validator changes are authorized merely to obtain a passing result.
- Preserve the primary checkout's unrelated untracked Xcode project and all existing owner resources. Do not switch, reset or clean the shared checkout to start this work. Transfer only the glossary/ADR material needed for the task into an owned implementation branch, making canonical decisions available in the resulting PR.

### H3 — exceptions

Stop affected work for an owner decision if schema, dependencies, supported media, shared-contract scope or recovery requirements expand; if review disagrees materially; if acceptance changes; or if two repair/review rounds fail to close findings. Present evidence and alternatives rather than widening this spec or weakening checks.

### H2 — owner understanding and value check

Pending implementation and Lei's assessment. Report delivery against H1, normal and failure/recovery journeys, cumulative persistent/shared changes, maintenance effort and manual interventions (unknown is not zero), independent review and exact-head validation. Lei decides continue, narrow or simplify. Do not close the issue until promised delivery, review dispositions, required checks, explicitly approved merge, merged-head follow-up and owner H2 are accounted for.
