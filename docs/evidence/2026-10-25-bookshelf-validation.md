# Bookshelf user journeys and recovery evidence

Date: 2026-10-25. Parent specification: [Issue #51](https://github.com/austery/legado/issues/51); validation ticket: [Issue #54](https://github.com/austery/legado/issues/54).

## Source and boundary

Production-source candidate: `703697c28b015a3e54699488af9ba60b7e17af86`, including process integration `deb8fc5d44003bd353b7682171ba480f79cfe3a9`. The simulator framework has unchanged Kotlin production provenance `86184361379469df1cc4c2fa4e9cd4b8b1623de7`; integrated Native coverage is recorded separately. Tests use iOS 27.0, Xcode 27.1, invocation-owned iPad simulators and controlled loopback sources. No physical iPad, owner database, live community source, source format or schema was changed.

The sole production change in this validation slice clears obsolete shelf success notices after a successful organization mutation. An actual UI test demonstrated that the previous admission/save notice remained after removal; clearing it does not clear failure feedback or selection on failure.

## Executed tracer evidence

| Evidence | Observed result | Retained output |
| --- | --- | --- |
| Mixed shelf UI | Two distinct books and two groups; home select-all excludes closed-group books; cancelled editing preserves membership; untouched mixed batch membership remains per-book; last-group removal returns a book home; shelf removal clears both group appearances; grid/list/rotation and relaunch exercised. Passed one actual UI test. | `/private/tmp/bookshelf-validation-mixed-green` |
| Failure and stale-editor UI | Real SQLite update rejection preserves the draft and two-book selection; real second-engine rename makes the old editor stale; Save disables with explicit Cancel/reopen guidance; reopening shows current metadata and succeeds. Passed one actual UI test. | `/private/tmp/bookshelf-validation-failure-green` |
| Empty-home finding and collection journey | Actual author query, candidate selection, trial without admission, explicit admission, Chapter 2 reading/save, removal, empty relaunch, trial of the removed book without automatic admission and explicit re-admission retaining Chapter 2. The stale-notice assertion failed before the narrow fix and passed afterward. | `/private/tmp/bookshelf-validation-empty-red`, `/private/tmp/bookshelf-validation-empty-green` |
| Lost acknowledgement and stale model command | A real committed group-create reply is withheld by the existing reply-delivery seam; cancel/refresh observes exactly one group and no create retry. A second engine renames the group; the stale command cannot overwrite it and the model refreshes. Passed one selected public-model test, with no network or fixture listener. | `/private/tmp/bookshelf-validation-lostack` |
| Actual SQLite snapshot/restore | Backed up the synthetic database using SQLite's backup API, then changed reading progress, deleted the group and removed the book. Restoring the backup recovered the organization token, group/name, membership, active source and a nonzero Chapter 2 paragraph; reopening used verified cached content. Passed one selected public-model test. | `/private/tmp/bookshelf-validation-snapshot-wal` |

The initial mixed/failure UI tracer failures identified missing fixture support, not product defects. Initial snapshot setup used the wrong chapter marker, then exposed WAL snapshot reopening with a read-only handle. The final experiment uses the controlled long-chapter paragraph marker and a writable handle to the invocation-owned snapshot so SQLite can create its WAL sidecars. Missing markers are guarded, snapshot sidecars are removed and failures remain failures. No application storage configuration was changed to make the experiment pass.

## Validation changes

The UI driver's declared inventory grows from 18 to 21 methods, adding three complementary journeys. Expected count and explicit allowlist enumerate every declared method; selection remains constrained to distinct declared methods. No existing journey, assertion, skip detection, deadline or aggregate gate was removed or weakened. The actual UI host alone gains `shelf-mixed` and `shelf-empty` setup plus controlled SQLite-rejection and second-engine-writer controls. Its relaunch path preserves an empty shelf instead of silently admitting a fixture book again.

The two added ordinary model tests use existing real engine/storage and reply-delivery seams. The focused temporary runner invokes one named XCTest through the generated test host, uses the existing strict summary validator with an expected selected count of one, and records its command/source patch. It does not alter repository suite discovery or substitute for final full C1.

## Recovery limits

The successful restore is evidence for a controlled same-format synthetic database snapshot with unchanged external chapter-cache files. It is not automatic undo for user actions, a production backup product, complete filesystem recovery, reverse migration, arbitrary old-binary compatibility or proof that a code revert restores organization. A real recovery would require an appropriate verified snapshot and compatible associated files. Group removals continue to preserve reading records and cached content as specified.

## Final selected regression

The seven-method run at `703697c28b015a3e54699488af9ba60b7e17af86` completed with six passes and one failure (`/private/tmp/bookshelf-validation-final-ui`). All four shelf journeys, shelf reading/recovery/resume and explicit source-switch/relaunch passed on the final production source. The existing discovery journey failed waiting for the discovery-page title after relaunch. Its retained accessibility hierarchy shows the exact admitted book on the shelf with canonical detail metadata: `discovery_fixture.py` advertises `Discovery first`, while `fixture_server.py` serves `Path C Book` for that same book ID. Test-only commit `62311c743` captures the discovered ID and asserts that exact shelf identity after relaunch; it changes no product behavior. Its focused rerun passed one actual UI test with zero skips/failures at `/private/tmp/bookshelf-validation-discovery-identity` on immutable test commit `62311c743`. Thus seven distinct selected journeys have passing evidence: six unchanged methods in the seven-method bundle and the corrected discovery method in its focused run. The aggregate seven-method bundle itself remains a recorded failed run; it is not relabeled green.

Fresh final-source attachments are retained under `/private/tmp/bookshelf-validation-final-ui/screenshots/manifest.json`, including `shelf-mixed-home-grid`, `shelf-mixed-membership-checklist`, `shelf-mixed-home-list-after-removal`, `shelf-group-list-landscape`, `shelf-membership-save-failure`, `shelf-stale-editor-review-required`, empty home and retained-chapter re-admission. Direct inspection found the mixed home, checklist and stale-editor guidance readable without clipping.

Full ordinary Swift, exact final-head C1, independent review and owner H2 remain separate follow-up gates owned by the integrating agent.

## Resources

Every test uses a newly created simulator and deletes only that UUID in `finally`. Logs, summaries, result bundles, command records and screenshots are outside the disposable child worktree under `/private/tmp/bookshelf-validation-*`. The temporary targeted runner is `/private/tmp/bookshelf-validation-target.py`; it is not product code. Build products are reproducible from the recorded candidate and existing project generators. All 12 recorded invocation-owned simulator UUIDs were verified absent after the last run. The fixture/heavy lane was released after completion. The integration agent owns final evidence retention and child-worktree cleanup. Owner devices, shared caches and running services are preserved.
