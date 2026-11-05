# Existing features and the shortest next delivery

Date 2026-11-05, America/Toronto.

The owner prioritized two-page reading and requested an inventory of existing upstream capabilities before further feature work. Evaluate the working reading journey first. Use observed gaps to select subsequent work. Every proposed storage change must identify why existing fields cannot satisfy the required behavior.

## Source boundary

Native assessment head is `38046704e936a31e9666a9be5df1aeab958b1ec8`. Its production files match merged bookmark PR #62. Its complete tree equals validation commit `bd023f833` after rebase onto PR #62. The inventory-only commit was then replayed as `f8b7bc00e`. Integrated KMP upstream is `d31c0a270e7c8610e9679dbbda5a6bee06927952`. The inspected upstream snapshot is `83657e54829b7603aa392bf072283805769ad385`. Upstream pagination and its two-page settings have identical source at that snapshot and in this checkout.

The upstream Compose interface and the native Swift interface have separate presentation code. Shared runtime and storage capabilities can be called through the existing engine boundary. A Compose screen's presence establishes an implementation candidate. Native usability also needs bridge, lifecycle and platform evidence.

## Feature inventory

Paths are relative to the repository root. Source evidence means the implementation was inspected. Runtime evidence is listed separately.

| Feature | Existing upstream implementation | Current native delivery | Next action |
| --- | --- | --- | --- |
| Two-page reading | `ui/src/commonMain/kotlin/io/legado/app/ui/book/read/page/provider/PaginationEngine.kt:113` switches columns before advancing the spread. `ui/src/sharedUiMain/kotlin/io/legado/app/ui/book/read/config/MoreConfigScreen.kt:124` exposes the setting. | `native-ios-app/Sources/ReadingText.swift:262` activates spreads on iPad in landscape when the reading viewport is at least 900 points wide and 160 points high. `ReadingSpreadView.swift` renders original-text ranges through TextKit. | Reuse the delivered native behavior. Re-run the actual UI journey and inspect screenshots. |
| Reading appearance and reflow | Upstream reader configuration and layout pipeline already provide typography and page layout. | `native-ios-app/Sources/ReadingPreferences.swift` and `ReadingText.swift` provide persisted native presentation and reflow. | Evaluate current controls with the two-page journey. |
| Shelf groups and grid/list | `ui/src/sharedUiMain/kotlin/io/legado/app/ui/book/group/GroupEditDialog.kt:107` edits existing groups. The shared shelf ViewModel reads group membership. | `native-ios-app/Sources/ShelfView.swift:28` has group management, membership actions and grid/list controls. | Use existing native controls. |
| Shelf sorting | `ui/src/commonMain/kotlin/io/legado/app/ui/bookshelf/BookshelfViewModel.kt:366` contains six modes. Existing global preferences and group overrides provide storage. | Current native list uses read-time order. A six-mode bridge/menu is proposed in the linked assessment. | Optional follow-up after the priority reading evaluation. Reuse one shared sorter and existing fields. |
| Bookmarks | Existing Bookmark entity, DAO, reader menu and `ui/src/sharedUiMain/kotlin/io/legado/app/ui/route/BookmarkRoute.kt` provide upstream bookmark operations. | PR #62 delivered `native-ios-app/Sources/BookmarkSheet.swift` and source/body-bound anchors. ADR-004 records tested legacy identity differences and the approved native table. | Use the delivered feature. Existing approved storage is sufficient for the present scope. |
| Text search | `ui/src/commonMain/kotlin/io/legado/app/ui/book/searchContent/SearchContentViewModelShared.kt:179` searches across chapters. `SearchContentRoute.kt` wires the results screen. | `native-ios-app/Sources/ChapterFind.swift` provides current-chapter search. | If cross-chapter search becomes a priority, test cached-body coverage and processed-text versus original-text coordinates before bridge work. |
| Source management and discovery | Existing source models, import/export and exploration routes are present in the shared client. | `native-ios-app/Sources/SourceManagementView.swift`, `DiscoveryView.swift` and existing ReaderEngine operations provide the native controls. | Reuse the bounded delivered workflows. Interactive login requires a separate observed need and platform assessment. |
| Offline reading | Upstream chapter storage, cache and predownload code exist. | ReaderEngine exposes bounded next-chapter caching, cancellation and protected clearing. SPEC-006 records next-20 manual caching and opt-in next-2 prefetch. | Evaluate current limits before requesting whole-book downloads. |
| Local book import | `ui/src/sharedUiMain/kotlin/io/legado/app/ui/route/ImportBookRoute.kt:65` initializes import and delegates file picking to the platform. | The native shelf currently admits online text books. | Verify supported formats and iOS file access through existing platform implementations before choosing a slice. |
| Read aloud / TTS | `ui/src/sharedUiMain/kotlin/io/legado/app/ui/route/ReadAloudConfigDialog.kt:146` wires settings and shared engine configuration. Shared/native TTS providers exist. | Swift reading controls expose no TTS journey in the inspected source. | Verify actual iOS playback, cancellation and background behavior before integration. |
| Backup / WebDAV restore | `ui/src/sharedUiMain/kotlin/io/legado/app/ui/route/BackupConfigRoute.kt:198` invokes existing restore and also routes WebDAV operations. | Swift has no exposed backup/restore workflow in the inspected source. | Audit coverage of native resume/bookmark data and execute fixture recovery before exposing restore. |
| RSS | `ui/src/sharedUiMain/kotlin/io/legado/app/ui/route/ReadRssRoute.kt:88` connects shared RSS loading with platform WebView behavior. | Swift has no exposed RSS workflow in the inspected source. | Retain as an existing upstream capability for a future requested use case. |

