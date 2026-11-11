# L0 validation map

This is an entry to existing validation, not a new CI policy or merge authorization.
Commands, job dependencies and runner selection are defined in
[the C1 workflow](../.github/workflows/c1-engine.yml); consult it at the candidate
revision rather than copying commands from an earlier run.

## Environment and execution

Use an ARM64 Mac, full Xcode with the selected iOS Simulator runtime, JDK 21 plus
the JDK 17 build-logic toolchain, the Gradle wrapper, Android SDK for project
configuration, Python 3.9+, uv with Python 3.13 for the Markdown link check, and
XcodeGen. Exact CI versions and setup are in the
workflow. See [engine reproduction](../engine-ios/README.md#reproduce).

C1 first runs lightweight scope/static checks on a hosted runner. An explicit
allowlist in [`c1_scope.py`](../scripts/path-c/c1_scope.py) recognizes explanatory
documents: named READMEs/agent guidance, this entry, the maintenance record,
architecture Markdown, agent guidance Markdown under `docs/agents/` and Markdown issue templates. Other paths, including test/fixture/build/workflow changes,
require full regression even when mixed with documents. Complete pinned PR and
push diffs include both sides of renames/deletions; missing comparison evidence
requires regression. Manual dispatch always requests full validation.

Documentation-only changes run routing/gate unit checks, diff whitespace, changed
inline repository links/anchors and Markdown fences, plus inbound references to
affected documents. Both heavy jobs are skipped for this mode. The required aggregate
passes only when the scope/static job succeeds and both jobs are skipped as expected;
its result explicitly says runtime regression was not applicable.
Classification/static-check failure, unknown mode, untrusted fork or unexpected job
outcomes cannot pass.

Every mode also runs the Markdown link check `scripts/path-c/doc_links.py`, built on
markdown-it-py on Python 3.13 (pinned with hashes in
`scripts/path-c/requirements-doc-links.txt`, installed only into a temporary virtual
environment). It runs after the mode is selected, so a link failure fails the
scope/static job and does not start heavy jobs that the mode skips. Every relative
Markdown link in this project's own documents must resolve to an existing file, and
absolute or `file:` links fail. It skips upstream-owned Markdown, app content and
archived files (but checks the archive index). Run it locally before publishing a
documentation change:
`uv run --no-project --python 3.13 --with-requirements scripts/path-c/requirements-doc-links.txt python scripts/path-c/doc_links.py`.

Static checks do not execute fenced examples or certify remote links, raw HTML links,
links inside image alt text, generated diagrams, machine-local paths in code spans or
plain text, a local path written as `//path` (it reads as a protocol-relative URL), or
semantic truth; AI review supplies semantic and evidence-boundary assessment.

Automatic PR/push C1 currently uses the repository's local runner. Manual cloud
execution is diagnostic; the process-interruption job still requires the local
runner. Hosted simulator responsiveness remains unresolved. An offline local
runner means queued validation, not a successful check or an automatic cloud fallback.
See [runner operation and limits](../engine-ios/README.md#c1-continuous-integration).

Use task-private build/evidence paths and invocation-owned simulators. The ordinary
product and interruption suites share an exclusive fixture port and run sequentially.
Use the existing drivers; preserve user simulators, apps and running services.
[Fixture and resource instructions](../scripts/path-c/README.md) describe ownership,
cleanup, interruption limits and host-path stalls. Record unavailable prerequisites
as environment blockers; they are not passing acceptance evidence.

## Choose evidence for the changed contract

| Change or claim | Existing executable evidence | Limit |
| --- | --- | --- |
| Harness/fixture orchestration | Workflow Python unittest discovery and fixture-only preflight | Does not execute the native engine or establish product acceptance. |
| Shared runtime or upstream upgrade | Both engine framework links, original UI compilation, data/core/UI JVM tests, upstream URI report validation, Kotlin Native driver | Compilation is separate from execution; these tests do not certify every upstream subsystem. |
| Native JS/network/cache boundary | Swift engine harness network, restart-cache and fresh-network suites | Real native runtime with synthetic loopback sources, not live community-site certification. |
| Native product behavior | Ordinary `native_product_ci.py` suites | Real bridge/storage and selected UI-facing assertions; not daily reading comfort or complete device acceptance. |
| Actual UI controls and navigation journeys | [UI driver](../scripts/path-c/reader_ui_ci.py), `NativeReaderUI` XCUITest scheme; [setup and evidence](../native-ios-app/README.md#minimal-reading-ui-and-actual-control-validation). Select relevant declared journeys with `--only-test` according to changed behavior and risk. | Actual controls in an isolated synthetic iPad simulator app, with screenshots and `.xcresult`; inspect screenshots as well as results. Not physical-device comfort or live-source acceptance; separate from ordinary product suites, not a universal required CI gate. |
| What a UI change looks like and how it behaves when an agent operates it | Agent-driven walkthrough of the product app on a throwaway iPad simulator, with screenshots; [recipe and limits](../native-ios-app/README.md#agent-driven-simulator-walkthrough) | Shows what an agent saw, not a CI gate. It can be the real-run evidence that the [impact radius map](agents/impact-radius.md) asks for, unless the change's risk calls for a `native_product_ci.py` suite or `reader_ui_ci.py` journey. It does not replace C1. Not live-source or physical-device acceptance. A physical-device run is final acceptance, not a per-PR step, and stays with Lei through Device Hub (the tool that operates the connected iPad). Lei decides when it runs; until then, report it as not run. |
| Durable save, interruption or offline restart | Separate workflow `native-process` job using the product driver's process-only mode | Synthetic process interruption, not physical power loss or all platform lifecycle behavior. |

For full-regression mode, the required aggregate `C1 engine regression` accepts
only success from both heavy jobs plus the scope/static job. The documented
docs-only case above is the sole deliberate skipped-job exception.
The URI and Native XML validators reject missing execution, failures and skips;
the Native validator also requires named suites. The product runner compares
executed counts with tests discovered in the candidate source. It cannot detect
all source-test deletions or prove that changed assertions remain meaningful.
See [product evidence criteria](../native-ios-app/README.md#what-counts-as-sufficient-regression-evidence).
For current process-job invocation, use the workflow; older README flag examples
are not the authority for job wiring.

## Evidence and review boundary

Record the exact candidate SHA, commands, toolchain/runtime, executed results and
unrun lanes. Distinguish local results, PR-head CI, merged-head CI and device
acceptance. Green results from an earlier head cannot certify the current one.
Check live repository rules when assessing merge eligibility; this document does
not replace them or authorize a merge.

Treat changes to assertions, fixtures, required suites, execution-count logic,
timeouts and workflow aggregation as changes to validation: identify them explicitly
in review and explain what evidence remains independent. Preserve failure and
missing/skip detection rather than weakening it to make a candidate pass. Current
CI does not independently enforce reviewer identity, reviewed SHA or design budgets.

For dependency/upstream upgrades, follow ADR-002's isolated comparison and recovery
requirements. A code revert does not establish data-format rollback safety.
The historical seven-file C1 extraction inventory in `engine-ios/README.md` is not
a current cumulative patch budget. The [maintenance record](MAINTENANCE.md) maps critical dependencies to acceptance
and recovery limits. Use the [H1/H2 contract](../.github/ISSUE_TEMPLATE/03-bounded-slice.md)
for owner-approved slices; it adds no automatic merge authorization.

Physical iPad touch/layout comfort, live providers, signing/distribution and system
permissions require their own applicable evidence and authorization. Synthetic
fixture success does not establish those outcomes.
