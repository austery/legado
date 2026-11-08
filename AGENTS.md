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
check: `uv run --no-project --with-requirements scripts/path-c/requirements-doc-links.txt python scripts/path-c/doc_links.py`. ADRs live in `docs/architecture/decisions/`, a Structure path.

## Upstream-first features

Before designing a feature, storage change or engine export, trace how the
integrated KMP upstream already does it. Shared `data`/`core` helpers and the
original Compose UI under `ui/` are the reference implementation. Record the
upstream path:line, or the search that found none, in the H1. Build the slice
as a narrow export over that path. A new table, schema migration or parallel
implementation of an upstream capability needs Lei's explicit decision, stating
why the upstream path cannot serve. Policy and reasons:
[ADR-001](docs/architecture/decisions/ADR-001-native-experience-and-upstream-ownership.md#owner-confirmed-policy-round-1-2026-10-13).
