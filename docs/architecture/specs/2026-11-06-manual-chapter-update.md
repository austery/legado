# Single-book manual chapter update

## Approved scope

On 2026-11-06 the owner activated the bounded proposal as the thread goal. Check one admitted shelf book using its current source. Reuse WebBook catalog fetching and parsing. Accept only unchanged catalogs or a strict appended suffix. Reject renamed, reordered, removed or changed existing chapters and changed book identity. Do not add tables, migrations, dependencies, preferences or background work.

The owner approved implementation, not a PR merge. H2 and explicit merge approval remain pending.

## Preservation contract

Capture the source and stored catalog. Parse into a separate candidate. In the existing database transaction, recheck shelf membership, source configuration and the full old catalog. Insert only the suffix. Patch only catalog count and update summary metadata. Never replace the Book row or write native resume/bookmark rows. Reject malformed identities, duplicate URLs, invalid indexes and blank titles.

Once the write boundary starts, complete commit and engine publication even if foreground delivery is cancelled. Cancellation before that boundary must not commit. Return committed shelf/catalog snapshots in the same result. Preserve the displayed text and reading token. A stale foreground reply must not navigate the user.

No new chapters means no persisted write. Catalog changes and network failures retain the old catalog. Existing cache bodies and original-text hash guards remain unchanged. The action does not refresh existing chapter text, move to a new chapter or download new bodies.

## Reuse boundary

The integrated upstream pin is d31c0a270e7c8610e9679dbbda5a6bee06927952. Reuse WebBook.getChapterListAwait and its response policy. Do not call the complete UpdateBookShared updater: its Book replacement can cascade-delete native records and its legacy index handling does not protect native paragraph anchors. No core parser changes are part of this slice.

## Validation and recovery

Required evidence includes real Room append/rejection and rollback tests, WebBook fixture checks, public bookmark navigation, nonzero paragraph preservation, an actual shelf-menu update and restart, ordinary product regression, C1 and independent review. Synthetic fixtures do not establish physical-device comfort or live-site compatibility.

There is no format change to reverse. Keep the last accepted source and synthetic rollback receipts. Test databases are disposable fixtures; do not test recovery on user data. A code revert alone does not prove all data recovery.

Current evidence and review dispositions are retained in the task's local chapter-update-characterization-2026-11-06 evidence directory. Final publication must report the tested and reviewed candidate, remaining limits and separate owner acceptance.
