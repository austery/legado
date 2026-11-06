# Upstream shelf sorting assessment

Date 2026-11-04, America/Toronto.

Status — implementation H1 recorded on 2026-11-05. After reviewing the inventory and simulator evidence, the owner requested merging the validation slice and continuing gradual upstream UI integration. The first bounded integration is the six-mode shelf sorting proposal below. Product H2 remains pending.

## Fixed source and evidence

Product source is `02ce73b495f95efab461aa2e304739e0ebaf2377`. Its tree equals merged PR #62 at `244d0b91826b5d7c946e7a3746b3facdce38964b`. Investigation branch is `codex/upstream-shelf-sort-assessment`.

Integrated KMP upstream is `d31c0a270e7c8610e9679dbbda5a6bee06927952`. Remote master was checked with `git ls-remote` and is `83657e54829b7603aa392bf072283805769ad385`. The sorter, group fallback, Native comparator, iOS preference provider and Native configuration accessor have no diff between these upstream revisions. Tests execute the vendored implementation in the current product tree. No upstream upgrade was performed.

## Existing implementation

| Concern | Existing source | Observed contract |
| --- | --- | --- |
| Sort modes | `ui/src/commonMain/kotlin/io/legado/app/ui/bookshelf/BookshelfViewModel.kt`, `sortBooks` | 0 descending read time, 1 descending known chapter-update time, 2 Chinese title order, 3 ascending stored `Book.order`, 4 descending maximum of read/update time, 5 Chinese author order. Other values use mode 0. |
| Group override | `data/src/commonMain/kotlin/io/legado/app/data/entities/BookGroupExtensions.kt`, `getRealBookSort` | Negative `bookSort` inherits global mode. Nonnegative values override it. |
| Global persistence | `ui/src/sharedUiMain/kotlin/io/legado/app/ui/config/BookshelfNavConfigDialogs.kt` | Writes existing `PreferKey.bookshelfSort` through `PreferenceProviders`, then requests a refresh. |
| Native persistence | `core/src/iosMain/kotlin/io/legado/app/help/config/IosPreferenceProvider.kt` and `core/src/nativeMain/kotlin/io/legado/app/help/config/NativeAppConfigAccessor.native.kt` | NSUserDefaults stores the existing key. Provider change notifications refresh cached configuration. EngineHost already registers both providers. |
| Native Chinese comparison | `foundation/src/nativeMain/kotlin/io/legado/app/utils/StringCnCompare.native.kt` | Existing pinyin table, with code-point fallback. Digits are lexical. Homophones and polyphonic characters have documented differences from JVM ICU collation. |
| Native membership | `data/src/commonMain/kotlin/io/legado/app/data/dao/NativeShelfDao.kt`, `organization` and `listBooks` | Exact native shelf scope and guarded membership mutations. Initial order is descending read time, then book URL. |
| Native projection | `native-ios-app/Sources/ReaderModel.swift`, `visibleShelfBooks` | Home shows ungrouped books. A group shows its members. The same book can appear in several groups. |

The upstream ViewModel also owns database subscriptions, automatic group selection and chapter-update scheduling. Reusing the entire ViewModel would change more than sorting. Its DAO includes local and other book types that the native reader does not currently admit. Keep native membership authority and reuse the existing pure ordering logic.

## Executed characterization

The following initial results belong to snapshot `38046704e936a31e9666a9be5df1aeab958b1ec8` (tree-equivalent to `bd023f833`).

Added `UpstreamShelfSortCharacterizationTest` under `ui/src/jvmTest` and `UpstreamShelfSortNativeTest` under `core/src/iosSimulatorArm64Test`.

- JVM targeted run passed 3 tests with zero failures, errors or skips. It uses real Room and SQLite through public `setBookshelfActive`, `selectGroup` and `upSort` calls. Only configuration values are supplied by a fixture.
- Cases cover all six modes with explicit expected book IDs, invalid-mode fallback, distinct same-title books, retained progress, group override and inheritance, and stored books/groups after closing and reopening the database.
- Native canonical driver passed data 84, core 10 and engine 44 tests, totaling 138. The two new core tests cover actual Native Chinese comparison and the existing iOS preference key.
- Native preference tests use an isolated NSUserDefaults suite. Each of modes 0 through 5 refreshes the existing configuration accessor and survives recreation of the preference provider. The suite is removed in cleanup.
- Preference-provider recreation and database reopening were tested within their test processes. A complete app process relaunch and actual Swift sorting controls remain untested. No physical-device claim is made.
- Equal-title identity retention was tested. Cross-process tie-order equivalence between the upstream DAO and native DAO was not established. The proposed extraction keeps stable sorting over each caller's existing input order.

