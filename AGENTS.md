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
