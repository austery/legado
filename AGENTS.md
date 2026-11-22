# Legado Native UI

## L0: validation entry

For implementation, review, or upstream/dependency upgrades, read
[the validation map](docs/VALIDATION.md) before choosing checks or claiming acceptance.
It identifies the executable gates, their prerequisites, and what they cannot prove.

For changes to engine behavior, persistence, or upstream integration, also read
[ADR-002](docs/architecture/decisions/ADR-002-engine-boundaries-and-upstream-validation.md).
Keep the tested upstream revision and recovery boundary explicit.

For feature or upgrade slices, use the [H1/H2 Issue contract](.github/ISSUE_TEMPLATE/03-bounded-slice.md)
and [current maintenance baseline](docs/MAINTENANCE.md). Record the owner's H1 before
implementation and leave H2 pending until the owner assesses the result. All merges
require Lei's explicit approval for the PR; plan approval is not merge approval.

Before publishing a PR that closes a task, follow the task closeout in
`~/Documents/global-skills/agents/DOC-LIFECYCLE.md`. Archive: `docs/_archive/`. Link
check: `uv run --no-project --python 3.13 --with-requirements scripts/path-c/requirements-doc-links.txt python scripts/path-c/doc_links.py`. ADRs live in `docs/architecture/decisions/`, a Structure path.

## Base branch

Base every task branch on `native-reader`, the product branch. `master` only mirrors
upstream. In a checkout based on the wrong branch, `native-ios-app/` is missing; stop
and create the task branch from `origin/native-reader`.

Before designing a feature or changing the UI, check `master` for overlapping
upstream changes. Pass upstream paths from the trace below, such as paths under
`ui/`, `data/` or `core/`. `master` has no `native-ios-app/` or `engine-ios/`.
`git fetch origin master native-reader && git log origin/native-reader..origin/master -- <paths>`.
No output means no unintegrated upstream commit touches those paths. If the
trace finds no direct match, search the closest relevant upstream area and
record where you searched.
Release dry-runs, when to integrate upstream, and merge and upgrade principles are in
[ADR-005](docs/architecture/decisions/ADR-005-upstream-integration-cadence.md).

## Upstream-first features

Before designing a feature, UI change, storage change or engine export, trace
the integrated KMP upstream behavior. Use shared `data`/`core` helpers and the
original Compose UI under `ui/` as references. Record the upstream path and line,
or the search that found none, in the H1 if the change requires one. Otherwise,
record the trace in the PR.

Layout-only work keeps model calls, selection, pagination rules and persistence
behavior, including saved-position computation, intact. Check upstream and use
native iOS layout conventions for this work. A separate issue is optional unless
the [impact radius map](docs/agents/impact-radius.md#review-depth) or another
existing rule requires an H1.

For engine, runtime and shared storage behavior, follow upstream by default.
Reuse existing upstream capabilities through narrow exports where needed.
Preserve the approved native rules for shelf reuse and deduplication,
cross-source work grouping and reading position in [ADR-002](docs/architecture/decisions/ADR-002-engine-boundaries-and-upstream-validation.md#actual-reuse-boundary-and-maintenance-cost).
A new table, schema migration or parallel implementation of an upstream
capability needs Lei's explicit decision, stating why the upstream path cannot
serve. Do not contradict upstream's documented
interface contracts (for example, a provider documented to throw on failure must
not return a silent default). Edit upstream-owned code only under an approved H1,
so upgrades stay mechanical.
Policy and reasons:
[ADR-001](docs/architecture/decisions/ADR-001-native-experience-and-upstream-ownership.md#owner-confirmed-policy-round-1-2026-10-13).
