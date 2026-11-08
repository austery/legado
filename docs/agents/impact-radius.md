# Impact radius map

## North Star

`/Users/leipeng/Documents/research-notes/05-archive/2026-10-22_legado-native-ui_north-star-and-maintenance.md`
(Lei's lineage note, a path on Lei's machine outside this repository; it is a
code span, not a link, because link checks reject machine-specific targets).
Agents read only its `## Current core` section. Lei confirmed that section on
2026-11-08.

### How Trunk follows from the mission

The mission in `## Current core` depends on three things. A failure in any of
them breaks daily reading, so the paths that carry them are Trunk (see
[Radius](#radius-in-this-repository)).

1. **Community sources stay usable.** The value is the community's per-site
   rules, run by the real runtime: sites built on the same template still
   differ. Sites also die and come back, so no single source lasts (Lei,
   2026-11-08: about 2,300 collected source files, about 1,500 after removing
   duplicates). Paths:
   - rule execution, networking and JS in `data/`, `core/`, `foundation/` and
     the engine-linked modules;
   - the source import format (`KS_JSON`, a JSON configuration explained under
     Structure, and `entities/rule/`);
   - change source: multi-source search (`IncrementalSearch.kt`) and the switch
     path (`ReaderEngine.prepareSourceSwitch` at `ReaderEngine.kt:130`,
     `commitSourceSwitch` at `:181`, `NativeShelfDao.switchSource` at
     `NativeShelfDao.kt:214`);
   - every upstream integration merge.
2. **Lei's reading data is kept** (no silent progress loss or wrong overwrite).
   Paths:
   - the Room database, the shared `Book` writers, and the native resume and
     bookmark DAOs (data access objects);
   - downloaded chapters: the chapter cache layout and writers, and the eviction
     path in `OfflineCache.kt`. Cached chapters are the only copy once a source
     is gone;
   - the native save path (`ReadingSaveCoordinator.swift`).
3. **The reading position survives layout changes** (book, chapter and
   paragraph). Paths:
   - the `ReaderEngine` contract and `EngineHost`;
   - the native composition root (`ReaderModel.swift`, `NativeReaderApp.swift`);
   - the reading views that compute the saved paragraph offset:
     `ReadingSpreadView.swift` (`firstVisibleOffset`, `:49`, passed on at
     `:167`) and `ReadingText.swift` (`acceptPageTurn`, defined at `:302` and wired at
     `:267`, which reports the offset at `:309`; also on scroll at `:213` and on find at `:367`). The
     offset reaches the durable save through `NativeReaderApp.swift:72` and
     `ReaderModel.swift:995-999`;
   - in-chapter find and cached search, whose result range becomes that offset:
     `ChapterFind.swift` (the find request and the `ChapterFindContext.matches`
     guard, `:10-15`) is accepted at `ReadingText.swift:352-354` and reported at
     `:367`; `CachedSearchSheet.swift` feeds the same path through
     `NativeReaderApp.swift:150-153`.

### `north_star_conflict` examples

A task inside a `## Current core` non-goal, or one that changes the product's
intended form, is a product decision for Lei. Stop it with
`north_star_conflict`. Examples, each with the `## Current core` line it comes
from:

- Match another reader's full feature set (Wanyuan, Fanqie or Apple Books)
  because the reference has it, not for a journey Lei confirmed. Source: product
  form ("does not promise feature parity").
- Write a private parser or rule runtime, or patch core parsing and rule
  execution in a private fork, instead of reusing the upstream runtime. Source:
  mission ("reuse the real Legado/KMP runtime").
- Take on long-term private per-site rule maintenance. Source: non-goal ("not
  another job of fixing book sources").
- Treat a dead third-party site as a product defect to fix in this repository,
  or promise that every source keeps working. Source: non-goal ("no guarantee
  that every community source works forever").
- Follow the newest upstream as a goal in itself. Source: non-goal ("not chasing
  the latest upstream").
- Hand routine technical work back to Lei as a standing duty: fixing sources,
  reading logs, or handling upstream conflicts. Source: division of work and
  non-goal.
- Introduce a new data format, a new recurring cost, or a change to the
  responsibility boundary without Lei's decision. Source: non-goal ("Lei decides
  these").

### Other owner decisions (not `north_star_conflict`)

These also stop and go to Lei, but the North Star is not their source:

- [ADR-001](../architecture/decisions/ADR-001-native-experience-and-upstream-ownership.md)
  (an architecture decision record) lists two compatibility goals that "are not
  project goals", B and C: exchange shelf or progress data with another reader,
  or keep the database readable by an unmodified old client.
- ADR-001's bounded MVP (minimum viable product) policy: do not separate product
  storage or replace the runtime without a blocked requirement or an observed
  recurring cost.
- Both items above are new design intent, which stops automation under the
  policy's execution gate 1.
- Publishing, deployment, live-provider calls, paid calls and other actions the
  policy's execution gate 5 says need separate approval.

## Policy and scope

Lei's global `PERSONAL-REPO-AUTOMATION.md` (global-skills `54322db`) defines:

- Door: Two-way or One-way;
- Radius: Leaf, Branch, Trunk or Unknown;
- Structure: untouched, approved, unapproved or Unknown;
- the controlled-Branch evidence, the review tiers (L1, L2) and the execution
  gates.

This file maps those terms onto this repository and sets the review depth for
each class. It grants no merge authority. [`AGENTS.md`](../../AGENTS.md) still
requires Lei's explicit approval for every PR merge (see
[Prerequisites](#prerequisites-before-automatic-merge)).

Evidence in this file was read at `native-reader` `e74d8a07c` on 2026-11-08.
Re-check a cited path when it has changed since.

Each change is classified on three separate axes:

1. **Door:** can the change and its effects be undone?
2. **Radius:** if the change is wrong, how far does the failure spread?
3. **Structure:** does the change touch a structure path (below)? The changed
   file paths decide this, not judgment.

Keep Radius and Structure apart. A new Room table adds an entity and edits
`AppDatabase.kt`, so its Radius is Trunk (shared code). Separately, it touches
Structure paths, so it needs a design that names it (Structure approved);
without one it is unapproved.

## How this repository is built

Terms used below:

- **KMP**: Kotlin Multiplatform. The upstream project is a multiplatform
  version of Legado; most of this tree is vendored from it.
- **C1**: this repository's required CI workflow (`.github/workflows/c1-engine.yml`).
- **OHOS**: HarmonyOS, one of the upstream client platforms.
- **H1**: the owner-approved scope recorded in an Issue that uses the
  [bounded-slice template](../../.github/ISSUE_TEMPLATE/03-bounded-slice.md).
  It is what the policy calls the approved design.
- **KSP**: Kotlin Symbol Processing (compile-time code generation).
- **cinterop**: the Kotlin/Native bridge that links a C library.
- **IPA**: an iOS app package.
- **Codable**: Swift's built-in encoding and decoding protocol.
- **ATS**: Apple App Transport Security (which plain-HTTP hosts the app may
  reach).

Read the radius rules with these dependency edges in mind:

- The product is the native iPad app. The Swift code in `native-ios-app/Sources/`
  reaches the engine almost only through `ReaderModel.swift` and
  `DiscoveryModel.swift` (`grep -c engine` gives 55 and 11 lines). The views
  hold the model, not the engine.
- `engine-ios` depends on `:core` only (`engine-ios/build.gradle.kts:33`).
  `:core` exposes `:data` and `:foundation` (`core/build.gradle.kts:72-73`).
  The engine does not link `:ui`.
- The same `data`, `core` and `foundation` modules are also consumed by the
  original upstream clients: `:ui` (`ui/build.gradle.kts:153-156`), `:app`
  (`app/build.gradle.kts:328`), `:desktop` and `:desktop-core` through `:ui`
  (`desktop/build.gradle.kts:181`, `desktop-core/build.gradle.kts:24`),
  `:headless` (`headless/build.gradle.kts:39`) and `ohosApp`.
- Keeping upstream integration cheap is a project goal
  ([ADR-001](../architecture/decisions/ADR-001-native-experience-and-upstream-ownership.md#owner-confirmed-policy-round-1-2026-10-13)).
  Every edit to an upstream-owned file is a future merge conflict as well as a
  runtime change.
- C1 executes the engine and the native product. For `:ui` it only compiles the
  iOS simulator target and runs `:ui:jvmTest` (`c1-engine.yml:218-219`). No C1
  lane runs the Android, desktop, OHOS or upstream Compose iOS clients.

## Structure paths

### Why the policy fallback paths do not work here

The policy fallback paths miss this repository's persistent structure:

- `**/migrations/**` matches nothing. Migrations live in
  `DatabaseMigrations*.kt` and `Migration84To85*.kt`, and in Room
  `autoMigrations` inside `AppDatabase.kt`.
- `**/schema.*` matches nothing. Room schema snapshots are
  `data/schemas/io.legado.app.data.AppDatabase/<version>.json`.
- `**/*.sql` matches only test fixtures (`data/src/jvmTest/resources/schema*-fixture.sql`).
- `**/*.prisma` does not apply.

The policy treats a new persistent model outside the fallback paths as Unknown.
Here that would make every Room change Unknown and every chapter-cache change
invisible, so use the list below instead.

### Paths

A change that adds, modifies or deletes anything under these paths touches
Structure.

**Room database (shared by the native app and every upstream client)**

- `data/src/commonMain/kotlin/io/legado/app/data/AppDatabase.kt`: `@Database`
  version (92), entity and view list, and `autoMigrations` (`:61-80`).
- `data/src/*/kotlin/io/legado/app/data/DatabaseMigrations*.kt` and
  `data/src/*/kotlin/io/legado/app/data/Migration84To85*.kt` (common
  definitions plus the `ios`, `jvmAndAndroid` and `ohos` actuals).
- `data/src/*/kotlin/io/legado/app/data/AppDatabaseDefaults*.kt`: seed data
  passed to the database callback (`IosDatabaseDriver.kt:77`).
- `data/schemas/io.legado.app.data.AppDatabase/`.
- `data/src/commonMain/kotlin/io/legado/app/data/entities/` and
  `data/src/roomEntitiesMain/kotlin/io/legado/app/data/entities/`, including
  `entities/rule/`. The rule classes are serialized into JSON columns of
  `BookSource` (`RuleStringSerializer.kt`, `RawJsonStringSerializer.kt`). A rule
  class change alters persisted column content and the source import/export
  format without any migration.
- `data/src/iosMain/kotlin/io/legado/app/data/IosDatabaseDriver.kt`: database
  file name and builder (it joins `filesDir` and `DATABASE_NAME`, `:100-101`;
  `DATABASE_NAME` is `legado.db` at `AppDatabase.kt:117`).

**iOS app container and directories**

- `PRODUCT_BUNDLE_IDENTIFIER` in `native-ios-app/project.yml` (`:87`). It
  selects the iOS sandbox container that holds everything below. Changing it
  leaves all of that data behind for an installed app.
- `data/src/iosMain/kotlin/io/legado/app/help/file/AppFilesDir.ios.kt`
  (`:27-41`): resolves `filesDir` (the Documents folder), `cacheDir` and
  `coversDir`. Every store below and the database live under these.
- `data/src/nativeMain/kotlin/io/legado/app/help/storage/NativeDataStorage.native.kt`
  (`:15-21`): the `book_cache`, `bg`, `font` and `backup` directories.

**Persisted formats outside table definitions**

- `foundation/src/commonMain/kotlin/io/legado/app/utils/KsJson.shared.kt`:
  `KS_JSON` is the JSON configuration that decodes community source files
  (`SourceManagement.kt:77-78`) and encodes exports (`:129`). Its leniency
  settings decide which community source files still import. This is
  compatibility goal A in ADR-001.
- Key formats inside the generic `caches` Room table:
  `data/src/commonMain/kotlin/io/legado/app/help/config/SourceConfig.kt`
  (`sourceScore_{origin}`). See Unknown below.
- The per-source file store on iOS:
  `core/src/nativeMain/kotlin/io/legado/app/help/NativeSourceCacheProvider.native.kt`
  writes `{filesDir}/cache_manager/<escapeKey(key)>`. It holds each source's
  `loginHeader_`, `userInfo_` and `sourceVariable_` values (`data/src/commonMain/kotlin/io/legado/app/data/entities/BaseSource.kt:199-271`),
  the per-key `v_<source>_<key>` variables (`:288`, `:296`) and the JS `cache`
  binding (`:316`).
  On iOS these values are files, not `caches` rows. Source deletion removes
  `caches` rows (`SourceHelp.kt:247`) and source scores
  (`NativeSourceHelpAccessor.native.kt:66-68`), but no step deletes the
  `cache_manager/` files (Issue #76).
- `core/src/nativeMain/kotlin/io/legado/app/help/NativeFileCacheProvider.native.kt`
  (`:53-56`, `:117`): persistent file-cache entries at
  `{filesDir}/file_cache/<key.hashCode()>`.

**Reading-position format**

- `data/src/commonMain/kotlin/io/legado/app/data/dao/NativeResumeDao.kt`
  (`NativeBodyCoordinates`, `:17-40`): the stored coordinate version
  (`VERSION = "native-body-v1"`), the body hash (`sha256`) and the paragraph rule
  (`paragraphStart`). Writers: resume rows (`NativeResumeDao.kt:80`, `:102`;
  also the source switch at `NativeShelfDao.kt:270-271`), bookmark rows
  (`NativeBookmarkDao.kt:68-77`) and cached search hits
  (`CachedChapterSearch.kt:48`). Checks: cached search hits
  (`CachedChapterSearch.kt:78`), the eviction guard (`OfflineCache.kt:68-69`),
  bookmark open (`ReaderEngine.kt:632-650`), resume save
  (`NativeResumeDao.kt:91`) and resume restore (`ReaderEngine.kt:713`).
- `native-ios-app/Sources/ReadingText.swift` (`paragraphStart`, `:115-135`): the
  Swift copy of the same paragraph rule.

A change to the paragraph rule on either side, without a new `VERSION`, moves
saved positions where the old and new rules differ, and bookmarks there fail
to open; the version check never fires. Change both sides together, bump
`VERSION`, and re-check every check site listed above.

**Chapter cache files**

- `data/src/commonMain/kotlin/io/legado/app/help/book/BookHelpShared.kt`
  (`cacheFolderName = "book_cache"`, `:49`) and
  `data/src/commonMain/kotlin/io/legado/app/help/book/BookStorage.kt`
  (the `getFolderName` and `saveText` interface).
- `core/src/nativeMain/kotlin/io/legado/app/help/book/NativeBookStorage.native.kt`:
  the iOS chapter writer (root `{filesDir}/book_cache/`, atomic `saveText`).
- `core/src/nativeMain/kotlin/io/legado/app/help/book/NativeBookImageStorage.native.kt`:
  chapter images at `book_cache/{book}/images/{md5}.{suffix}`.
- `data/src/commonMain/kotlin/io/legado/app/help/book/BookExtensionsShared.kt`
  (`getFolderNameNoCache`, `:39-43`): the folder-name algorithm (strip
  `AppPattern.fileNameRegex`, keep 9 characters, append `md5Encode16(bookUrl)`).
  `foundation/src/commonMain/kotlin/io/legado/app/constant/AppPattern.kt`
  (`fileNameRegex`, `:44`) is part of that algorithm: changing the characters it
  strips moves some books' folders. `Book.getFolderName()` only delegates to
  `getFolderNameNoCache`. `BookChapter.getFileName`
  (`roomEntitiesMain/.../BookChapter.kt:96-99`) is covered by the entity
  directories.
- `engine-ios/src/iosMain/kotlin/io/legado/engine/EngineBookHelpAccessor.kt`
  (`:24`): cover files at `covers/<md5_16(bookUrl)>.jpg`.

Renaming any part of the chapter layout orphans every cached chapter. After a
source is deleted, cached chapters are the only copy of that book's text, so this
loss cannot be repaired by downloading again.

**Config files and backup format**

- `data/src/commonMain/kotlin/io/legado/app/help/config/` and
  `core/src/commonMain/kotlin/io/legado/app/help/config/`: the serialized config
  models and the preference key names. Examples:
  - `ReadBookConfigShared.kt`: the `ReadStyleConfig` model (`:913`), the files
    `readConfig.json` and `shareReadConfig.json` (`:886-889`), and their
    encoding (`:268-282`);
  - `ThemeConfigProvider.kt` (the `ThemeConfigData` model, `:55`) with
    `ThemeConfigStore.kt` (reads and writes `themeConfig.json`, `:39`, `:59`);
  - `SourceConfig.kt`.
- Other named JSON files under `filesDir`:
  `data/src/commonMain/kotlin/io/legado/app/help/PinnedExploreHelp.kt`
  (`exploreFavorites.json`),
  `data/src/commonMain/kotlin/io/legado/app/help/DirectLinkUploadShared.kt`
  (`directLinkUploadRule.json`) and
  `data/src/commonMain/kotlin/io/legado/app/help/HomeTabHelpShared.kt`
  (`homeTabs.json`, `:28`).
- `data/src/commonMain/kotlin/io/legado/app/help/storage/BackupShared.kt`
  (backup file list and content, `:108-128`), `RestoreShared.kt` and
  `BackupConfigShared.kt` (`restoreIgnore.json`): the backup and restore format.

**Decision records**

- `docs/architecture/decisions/`: the ADRs. A new ADR, or a change to an accepted
  one, needs Lei's approval. Write a new ADR when a decision changes, and change
  only the old one's status (`Superseded by ADR-N`).

**Preference and grant stores**

- `core/src/iosMain/kotlin/io/legado/app/help/config/IosPreferenceProvider.kt`
  (iOS backend for all shared preferences).
- `foundation/src/iosMain/kotlin/io/legado/app/utils/IosSecurityScopedStorage.kt`
  (`NSUserDefaults` keys for granted directories and the import root).
- `native-ios-app/Sources/ReadingPreferences.swift` (keys `nativeReader.*.v1`
  at `:27-30`, the reading-style encoder at `:38-44` and decoder at `:50-52`) and
  `native-ios-app/Sources/ReadingText.swift` (the `ReadingStyle` Codable model,
  `:4-11`). A decode failure silently falls back to the default style, and the
  next save overwrites the old data.

These three stores share `NSUserDefaults.standard`. A new key in any of them
that could collide with another store's key is Structure Unknown.

Not a Structure path: the explore-rule cache under `{cacheDir}/explore/`
(`NativeExploreKindsCacheProvider.native.kt`). It is regenerated from the
source.

### Not covered by paths: treat as Unknown

- Other upstream helpers that write a named JSON file under `filesDir`. Search
  for `"<name>.json"` in `data/` and `core/` when a change touches one; a file
  not listed above is Structure Unknown.
- Shared preference key names outside the config directories above. A renamed
  key silently resets a setting. Flag any key rename as Structure Unknown.
- New key prefixes in the `caches` table or in `cache_manager/` can be added by
  any upstream helper or by a source's JS. A new prefix outside `SourceConfig.kt`
  and `BaseSource.kt` is Structure Unknown.
- WebDAV (`data/src/commonMain/kotlin/io/legado/app/help/AppWebDavShared.kt`,
  remote directories at `:89-95`, backup upload at `:251`). Lei does not use it
  (2026-11-08).
- iCloud progress and backup sync
  (`core/src/iosMain/kotlin/io/legado/app/help/sync/IosICloud.kt`,
  `IosICloudBackupSync.kt`, `IosICloudProgressSync.kt`): an iCloud key-value
  store for progress and iCloud Documents for backup, gated by
  `IosICloud.enabled`.
- Neither `engine-ios` nor `native-ios-app` calls WebDAV or iCloud sync. A change
  that wires either into the native app is Structure Unknown until its remote
  layout is designed.
- Cookies and web storage of the backstage `WKWebView`
  (`data/src/iosMain/kotlin/io/legado/app/help/http/IosBackstageWebView.kt`)
  live in the system data store. The repository cannot version or roll them back.

### What Structure approved needs here

This list does not apply to an ADR. An ADR needs Lei's approval of that ADR.

- The H1 approved before implementation names each added or altered entity,
  column, index, view, migration, persisted key and file-layout element.
- This repository has no down migrations, and Room offers no reverse migration
  ([maintenance record, Room row](../MAINTENANCE.md#critical-dependency-and-acceptance-map)).
  So the PR attaches, instead of rollback output:
  - a **new** `data/src/jvmTest/resources/schema<N>-fixture.sql` for the old
    version and a test that migrates it forward with data preserved. A new
    fixture file is new coverage. Editing an existing fixture is an Always stop;
  - a synthetic snapshot-and-restore record that shows how the previous app
    build recovers. Never use Lei's device database for this.
- A schema migration that writes data is **One-way** by default. Only the
  snapshot-and-restore evidence above can show Two-way.
- An upstream integration merge that moves the schema version is Structure
  approved only when its H1 names each changed entity, column and migration.
  Otherwise it is unapproved.

## Radius in this repository

Radius answers only how far a failure spreads.

### Trunk

**Shared upstream production code** in `data/`, `core/` and `foundation/`,
because the engine and every upstream client consume it. Hubs to name in a PR:

- `AppDatabase.kt`;
- the shared `Book` writers: `BookDao` and `data/.../dao/NativeShelfDao.kt`
  ([ADR-002](../architecture/decisions/ADR-002-engine-boundaries-and-upstream-validation.md#actual-reuse-boundary-and-maintenance-cost));
- the native persistence DAOs `NativeResumeDao.kt` and `NativeBookmarkDao.kt`
  (guarded writes that hold reading-position invariants);
- `model/webBook/SearchModel.kt` and `help/source/SourceHelp.kt`;
- an `io.legado.app.ui.*` package inside `data/` (see
  [Coupling](#coupling-that-a-folder-name-hides)).

**Modules the engine links**, through `data`, `core` and `foundation`:

- `modules/quickjs` (the JS engine). `scripts/build-ios-native.sh` compiles its
  sources (`:12`) into `libquickjs.a` (`:63`), and the cinterop in
  `data/build.gradle.kts:367-381` links it;
- `modules/quickjs-processor` (KSP code generation, `data/build.gradle.kts:597-598`);
- `modules/js-api` and `modules/rjpath` (`data/build.gradle.kts:405-406`,
  `foundation/build.gradle.kts:46`);
- `modules/charset-native` (`foundation/build.gradle.kts:86`).

**Engine contract and composition** (`engine-ios/src/iosMain/kotlin/io/legado/engine/`):

- `ReaderEngine.kt` when an existing export, reply shape or error mapping
  changes;
- `EngineHost.kt` (process-wide provider registration and ordering,
  `:114-141`) and the providers it registers, such as `EngineBookHelpAccessor.kt`;
- `CachedChapterSearch.kt` hit coordinates and the `verify` check (`:66`,
  `:78`): an accepted hit (`ReaderEngine.kt:110`) becomes the reading position
  (`:709`), which is then saved (`ReaderModel.swift:995-999`);
- `IncrementalSearch.kt` (multi-source search, the first half of change source;
  it wraps the shared `SearchModel`);
- `EngineOperation.kt` (the failure latch shared by `ReaderEngine`,
  `IncrementalSearch`, `NativeDiscovery`, `OfflineCache` and `EngineHost`).

**Native app composition and the reading position** (`native-ios-app/Sources/`):

- `ReaderModel.swift`, except a new method for a Branch view that does not touch
  position saving, the reading session or shelf writes (that is Branch, below);
- `NativeReaderApp.swift` and `ReadingSaveCoordinator.swift`;
- `ReadingText.swift` and `ReadingSpreadView.swift`, including layout and
  pagination changes, because they compute the paragraph offset that is saved;
- `ChapterFind.swift` and `CachedSearchSheet.swift`, because their result range
  becomes that offset (see [How Trunk follows](#how-trunk-follows-from-the-mission),
  item 3).

**Build and toolchain:** `gradle/libs.versions.toml`, `settings.gradle.kts`,
`build-logic/`, `build.gradle.kts`, `gradle.properties`,
`data/build.gradle.kts`, `core/build.gradle.kts`, `foundation/build.gradle.kts`,
`engine-ios/build.gradle.kts`, and `scripts/build-ios-native.sh` (it builds the
QuickJS library; SQLite comes from the system, `-lsqlite3` at
`data/build.gradle.kts:373`; C1 runs the script at `c1-engine.yml:211`).

**Upstream integration:** any upstream integration merge into `native-reader`,
whatever its diff size. See ADR-002 and the maintenance record's
[comparison points](../MAINTENANCE.md#where-maintenance-reaches-upstream)
(product base, previous and candidate upstream, tested head).

### Branch

Each entry names what the file calls and what it writes. A Branch counts as
controlled only with the policy's controlled-Branch evidence for the actual
change; the notes below are the starting point, not that evidence.

**Engine feature files behind an unchanged `ReaderEngine` contract**
(`engine-ios/src/iosMain/kotlin/io/legado/engine/`):

- `NativeDiscovery.kt`: runs a source's explore rules for the Discover screen.
  The engine code itself writes only the regenerable explore cache. But the
  rules run source JS (`BookSourceExtensionsShared.kt:127`), and that JS can
  persist source variables through `source.put()` (`BaseSource.kt:288`, written
  to disk at `NativeSourceCacheProvider.native.kt:88`). A change to when or how
  rules run therefore falls under the write-path exception below. Called only
  from `DiscoveryModel.swift` through `ReaderEngine`.
- `CachedChapterSearch.kt`: Branch only for a change to how results are listed
  or summarized, with evidence that hit coordinates and checks are unchanged.
  Its hit coordinates and its `verify` check (`:66`) are Trunk (see Trunk).
- `OfflineCache.kt` and `SourceManagement.kt`: Branch only for changes that do
  not touch their write paths. Their writes fall under the exception below.

**An additive `ReaderEngine` export** that leaves existing exports, replies and
errors unchanged, together with the Swift caller that uses it.

**One Swift feature view or model** (`native-ios-app/Sources/`). The views reach
the engine through `ReaderModel.swift` or `DiscoveryModel.swift`:

- `DiscoveryModel.swift`: calls the Discover engine exports (`startDiscovery`,
  `loadMoreDiscovery`, `refreshDiscovery` and similar). Discover can run source
  JS; see `NativeDiscovery.kt` above.
- `DiscoveryView.swift`: Discover screen; also opens a result in the reader
  through `ReaderModel.select` (`:135`).
- `BookmarkSheet.swift`: opens and deletes bookmarks (`deleteBookmark`).
- `ShelfView.swift`: shelf browsing, sort (`setShelfSort`), groups
  (`createShelfGroup`, `renameShelfGroup`, `changeShelfGroups`,
  `deleteShelfGroup`), removal (`removeShelfBooks`), and new-chapter checks
  (`checkNewChapters`, which writes catalog rows through the engine,
  `ReaderModel.swift:517-529`).
- `SourceManagementView.swift`: source import (`confirmSourceImport`), export,
  enable and discovery switches, groups (`changeSourceGroup`) and delete
  (`deleteSources`).
- `ReadingPreferences.swift`: reading style, shelf layout and the prefetch
  setting (`prefetchNextTwo`, `:29`); no engine calls. Its file is also a
  Structure path.
- `ReaderModel.swift` may gain a new method for one of these views if the method
  does not touch position saving, the reading session or shelf writes.

**Swift views that start an irreversible write.** `ShelfView.swift`,
`SourceManagementView.swift` and `BookmarkSheet.swift` start deletes that a code
revert cannot undo. Lei decided on 2026-11-08 that such a view stays **Radius
Branch**: a wrong change stays inside that screen's action. A change to which
items the action selects or deletes (for example "Select visible" in
`SourceManagementView.swift:71`) has **Door One-way**, so it takes the L2 tier.
This rule covers only those three views. The reader's change-source UI lives in
`NativeReaderApp.swift` and `ReaderModel.swift`, which are Trunk.

**Exception for engine write paths:** a change to engine code that writes,
deletes or evicts shared persistent state is not Branch by file name. Examples:

- source import merge rules and deletion in `SourceManagement.kt`
  (`dao.importReviewed` at `:121`, `SourceHelp.deleteBookSourceParts` at `:59`);
- chapter eviction in `OfflineCache.kt` (`storage.delContent` at `:111`).

Classify such a change by the shared table or store it writes (Trunk). Its Door
is One-way unless recovery is shown.

### Leaf

- Copy, colour or styling inside one Branch-listed Swift view, with no change to
  model calls, selection, pagination or persisted keys.
- New tests that leave existing assertions, fixtures, baselines and declared
  counts unchanged (see the declared-journey rule under Always stop).
- Documentation that states no rule: typo or link fixes outside the policy text
  listed under Always stop.

### Coupling that a folder name hides

- `engine-ios/.../IncrementalSearch.kt:10` imports
  `io.legado.app.ui.book.search.SearchScope`, and `CachedChapterSearch.kt:6`
  imports `io.legado.app.ui.book.searchContent.LiteralTextSearch`. Both classes
  live in `data/src/commonMain`, not in the `:ui` module. A change to an
  `io.legado.app.ui.*` package inside `data/` is shared upstream code (Trunk),
  even though the package name says "ui".
- Upstream reference code that the engine does not link (for example
  `ui/src/commonMain/.../ChangeBookSourceViewModelShared.kt`) is read-only
  reference for the [upstream-first rule](../../AGENTS.md#upstream-first-features).
  Reading it is free. Editing it is an Always stop (next section).

### Upstream clients Lei does not use

Lei confirmed on 2026-11-08 that he does not use the original Android, desktop,
OHOS or upstream Compose iOS clients. He reads on the iPad about 90% of the time
and on the iPhone for the rest. He does not read on a computer; running the iPad
app on a Mac is possible but is not a target.

Paths:

- the clients Lei named: `ui/` (original Compose UI), `app/` (Android),
  `desktop/`, `desktop-core/`, `ohosApp/`, `iosApp/` (upstream Compose iOS app);
- upstream tooling with no consumer in the native product (not named by Lei;
  same evidence: the engine does not link them): `headless/`, `benchmark/`;
- modules only those clients use: `modules/treeview`, `modules/web`,
  `modules/quickjs-android-native` and the `modules/*-ohos` modules.

Classification:

- **Radius Leaf for the product.** A runtime failure there does not reach the
  native app, because `engine-ios` does not link them (`engine-ios/build.gradle.kts:33`).
- **Always stop for edits.** They are upstream-owned. An edit adds upstream
  merge-conflict cost, which ADR-001 asks to keep low. Leave them as upstream
  ships them.
- **CI still reaches `ui/`.** C1 compiles `:ui` for the iOS simulator and runs
  `:ui:jvmTest` (`c1-engine.yml:218-219`), so a shared-module change that
  breaks `:ui` still fails the required check.

`modules/quickjs-test` is not client code. It is test support for the Trunk
module `modules/quickjs` (`modules/quickjs/build.gradle:40,45`); it is covered by
the test rules under Always stop.

### Unknown until evidence exists

Treat these as **Unknown**. The missing evidence is stated for each:

- `native-ios-app/project.yml` settings that no other rule names. ATS,
  entitlements, signing and test targets are Always stop; the bundle identifier
  is a Structure path. Missing: a signing and install check on Lei's device
  path.
- Any path this file does not name.

## One-way effects in this repository

- Room migrations that write data, and any change that rewrites existing rows on
  first launch. Room has no reverse migration; old code cannot read new data.
- Deleting or rewriting user data at runtime, for example source deletion
  (`SourceHelp.deleteBookSourceParts`) or cache eviction. A code revert does
  not restore the rows or files.
- Renaming the chapter cache layout or changing the bundle identifier (Structure
  above): the old files are left behind.
- Writes to `master`, the upstream mirror. `sync-upstream-mirror.yml` runs daily
  with `contents: write` and fast-forwards it
  (`scripts/ci/sync-upstream-mirror.sh --apply`).
- Releases:
  - `ios.yml` runs on manual dispatch only, with no repository or secret guard.
    With stage `ipa` or `simulator` it publishes the `multiplatform-test`
    prerelease through `_publish.yml` (`ios.yml:353-361`). This path is open
    today.
  - `release.yml` (cron on the 1st and 15th) and `test.yml` also call
    `_publish.yml`. On 2026-11-08 `test.yml` skips in `austery/legado`
    (`test.yml:38`), and `release.yml` skips without the `RELEASE_KEY_STORE`
    secret; `gh secret list` showed no repository secrets. Adding that secret or
    changing these guards turns publishing on.
- `delete_actions.yml` (manual dispatch) permanently deletes workflow-run
  history, which is the CI evidence trail.
- `sync-quickjs-ng.yml` (`contents: write`) overwrites the vendored QuickJS and
  opens a PR.
- IPA distribution to Lei's device, and live community-site requests beyond
  loopback fixtures.

## Always stop, whatever the class

- **Verifier changes.**
  - Everything under `.github/` except the policy text below: workflows,
    `.github/scripts/`, `.github/actionlint.yaml` and `.github/dependabot.yml`.
  - `scripts/path-c/` (including `c1_scope.py`, `native_product_ci.py`,
    `reader_ui_ci.py`, `kotlin_native_ci.py`, `verify_url_tests.py`, and fixture
    servers), `scripts/ci/` (including `ci-machine-lock.sh`, the lock shared
    with `insight-engine-personal`), `scripts/build-ios-native.sh`, and the pinned
    verification dependency `scripts/path-c/requirements-doc-links.txt`.
  - `engine-ios/fixtures/`, `engine-ios/harness/`, `native-ios-app/UITestHost/`
    and `native-ios-app/ui-tests.yml`.
  - Existing files in the test source sets and test resources:
    `native-ios-app/Tests/`, `native-ios-app/UITests/`,
    `engine-ios/src/iosSimulatorArm64Test/`, `data/src/*Test/` (including
    `data/src/jvmTest/resources/`), `core/src/*Test/`, `modules/quickjs-test/`,
    and the test targets in `native-ios-app/project.yml`. Editing or deleting an
    existing file there is a stop; adding a new test or fixture file is new
    coverage.
  - Existing test assertions, fixtures, baselines, timeouts, thresholds and
    expected counts.
  - The required check name `C1 engine regression` and the ruleset.

  New coverage is not a verifier change. In particular, a new UI journey must be
  declared in `scripts/path-c/reader_ui_ci.py` with `expectedTests` raised by
  the same number. That edit adds coverage and is not a stop. Lowering a count,
  removing a declared test, or adding a skip is a stop.
- **Policy text.** `AGENTS.md`, `GLOSSARY.md`, `docs/VALIDATION.md`, the
  validation sections of `native-ios-app/README.md`, `engine-ios/README.md` and
  `scripts/path-c/README.md` (VALIDATION.md points to them),
  `docs/MAINTENANCE.md`, `docs/agents/`, ADRs, accepted specs under
  `docs/architecture/`, `.github/ISSUE_TEMPLATE/`, and the archive index
  `docs/_archive/README.md`.
- **Security boundary.** ATS exceptions in `native-ios-app/project.yml`
  (`NSAppTransportSecurity`, `:44-83`), entitlements, and signing settings.
- **Upstream clients Lei does not use** (listed under Radius): any edit.
- **Upstream integration.** Any upstream integration merge, any change to the
  mirror sync, and any edit to an upstream-owned file that is not part of an
  approved H1.

### Inherited workflows in an upstream integration merge

The upstream (`huajideshutiao/legado`, the parent of this fork) is maintained
mostly by one person, with no published roadmap, and changes daily. Its
`.github/` changes arrive with every upstream integration merge. Example: the
merge in PR #68 (`7a23c081f`) changed `ios.yml` and `sync-quickjs-ng.yml`.

So every upstream integration merge also does these steps:

- List its `.github/` changes on their own (`git diff <previous base> <merge>
  -- .github`) and review them as verifier changes.
- Re-check the guards that limit inherited publishing in this repository (the
  `ios.yml` manual publish stays open; see One-way effects):
  - `test.yml:38`: the `github.repository != 'austery/legado'` condition;
  - `release.yml:39-41`: publishing runs only when `RELEASE_KEY_STORE` is set;
  - `ios.yml:353-361`: the manual publish of the `multiplatform-test` prerelease.
- Stop and ask Lei when any guard changed, a workflow gains a new trigger or
  write permission, or a new workflow appears.

A path on the docs-only allowlist in `c1_scope.py` gets cheaper CI. That is a
CI routing fact, not a Leaf classification.

## Review depth

Review models and commands are pinned in global-skills
`agents/REVIEW-COMMANDS.md` (§ Review models); this file does not repeat them.

**Leaf, Door Two-way, Structure untouched: L1.**

- One implementation.
- The `reviewer` agent runs Standards and Spec.
- The vendor that did not author the change runs Risk, following
  `RISK-REVIEW.md`: Codex for Claude Code's work, `reviewer` for Codex's work.
  If that vendor is unavailable, the author vendor's reviewer runs Risk and the
  PR comment says so.
- Lei: merge approval (AGENTS.md).

**Controlled Branch, Door Two-way, Structure untouched: L1.**

- The L1 reviews above.
- The author records consumers and failure propagation per the policy; the
  Risk review verifies that evidence.
- Lei: merge approval; a decision when author and reviewer disagree.

**Structure approved.**

- The review of the strictest tier that applies, plus the migration fixture and
  snapshot-and-restore evidence above. An ADR does not need that evidence.
  Almost every Structure path is in
  `data/`, `core/` or `foundation/` (Trunk), and migrations are a
  wrong-but-green domain, so in practice this is L2.
- Lei: H1 approval before work; merge approval.

**L2.** Everything the policy's execution gate 1 stops: Trunk, Door One-way,
Radius Unknown, a Branch without controlled-Branch evidence, Structure
unapproved or Unknown, author–reviewer disagreement, or new design intent. This
map adds every Always stop item. Also the wrong-but-green
domains, where a wrong change still passes every test: crash recovery, paid
calls, irreversible publication and migrations.

- The L1 reviews.
- Standards and Spec reviews by the vendor that did not author the change.
- `deep-reviewer` (Claude Code's agent for independent judgment) when the
  question needs independent judgment, including design questions.
- Antigravity (a third review vendor with a small quota) when Door is One-way or
  Structure is not untouched and its quota allows, and for any change Lei names
  it for. Record a skip in the PR comment.
- Runtime changes also need evidence from a real run: the relevant
  `native_product_ci.py` suites, a declared UI journey, or a simulator
  walkthrough with screenshots.
- Lei: H1 approval before work; decision before merge.

Until this map is merged, the whole repository is L2 (`no_radius_map`).

The coordinator runs the independent reviewers itself and gives them only the
requirement text, the pinned base/head and the code. The coordinator verifies
each finding and brings Lei the decisions above or a disagreement.

## Slicing example: automatic change source

Issue #69 left this follow-up: when a shelf book's source is gone, upstream
changes source automatically. Upstream does it in `autoChangeSource`
(`ui/src/commonMain/kotlin/io/legado/app/ui/book/changesource/ChangeBookSourceViewModelShared.kt`).
It walks the search results of the same book type, loads each table of
contents, and takes the first that succeeds. The engine does not link `:ui`, but
the native manual switch already exists (`ReaderEngine.kt:130`,
`NativeShelfDao.kt:214`).

1. **Design gate (Lei approves the H1).** Choose where the loop runs: in
   `engine-ios` over the existing search and switch exports, or moved into
   `data/`. Moving it edits upstream-owned code (Trunk, upstream conflict cost).
   Reimplementing it in `engine-ios` is a parallel implementation of an
   upstream capability, which AGENTS.md says needs Lei's explicit decision.
   The H1 also states that no table or column is added.
2. **Engine ticket: Radius Trunk, Door One-way, Structure untouched.** An
   additive `ReaderEngine` export that runs the loop over the existing search
   and `prepareSourceSwitch`, plus its engine test. Existing exports stay
   unchanged. Each switch commits through `NativeShelfDao.switchSource`, which
   deletes the old `Book` row and its catalog, then re-keys bookmarks and the
   resume record (`NativeShelfDao.kt:263-272`). The old chapter folder stays
   orphaned on disk, and the automatic loop removes the confirmation the manual
   switch has. It writes shared persistent state, so by the Branch exception it
   is Trunk, and it takes the L2 tier.
3. **Swift ticket: Radius Trunk, Door One-way.** In the reader, the "Source
   deleted" state offers "Change source automatically". The reader's
   change-source UI lives in `NativeReaderApp.swift`, and the call needs a
   `ReaderModel.swift` method that touches the reading session and shelf
   writes; both are Trunk. The new export rewrites shelf, catalog and reading
   session (`ReaderEngine.kt:181-204`), so the Door is One-way. It takes the L2
   tier.
4. **Leaf ticket.** The red tint for the Sources Delete button: styling inside
   one view, no model call.
5. **Stops.**
   - Source ranking by score: upstream already keeps scores in `caches`
     (`SourceConfig.kt:10`). A new score column instead touches the entity
     directories, so Structure is unapproved unless the H1 names it.
   - Changing the guards in `NativeShelfDao.switchSource` changes a shared
     `Book` writer: Trunk.

## Prerequisites before automatic merge

In this section, **automatic merge** means the policy's standing authorization:
an agent merges without Lei's approval of that PR. GitHub's **auto-merge** is a
different setting: it merges a PR when the PR meets its requirements.

Agents read the evidence here on 2026-11-08: the ruleset and repository settings
from GitHub, and `.github/CODEOWNERS` at `native-reader` `d9845fed3` plus the lines
for `BackupConfigShared.kt` and `docs/_archive/README.md`, added with this text.
This evidence is newer than the revision named under
[Policy and scope](#policy-and-scope).

Automatic merge stays off. Reasons:

- **AGENTS.md requires Lei's explicit approval for every merge.** The policy's
  standing authorization, which replaces the per-PR merge confirmation, cannot
  apply here until Lei changes `AGENTS.md`. That is Lei's decision, not
  something this map settles.
- **What GitHub already enforces.** The ruleset `Protect native-reader` requires:
  - a PR;
  - code-owner approval for paths in `.github/CODEOWNERS`;
  - the status check `C1 engine regression`, with up-to-date branches.

  A new reviewable commit dismisses a code-owner approval. Other paths need 0
  approvals, so GitHub's extra approval for unattributed Copilot changes
  (`require_extra_approval_for_unattributed_changes`) adds none there. The ruleset
  also blocks deletion and force-push.
- **What CODEOWNERS covers.** It copies named paths from this map. Change both
  together. It covers the Structure files and directories listed under
  [Paths](#paths). It does not cover:
  - files that [Paths](#paths) names only as a writer or a check site, such as
    `NativeBookmarkDao.kt`;
  - the WebDAV, iCloud sync and `IosBackstageWebView.kt` files named under
    [Not covered by paths](#not-covered-by-paths-treat-as-unknown).

  A PR that changes only those files needs 0 approvals. There, agents and reviewers
  apply this map's content rules; GitHub does not.
- **What GitHub leaves open.**
  - The repository admin role can bypass the ruleset. Lei's account holds that
    role. Agents do not use the bypass.
  - The repository setting allows auto-merge. An agent turns it on for a PR only
    after Lei gives merge approval for that PR's head, and passes that head with
    `--match-head-commit`.
  - GitHub's auto-merge pages say that auto-merge turns off when someone without
    write permission pushes or switches the base branch. They do not say what a
    push with write permission does, or that GitHub rechecks that head at merge.
    So a new head voids the approval: turn auto-merge off before a push, then ask
    Lei to approve the new head.
  - GitHub enforces an approval from the `austery` account, not Lei's decision. An
    agent session signed in with that account can approve a PR. Agents do this
    only when Lei explicitly tells them to.
- **What is missing:**
  - Conditions that depend on a diff's content. CODEOWNERS matches whole paths,
    so agents and reviewers still apply the content conditions in this map;
    GitHub does not enforce them.
  - A PR can change the check that judges it. `c1-engine.yml` runs on
    `pull_request` from the PR's own revision, on the self-hosted runner. A
    passing C1 alone does not prove the verifier is unchanged. For verifier paths
    in CODEOWNERS, the guard is Lei's approval, not an automatic check.
  - Agent identity. A GitHub App is installed for agent writes, but it has no
    Workflows permission. Workflow pushes still go through Lei's account. Agents
    open PRs with the App, because GitHub does not count an author's own approval.
    A PR opened from Lei's account cannot get code-owner approval without the
    bypass.
  - Runner reliability. The C1 runner shares this Mac with local work and with
    another repository's runner. `scripts/ci/ci-machine-lock.sh` serializes heavy
    CI jobs; local fixture work can still take the fixture ports and fail CI.
  - `docs/agents/` is not on the docs-only allowlist in `c1_scope.py`, so
    changes to this map run full C1. Its links are checked by
    `scripts/path-c/doc_links.py`, which C1 runs in every mode.
