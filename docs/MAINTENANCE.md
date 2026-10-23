# Maintenance and upgrade baseline

Snapshot: 2026-10-22. This record describes evidence and acceptance boundaries;
counts are not automatic merge thresholds. Merge requires Lei's explicit approval.
Status reconciled: 2026-10-23. The fixed B/U comparison and declared versions below
remain the original snapshot; no counts have been recalculated for the latest head.

## Fixed comparison

- Product B: `0240d065e305b054927a12e6ab8386ad3992abd2`.
- Integrated KMP upstream U: `c66940d6a91916fa5fdf43a4dfe9ae63e2b7ea8b`.
- `git merge-base --is-ancestor U B` succeeded. This records integration ancestry,
  not semantic compatibility with arbitrary future upstream versions.
- Compare immutable trees with `git diff --name-status -M U B`. The result has
  228 entries: 145 additions, 81 modifications and two renames. Rename destinations
  count once. Generated build output and untracked local material are excluded.
- The seven-file C1 extraction list in `engine-ios/README.md` is historical, not
  this cumulative baseline. This comparison excludes the documentation changes
  subsequently merged in PR #36 and later integration work.

### Reproduce the categorized inventory

Run from the repository root. Categories are exclusive path-based accounting,
not proof of subsystem isolation. Scripts (including Python tests) count as tooling;
Gradle files count as build files. Inspect the printed paths for risk assessment.

```python
import collections
import subprocess

upstream = "c66940d6a91916fa5fdf43a4dfe9ae63e2b7ea8b"
product = "0240d065e305b054927a12e6ab8386ad3992abd2"
rows = [line.split("\t") for line in subprocess.check_output(
    ["git", "diff", "--name-status", "-M", upstream, product], text=True
).splitlines()]

def category(path):
    if path.endswith(".md"):
        return "Documentation"
    if (path.startswith((".github/", "scripts/"))
            or path.endswith((".gradle.kts", ".yml", ".yaml"))
            or path in (".gitignore", "gradle.properties")):
        return "Build / CI / tooling"
    if "/schemas/" in path:
        return "Persisted schema snapshots"
    if (any(part in path.lower() for part in
            ("/tests/", "/test/", "test/kotlin/", "/fixtures/", "/harness/"))
            or "Test.kt" in path):
        return "Tests / fixtures / harness"
    if path.startswith(("engine-ios/", "native-ios-app/")):
        return "Native product / bridge"
    return "Shared / inherited production"

counts = collections.defaultdict(collections.Counter)
for row in rows:
    group = category(row[-1])
    counts[group][row[0][0]] += 1
    print(group, *row, sep="\t")
for group, statuses in sorted(counts.items()):
    print(group, dict(statuses), "total", sum(statuses.values()))
```

| Category | Added | Modified | Renamed | Total |
| --- | ---: | ---: | ---: | ---: |
| Build / CI / tooling | 36 | 7 | 0 | 43 |
| Documentation | 19 | 0 | 0 | 19 |
| Native product / bridge | 20 | 0 | 0 | 20 |
| Persisted schema snapshots | 2 | 1 | 0 | 3 |
| Shared / inherited production | 14 | 66 | 2 | 82 |
| Tests / fixtures / harness | 54 | 7 | 0 | 61 |
### Where maintenance reaches upstream

The 82 shared/inherited production entries include 66 modified files, 14 additions
and two renames. They span `core`, `data`, `foundation`, `ui` and platform adapters;
they are not 82 independent parser patches. The three schema snapshots need their
own compatibility review. Native additions are not cost-free simply because they
avoid upstream files.

`ReaderEngine` exports the Swift boundary; `EngineHost` registers shared providers.
`IncrementalSearch` uses shared `SearchModel` and its lifecycle, while native shelf
and resume DAOs share Book/storage state with original clients. These consumers
make runtime, identity and persistence changes cross-module risks. See
[ADR-002](architecture/decisions/ADR-002-engine-boundaries-and-upstream-validation.md).

For each future integration, retain B (product base), U0 (previously integrated
upstream), U1 (candidate upstream) and H (tested integration head), conflicts, compatibility repair
commits, changed shared contracts, new adaptation decisions and deferred findings.
Record unavailable time/conflict measurements as unknown, not zero. Compare these
at H2; no retrospective effort estimate or arbitrary file-count budget is claimed.

## Critical dependency and acceptance map

Versions below are declarations at B, not a freshly resolved dependency graph.
The exact executable lanes and prerequisites remain in [L0](VALIDATION.md) and
[the workflow](../.github/workflows/c1-engine.yml).

