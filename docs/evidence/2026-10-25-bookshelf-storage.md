# Bookshelf storage and engine boundary evidence

Date: 2026-10-25. Parent specification: [Issue #51](https://github.com/austery/legado/issues/51); implementation ticket: [#52](https://github.com/austery/legado/issues/52). This record is intermediate implementation evidence, not merge or owner H2 acceptance.

## Implementation boundary

The native shelf reuses existing book-group records and book membership bits. Its coherent organization snapshot and targeted operations support creation, rename, deletion, mixed-membership edits and batch shelf removal. Group deletion and batch writes run within real Room transactions. Fresh admission ignores incoming group metadata; removal and re-admission clear memberships while duplicate admission of a still-kept book preserves them. Reading records, chapter catalogs and cached content are retained.

ReaderEngine exports immutable group/book snapshots, decimal-string group identifiers, public book targets and typed errors. Organization tokens compare current group and membership state, excluding reading progress. They are state preconditions, not persistent historical group revisions: an identical empty organization recreated with identical IDs/names/order has the same token. Changes to members or group metadata invalidate the precondition. Safe ID reuse clears old membership bits rather than reattaching books to a replacement group. No epoch, new schema, dependency or parallel storage was introduced.

## Executed evidence

- TDD tracer: fresh admission initially failed because source group bits were retained (`expected 0`, `actual 7`); clearing incoming bits passed the same test.
- Group creation, membership editing, rename/deletion and batch removal each began with a missing-public-operation failing tracer, followed by successful real Room behavior tests.
- Foundation `d22fa1bf6933a1fc7bd91bf012b1b028cb201918`: NativeShelf JVM15 tests passed, no failures/errors/skips; actual iOS Simulator ReaderEngine framework linked successfully and generated Swift signatures were inspected.
- Subsequent JVM16 shelf tests passed, no failures/errors/skips. Coverage includes capacity63, slot reuse, trimmed/duplicate names, partial-batch failure rollback, group-deletion rollback, invalid targets, stale state, reading progress independence, preserved catalog and re-admission.
- Kotlin/Native driver passed data79/core8/engine44 (131 total), with no missing/failed/skipped reports. This included nine new Native shelf cases and the existing source-switch test updated to set memberships through the actual group API. A tenth Native safe-ID-reuse case was subsequently added and remains pending the final integrated Native run; do not transfer the131 result to that later test tree.
- The first Swift product run exposed malformed group IDs incorrectly returning STORAGE instead of INVALID_INPUT. The normal group lifecycle test passed. The parser was corrected to retain the existing typed shelf invalid-input failure.
- After relinking that correction, the complete ordinary Swift product suite passed82/82, with zero failures or skips. Both new public ReaderEngine tests passed: full grouping/removal/re-admission/resume lifecycle, and invalid group/batch targets preserving committed state.
- Process-interruption/offline-restart suites were not executed by this ordinary product invocation and remain part of integrated validation. No physical-device or live-source acceptance is claimed.

## Reproduction and retained diagnostics

The task used the repository Gradle wrapper with existing Java21 and Java17 toolchains, existing Android SDK, Xcode27/iOS27 Simulator, XcodeGen and existing dependency caches. No system installation or global configuration was changed.

- Focused JVM command: `:data:jvmTest --tests '*NativeShelfIntegrationTest'`; final log `/private/tmp/bookshelf-storage-final-jvm.log`.
- Native framework command: `:engine-ios:linkDebugFrameworkIosSimulatorArm64`; logs `/private/tmp/bookshelf-storage-bridge-build.log` and `/private/tmp/bookshelf-storage-bridge-parser-green.log`.
- Native driver: `python3 scripts/path-c/kotlin_native_ci.py --output /private/tmp/bookshelf-storage-native-20261025`; summaries, failure report and test log retained there.
- Ordinary Swift driver: `python3 scripts/path-c/native_product_ci.py --output /private/tmp/bookshelf-storage-product-green-20261025`; result bundle, summary and logs retained there. Failed first run retained at `/private/tmp/bookshelf-storage-product-20261025`.
- Task-only command wrapper and tracer logs are `/private/tmp/legado-bookshelf-storage-test.sh` and `/private/tmp/bookshelf-storage-*.log`. They contain toolchain locations and commands, not credentials.

Root integration owns the final evidence export and retention decision before reclaiming large run outputs.

## Resources and handoff

The storage child checkout is `/private/tmp/legado-bookshelf-storage-20261025`, branch `codex/bookshelf-storage`. Generated Gradle/Kotlin/Xcode products inside it are reproducible; retain only required evidence before Git worktree removal. Copied native C libraries came from the integration task's successful unchanged-source build and remain disposable build inputs.

The drivers created and deleted their own simulators: Kotlin Native `1922DC5F-6950-4487-9E41-F8927487C13E`; failed Swift run `8AC665D5-BA38-4E6B-9178-592AEECAAD74`; successful Swift run `B13D5CCA-12E9-4CD0-B687-35456D403734`. No owner simulator, app or data was changed. Fixture listeners ended with their driver contexts. The ordinary external dependency caches and root integration workspace are retained, not child cleanup targets.
