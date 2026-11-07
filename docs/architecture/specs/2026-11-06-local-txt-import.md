# Single UTF-8 TXT import

H1 approved by Lei on 2026-11-06: implement the characterized minimum TXT adapter, preserve duplicate-import progress/bookmarks, validate offline relaunch, run simulator and CI, and obtain Gemini 4 review before owner acceptance. H2 and explicit PR merge approval remain pending.

Accept one UTF-8 TXT (optional BOM), at most 10 MiB. Copy through scoped picker access into app-owned staging; keep the user's original. Identify immutable copies by SHA-256 bytes under books/native-txt/<digest>/book.txt. Same bytes reuse the original metadata/catalog/reading records. Different bytes remain distinct even with the same name. Do not use online title/author merging for local admission.

Reuse upstream TextFile parsing at integrated revision d31c0a270e7c8610e9679dbbda5a6bee06927952. Preserve the first original filename for stable upstream chapter IDs. Reuse existing Book, BookChapter, native_reading_resume and native_bookmarks. No tables, fields, migrations, dependencies, preferences or background tasks. Bound native local admission to app-owned TXT identities; preserve online source guards. Publish parsed catalog and book in one Room transaction only after a verified immutable file exists. Failed imports cannot change admitted books. A crash orphan may be reused on a later explicit import.

Use existing body cache verification, tokens, body hashes and UTF-16 paragraph anchors. Local cache misses read the immutable file without network fallback. Missing/corrupt data must not replace saved anchors. Network update/source switching/download actions are not available for local books. No EPUB, PDF, archives, scanning, synchronization or overwrite refresh.

Acceptance: actual picker import; duplicate import with unchanged position/bookmark; same-name different-content isolation; invalid/oversize/cancelled input; app termination/relaunch offline; saved paragraph and bookmark navigation; existing online regressions. Run required C1 and Gemini 4 review on the final candidate. Simulator fixtures do not prove real-device comfort or every document provider.

Recovery: no schema migration; prior builds retain but exclude new local rows. User copies and reading records must be retained on code rollback. Test transaction rollback and import cleanup. Do not delete source files or admitted copies as task cleanup. Characterization receipts remain in docs/evidence/local-txt-assessment-2026-11-06.

Owner approved the review repairs on 2026-11-06, including identity separation. Persist native-txt://<sha256>/book.txt in existing identity fields. Resolve the current app Documents root only through an engine-local locator adapter. Preserve upstream parser and other locator behavior. Test relocation of the database and owned files, successful duplicate completion, and cleanup that retains files when database admission is uncertain. No schema change or overwrite recovery is authorized.