| Group / source | Declared baseline and actual consumers | Acceptance before an upgrade | Recovery limits |
| --- | --- | --- | --- |
| KMP build and runtime; `gradle/libs.versions.toml`, `settings.gradle.kts` | Kotlin 2.3.20, KSP 2.3.11, Compose 1.11.1. Shared data/core and engine compile together; original UI remains a regression consumer. OHOS separately selects `kotlin-ohos` 2.2.21-0.5.0-12. | Both iOS framework links, original UI compile, JVM and Native suites, engine and Swift product lanes. Changed non-iOS consumers require their own relevant evidence. | Restore source/catalog/wrapper in an isolated checkout with matching caches/toolchain; this does not prove old binaries can read new data. System Xcode/SDK changes are separate authorization. |
| QuickJS and host bridge; vendored README, `data/build.gradle.kts`, `engine-ios/build.gradle.kts` | Pin `02368b6b1689c28ff2ebe6d1f73d9c1893ae4ce7`; native C library/cinterop and JS host methods; Android/JVM wrappers also consume the vendor tree. | Native JS concurrency, rule, crypto and URL suites through real bridge; engine fixture and product lanes. Check vendor diff against the pin and local patch ledger before sync. | Source restoration must include wrappers and native rebuild. Sync overwrites files and does not replay local patches. README's empty patch ledger is historical; vendor byte identity was not revalidated in this baseline. |
| Room / SQLite / schema; `data/build.gradle.kts`, `data/.../AppDatabase.kt` | Room 3.0.1; AndroidX SQLite library 2.7.0 (not the system SQLite engine version); schema 91, local 88→89→90→91 path. Engine shelf/resume and original Book writers share storage. | Native shelf/resume integration, product save/restoration, interruption and offline restart; a format-changing candidate additionally needs explicit old/new migration and recovery fixtures. | No reverse migration guarantee. Retaining old code is insufficient after new data writes. A verified synthetic snapshot/restore experiment is needed before claiming Two-way data recovery; never use user DBs for this test. |
| Ktor / HTTP / cookies and chapter storage; data/core Gradle files | Ktor 3.5.2; Darwin HTTP, shared cookie/provider state, cache and atomic chapter storage feed real engine operations. | URI report gate, Native URL/JS tests, network/fresh-network/restart-cache harness, product failure/cancellation and offline lanes. | Restore code plus required compatible state. Cookie/cache semantics and serialized formats need inspection. Loopback fixtures do not certify live sites, auth flows or all providers. |

The inherited Dependabot ignore rules are present, but their Alipay-only explanation
is older than the default-toolchain split. They are not a complete criticality policy.
Neither a patch version nor a bot author establishes low risk. For a proposed update,
list newly introduced packages/native artifacts, publisher/registry/integrity changes,
install behavior and state-format changes; unknowns go to the owner. No version
upgrade, remote vendor sync or live-provider call was performed for this record.

## Deferred findings: reconcile evidence, not labels

Sources: full local reviews `pr-27v3.md` (2026-10-17, task-10) and `pr-19v3.md`
(2026-10-15, task-3) under the owner's Codex documents; repository carry-forward
record [upstream sync](upstream-sync-2026-10-18.md#deferred-scope).
The table preserves historical findings; no new platform reproduction was run.

| ID | Historical scope | Comparison against B / next decision |
| --- | --- | --- |
| PR27 F03 | Original Compose audio publishes a new source before book/catalog commit. | AudioPlayScreenModel changed since reviewed H `cf4e1f9`, but its diff adds UI callbacks/options rather than repairing that initialization. Retain; recheck full playback consumers before a fix. Not a Swift text-reader blocker by default. |
| PR27 F04 | Android video/PiP controller lifecycle. | Cited AndroidVideoPlayPlatformProvider blob unchanged from `cf4e1f9`; retain platform follow-up, no fresh Android acceptance. |
| PR27 F05 | Desktop crash list omits owned JVM fatal logs. | Cited DesktopPlatformServices blob unchanged; retain desktop follow-up. |
| PR27 F06 | Removed Backup enum key can invalidate persisted directory grants. | Cited DirUsage blob unchanged; retain compatibility concern and inspect platform grant readers if touched. Do not infer current Swift exposure from the enum alone. |
| PR27 F07 | Backup destination may collide with recursively cleaned workspace. | Cited BackupShared blob unchanged; retain storage follow-up, no destructive experiment performed. |
| PR27 F09 | Existing-directory users lose custom chapter-export selection. | Cited BookshelfManageScreen blob unchanged; retain original-client journey follow-up. |
| PR19 F15 | Forwarding software-delivered native signals. | Native crash handler unchanged from reviewed `6916842`; retain Android subprocess/device evidence requirement. |
| PR19 F16 | Duplicated native export-queue policy. | iOS/OHOS capability files changed materially since `6916842`; current status requires renewed design review. Historical recommendation is not proof of a present defect or mandatory extraction. |

Do not close an item using only an unchanged blob, a file-count trend or green C1.
Reassess affected consumers when a pilot reaches their contract; avoid expanding a
native text-reader task into unrelated original-client repairs.

## Current limits and completed pilot

[L0 PR #36](https://github.com/austery/legado/pull/36) merged as
`c6b61c38fee4d32d69cfe333ed7cc69edc247b96`, including this maintenance baseline and
the H1/H2 Issue contract. Its UI-validation routing follow-up is tracked in
[Issue #38](https://github.com/austery/legado/issues/38).

The approved real pilot was upstream integration, not the earlier speculative
SwiftUI warning repair. [Issue #41](https://github.com/austery/legado/issues/41)
records H1, scoped compatibility decisions, validation/review, explicit merge
authorization and owner-accepted H2; it is closed.
[PR #42](https://github.com/austery/legado/pull/42) merged as
`61562bc558d76d901a854f79136d28e9077a2781`, integrating KMP upstream
`d31c0a270e7c8610e9679dbbda5a6bee06927952`.
[PR C1](https://github.com/austery/legado/actions/runs/39945338204) and
[merged C1](https://github.com/austery/legado/actions/runs/39946619743) passed separately.
See [integration decisions and recovery limits](evidence/2026-10-22-upstream-d31c0a2.md).
These new revisions do not replace the old B/U pair in the inventory above.

Hosted simulator responsiveness, physical-device reading comfort, live sources,
distribution and broad original-client/platform acceptance remain separate evidence.
The historical publishing-during-view-update warning is not claimed fixed by this
pilot. It remains a candidate for a separately approved task with a fresh reproducer;
no speculative UI repair or new pilot is authorized here.
