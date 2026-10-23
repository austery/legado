# L0 validation map

This is an entry to existing validation, not a new CI policy or merge authorization.
Commands, job dependencies and runner selection are defined in
[the C1 workflow](../.github/workflows/c1-engine.yml); consult it at the candidate
revision rather than copying commands from an earlier run.

## Environment and execution

Use an ARM64 Mac, full Xcode with the selected iOS Simulator runtime, JDK 21 plus
the JDK 17 build-logic toolchain, the Gradle wrapper, Android SDK for project
configuration, Python 3.9+ and XcodeGen. Exact CI versions and setup are in the
workflow. See [engine reproduction](../engine-ios/README.md#reproduce).

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
| Durable save, interruption or offline restart | Separate workflow `native-process` job using the product driver's process-only mode | Synthetic process interruption, not physical power loss or all platform lifecycle behavior. |

The required aggregate `C1 engine regression` accepts only success from both jobs.
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