## Minimum delivery and time

The priority two-page feature already has native implementation and an actual-touch test. The shortest delivery is a current-build verification and a usable screenshot, followed by owner evaluation on the intended iPad layout. This requires zero new feature implementation and zero storage changes if the existing behavior meets the need.

The initial verification budget is one framework build and one targeted UI journey. The canonical UI driver has a 900-second execution deadline. Toolchain build time is additional. Treat failures as evidence to diagnose before increasing the budget. A reliable feature estimate can follow any reproduced gap.

Shelf sorting remains an optional next delivery. Its existing proposal uses zero new tables, migrations, dependencies or preference keys. Its implementation and full acceptance should be estimated separately after the owner selects it as the next priority.

## Verification receipt

Current-build verification passed at `38046704e936a31e9666a9be5df1aeab958b1ec8`.

- Existing upstream `TwoPhaseLayoutPipelineTest` passed 18 tests, with zero failures, errors or skips. Its two-page case asserts left-to-right column transition before advancing the page.
- Existing `testTwoPageTurnsReflowAndDurableRecovery` passed 1 of 1 actual iPad simulator journeys, with zero failures or skips. It exercises left/right swipes, larger typography, narrow viewport fallback, portrait reflow, saved-position failure and retry, and application termination/relaunch with the retained position.
- Inspected the initial and relaunched screenshots. Both show two text columns. The controls are expanded in these captures. These are synthetic fixture screenshots. Physical iPad comfort and live-source reading remain unverified.
- Initial framework linking failed because task-local QuickJS libraries were absent. Ran the repository native-library build script and repeated the framework build successfully. The failure and successful retry logs are retained.
- The UI driver released its owned simulator. Test evidence and the source revision are archived at `/Users/leipeng/Documents/Codex/legado-double-page-verification-20261105`.

```sh
bash scripts/build-ios-native.sh ios_simulator_arm64
./gradlew :engine-ios:linkDebugFrameworkIosSimulatorArm64
./gradlew :ui:jvmTest --tests '*TwoPhaseLayoutPipelineTest'
python3 scripts/path-c/reader_ui_ci.py --output /private/tmp/legado-double-page-ui-20261105 --only-test testTwoPageTurnsReflowAndDurableRecovery
```

The commands used the existing runner JDK 21/JDK 17, Android SDK, Gradle/Konan caches and full Xcode environment. The native implementation needed zero source changes for this verification. Inventory rows other than pagination describe inspected implementation and prior delivery scope. They do not claim new runtime acceptance of every upstream feature.

## Storage decision rule for subsequent work

For each selected feature, trace its upstream entry point, shared implementation, platform adapter and existing data representation. Test the required behavior through that path. Use a bounded adapter when the native screen needs access to working shared logic. Propose a new persistent structure only after an executable mismatch establishes its necessity and the owner approves the concrete migration and recovery budget.