Commands use the repository wrapper and existing runner JDK 21, JDK 17, Android SDK, Gradle/Konan caches and Xcode. No toolchain configuration was changed.

```sh
./gradlew :ui:jvmTest --tests '*UpstreamShelfSortCharacterizationTest'
python3 scripts/path-c/kotlin_native_ci.py --output /private/tmp/legado-shelf-sort-native-20261104
```

Exact environment, commands, source hashes, XML reports and logs are retained in `/Users/leipeng/Documents/Codex/legado-shelf-sort-assessment-20261104`.

The original test snapshot is local commit `38046704e936a31e9666a9be5df1aeab958b1ec8`, tree-equivalent to `bd023f833` after rebasing this validation slice onto merged PR #62. The two-page receipt refers to that same original snapshot. Review follow-up commit `0753107b393b8daf00320d5693e1408e241ff213` was tested separately. Its revised JVM suite passed 3 tests, including six distinct sort permutations and published progress assertions. Its Native driver passed data 84, core 10 and engine 44 tests, totaling 138. Both runs had zero failures or skips. Reports and logs are retained in `/Users/leipeng/Documents/Codex/legado-shelf-sort-assessment-20261104/review-followup-0753107b3` (`receipt.json`, `jvm.xml`, `native-sort.xml`, and `native/summary.json`). Subsequent receipt-only edits do not change the tested source files.

Fixture limits are explicit. The database provider is restored or unregistered. The configuration registry has no reset operation, so a previously absent JVM configuration retains the fixture until the test worker exits. The Native test creates one configuration accessor. Its existing theme and preference listeners live until the owned test process exits. The isolated defaults suite is removed immediately. This validation slice does not change those production lifecycle APIs.

## Proposed minimum integration

1. Extract `sortBooks` into one shared pure function in `data/commonMain`, beside the existing book extensions. Move its existing branches intact. Keep the ViewModel as a caller and add the native engine as a caller. Reuse `cnCompare` and `getRealBookSort`. Review this narrow shared-source adaptation under ADR-002.
2. Keep `NativeShelfDao.organization()` as the book and group authority. Sort its books in memory. Use existing global `bookshelfSort`, group `bookSort`, book timestamps and `Book.order`.
3. Extend the existing shelf reply with the current global mode. Extend each group snapshot with its effective mode and ordered existing book IDs. This lets one book retain different positions in different groups without adding stored coordinates or duplicating book records. Swift follows these IDs for presentation.
4. Add one engine operation to set the global mode. Accept only 0 through 5, write through the existing preference provider and return the refreshed shelf reply. Invalid input must fail before writing. Keep existing engine request serialization and Swift stale-result checks.
5. Add a global sorting menu using the six existing modes. Label mode 3 as stored order to reflect that it reads the existing `Book.order` field. Update-time modes use stored chapter metadata. Group views show their effective mode and identify an existing group override. Global changes affect groups that inherit the global setting.
6. Budget zero new tables, schema migrations, dependencies, preference keys or database mutation methods. This first slice adds no group-sort editor, drag ordering, chapter-refresh scheduler or network request. Existing group overrides remain authoritative and visible. A group editor would need a separate guarded-write budget because the current organization token excludes `bookSort`.

The six modes are proposed together because they already share one implementation and existing persisted values. Their availability does not establish fresh chapter metadata or a native drag-reordering interaction.

## Acceptance for the proposed implementation

- Keep the upstream ViewModel tests passing after extraction. Add a native engine check that the same sorter receives only the existing native shelf scope.
- Reject invalid setter input without changing preferences, membership, progress or bookmark data.
- Verify inherited and overridden groups, one book in several groups, empty shelf, equal names, and stable ordering from identical input.
- Exercise the actual menu in portrait and landscape, change mode, relaunch the app and check retained selection and visible order. Verify group counts, opening a book and saved reading position.
- Run applicable native product, shared JVM/Native and C1 gates on the implementation head. Obtain the requested independent review before publishing a ready implementation PR. Owner H2 and explicit PR merge approval remain separate.

## Current disposition

Validation PR #63 merged as `4dcd414c25d606b29e9d917320826e6e8f44c275`. Implementation proceeds on `codex/native-shelf-sort` with the six-mode, zero-migration budget above. Recovery restores the existing global preference value and reverts the bounded code change. Group-sort editing remains outside this slice. Independent review, product H2 and explicit approval for the implementation PR remain required.
