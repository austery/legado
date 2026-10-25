# Native bookshelf UI implementation

Date: 2026-10-25. Parent #51; implementation ticket #53. Integration base refreshed through `4f427d6b63b7906a9ce28b58bebef480e30a9d17`.

## Behavior

The native shelf now shows one-level group entries with ungrouped books, persistent grid/list presentation, visible book/group menus, group create/rename/delete, token-captured membership editing, direct current-group removal and confirmed shelf removal. Basic book multi-selection/select-all is scoped to visible books; untouched mixed memberships retain each original relationship. Reader return preserves the chosen group, while deletion falls back to home. Missing/unsupported covers use a placeholder. No schema or dependency changed.

## TDD and executed evidence

- Preference tracer red: missing `shelfLayout` public member in `/private/tmp/bookshelf-ui-preferences-red.log`; actual green: five `ReadingPreferencesTests` passed, zero failures/skips, `/private/tmp/bookshelf-ui-preferences-run/summary.json`.
- Model group tracer red: missing public model group commands in `/private/tmp/bookshelf-ui-model-red.log`; actual green: one real engine/local Room group-create/rename/delete test passed in `/private/tmp/bookshelf-ui-local-groups-run/summary.json`.
- Membership tracer red: missing public membership command in `/private/tmp/bookshelf-ui-membership-red.log`; actual green: both `ShelfOrganizationTests` passed through the real engine and loopback source in `/private/tmp/bookshelf-ui-model-run/summary.json`. This covers one book in two groups, removal of one relationship, reader return and deletion returning the book ungrouped.
- Actual UI tracer red: `testShelfGroupingAndGridListManagement` failed at the missing `shelf.newGroup` control, `/private/tmp/bookshelf-ui-controls-red/summary.json`.
- First green attempt reached creation, membership, group entry, list and rotation, then exposed SwiftUI's nested accessibility nodes for one confirmation button. The query was disambiguated to the first matching node for that same control; the action and postconditions remain required.
- Actual UI green: that journey passed, one test, zero failures/skips, `/private/tmp/bookshelf-ui-controls-green2/summary.json`. It includes group creation and assignment, grid home, landscape group list, group deletion retaining the book and view-mode persistence after relaunch. Screenshots and `.xcresult` are retained under that output; earlier first-attempt grid/list screenshots were visually inspected for layout and controls.
- The UI driver now declares 18 methods instead of 17 by adding this journey; no existing suite or gate assertion was removed.
- After the passing UI run, a small followup adds an explicit Cancel/reopen prompt and disables Save when an editor's captured token no longer matches refreshed organization; it does not silently rebase a draft. Its `build-for-testing` check passed in `/private/tmp/bookshelf-ui-stale-prompt-build.log`; this is separate from the earlier UI runtime evidence. Final integrated behavior/CI and remaining #54 failure/batch/recovery coverage are pending.

## Resources

All created simulators were synthetic and removed by their invocation finally blocks: preference `F9C6DA78-4B3D-4E85-85CC-05020E9A10E8`; local group `8D656D4B-87E0-4DF1-B99C-E595A9A4D450`; model `DB029B63-98CB-404A-A2D8-E84EEF08FF6E`; UI red `88BDE506-811C-4163-982E-389640658752`; first green `7E81EA84-6B6C-42E2-B2A0-4D4511A89910`. Final green `8E076C00-5997-413E-B6B0-4859B3CA38DB` was also deleted by its driver. No owner simulator, app, source bundle, data or running service was modified.

Task worktree `/private/tmp/legado-bookshelf-ui-20261025`, branch `codex/bookshelf-ui`, remains active for integration. Build output and copied framework inside it are reproducible from the exact integration source; task-private logs, result bundles, screenshots and DerivedData live outside the worktree under `/private/tmp/bookshelf-ui-*`. Retain concise required evidence before reclaiming reproducible bulk outputs. Fixture servers are scoped to their context managers and no longer running after the completed tests.
