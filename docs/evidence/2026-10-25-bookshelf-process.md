# Bookshelf process interruption and offline restart evidence

Date: 2026-10-25. Parent specification: Issue #51; acceptance ticket: #54.
Base: `ebe2189e09e897f79b3583b498a3cd8e4237390e`. These runs exercised this child working-tree patch before its final commit. Final integration and exact-head C1 evidence remain separate.

## Changed validation contract

The existing interruption driver now declares six default boundaries: the original `before-file`, `after-file`, `before-db` and `after-db`, plus `group-before-db` and `group-after-db`. The normal process-only lane selects every default boundary without a narrowing `--case` argument. Existing host validation, invocation-owned simulator checks, missing-boundary rejection, no-acknowledgement check, external termination, changed-PID verification and exactly-one-passing-verifier requirement remain intact. No timeout or existing assertion was relaxed.

The group operation is a real ReaderEngine group deletion: a book starts in two named groups, and deletion must both remove one group record and clear its membership while retaining the other group. Before-commit preparation holds the existing SQLite writer-lock boundary. After-commit preparation observes both committed changes through a separate connection while MainActor blocks the acknowledgement. The existing driver terminates that owned test process and a new process verifies the complete original or committed organization, the retained reading revision, chapter and cached body. This does not simulate physical power failure or termination at every internal statement; separate real-storage rollback tests cover failed multi-write transactions.

The existing separate-process offline shelf journey additionally creates two groups, assigns one book to both, persists IDs/names in its fixture manifest and verifies them after restart with its source disabled. Cold launch remains at shelf home, grouped books are not duplicated there, entering a group finds the same book, and opening it retains the group navigation context and saved paragraph. Original offline/cache/typography assertions remain.

## Executed evidence

- Driver coverage RED: `/private/tmp/bookshelf-process-driver-red.log` failed because CLI help lacked the two group boundaries; the same ownership/CLI suite subsequently passed four tests.
- Genuine runtime RED: `/private/tmp/bookshelf-process-boundary-red` records one failed preparation with `Unknown interruption boundary`, before engine initialization or network access. It used the unchanged pre-extension Swift suite with `group-before-db`, not an infrastructure failure.
- Fresh private test-host compilation passed after correcting asynchronous XCTest assertion syntax. Logs: `/private/tmp/bookshelf-process-build-green2.log` and the final process driver's fresh `build.log`.
- Full existing Python fixture/driver suite passed **61 tests** in `/private/tmp/bookshelf-process-python.log`.
- `/private/tmp/bookshelf-run-20261025.sh python3 scripts/path-c/native_product_ci.py --output /private/tmp/bookshelf-process-green-20261025 --process-tests-only --runtime-version 27.0` completed successfully. Its `interruption/results.json` contains six verified boundaries, each with different preparation/verification PIDs and a nonzero intentionally interrupted prepare exit; each verification `.summary.json` has one pass, zero failures and zero skips.
- The same command's `shelf-restart/results.json` records successful preparation and offline verification. Both independent phase summaries have one pass, zero failures and zero skips.
- Final driver ownership/CLI checks passed after adding explicit type annotations; `/private/tmp/bookshelf-process-driver-final.log`. `git diff --check` passed.

Toolchain was process-local Xcode 27.1, simulator runtime iOS 27.0 and XcodeGen 2.46.0. The existing native simulator framework was copied with unchanged Kotlin production-source provenance from storage commit `86184361379469df1cc4c2fa4e9cd4b8b1623de7`; this child changes no production code, schema, dependency or source runtime.

## Resource inventory and limits

- Child workspace: `/private/tmp/legado-bookshelf-process-20261025`, branch `codex/bookshelf-process`, from the base above. Root owns integration and post-integration worktree reconciliation.
- Invocation-owned RED, product-build, interruption and restart simulator IDs are recorded in `/private/tmp/bookshelf-process-simulator-cleanup.json`. All four were absent after the drivers' `finally` teardown, verified against the current device registry.
- All logs, result bundles, manifests and private DerivedData are retained outside the child under `/private/tmp/bookshelf-process-*`. The fixture servers and test-host processes exited; fixture lanes 18769 and 18771 were released to the integrating agent. The working tree retains only reproducible generated project/framework files and Python bytecode in addition to committed source.
- No owner database, existing simulator, physical iPad, shared runner service or global developer configuration was modified. This is synthetic simulator evidence, not physical-device comfort, live-provider acceptance, production backup or owner H2 acceptance.
