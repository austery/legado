# Bounded development and upgrade loop

Date: 2026-10-22
Status: Scoped delivery complete; owner H2 accepted 2026-10-23 (reconciled 2026-10-23)
Goal owner: Lei

## Outcome

Make one real Legado feature or upstream/dependency upgrade traceable from an
owner-approved boundary through independent review and exact-revision validation
to an owner understanding check, without creating a second maintenance project.

Preserve upstream runtime reuse, our native reading experience, and sustainable
maintenance. This plan does not finalize the wording of the north-star draft.

## Completed delivery (2026-10-23)

[PR #36](https://github.com/austery/legado/pull/36) landed L0, the maintenance and
critical-dependency baseline, and the H1/H2 Issue template as
`c6b61c38fee4d32d69cfe333ed7cc69edc247b96`. Its independent review is recorded in
that PR; [Issue #38](https://github.com/austery/legado/issues/38) retains a separate
nonblocking UI-validation routing follow-up, not an unlanded L0 prerequisite.

[Issue #41](https://github.com/austery/legado/issues/41) records the approved real
pilot: upstream integration delivered in [PR #42](https://github.com/austery/legado/pull/42),
merged as `61562bc558d76d901a854f79136d28e9077a2781`. It records H1, bounded adaptation
decisions, independent review, local validation, successful exact-head PR and
merged-head C1, explicit merge approval and owner H2 acceptance on 2026-10-23.
The slice is closed; physical-device, live-provider and distribution evidence remain
outside it. Focused regression tests were added for the integration; no new CI gate
or recurring automation was introduced. The existing C1 gate was retained; no
automation expansion is proposed by this reconciliation. Final north-star wording
and acceptable recurring maintenance effort remain a separate owner decision.

## Historical observed starting point (2026-10-22)

- Product baseline: `0240d065e305b054927a12e6ab8386ad3992abd2`.
- Integrated upstream: `c66940d6a91916fa5fdf43a4dfe9ae63e2b7ea8b`, verified as an ancestor.
- L0 candidate: [PR 36](https://github.com/austery/legado/pull/36), head
  `e5d2ac218856671d679aae852aa15c65a51735f9`; open, CI running/queued and no reviews
  at inspection. Publication is complete; landing and independent acceptance are not.
- Existing required aggregate protects runtime/product/process regressions.
  GitHub does not currently enforce reviewer identity, reviewed SHA or H1 budgets.
- `git diff --name-status <upstream> <product>` reports 145 additions, 81 modifications
  and two renames. These include tests and infrastructure; they are raw inventory,
  not a risk score or an approved patch budget. The seven-file README inventory is historical.
- No open project Issues were returned at inspection. Existing deferred findings
  still need reconciliation against their source reports and current code.

## Approved delivery

### L0 landing prerequisite

Review PR 36 against the current workflow and drivers, record independent findings,
repair only supported issues, and check its exact-head required CI. Merge only with
applicable explicit authorization; verify merged-head results separately. Do not
restart or reconfigure a runner to accelerate completion.

Completion criterion: the entry is on the product branch, its links resolve, blocking
review findings are closed and PR/merged-head validation states are recorded without
conflation. Nonblocking follow-ups remain explicitly tracked (Issue #38).

### 1. Establish one maintainable baseline

Create one repository maintenance record with a pinned upstream/product pair and
reproducible inventory command. Distinguish modifications to upstream production
files, native additions, tests/fixtures, build/CI and documentation. Include known
coupling, unresolved findings and missing evidence; investigate their current state
before carrying historical items forward as active debt.

In that record, map critical dependency groups (KMP toolchain, QuickJS/native bridge,
Room/SQLite and HTTP/storage boundaries) to current versions, real acceptance lanes,
limits and rollback constraints. Confirm actual consumers before final classification.
Record recoverable source/tool versions separately from persisted-data compatibility.
No dependency upgrade is implied by documenting this matrix.

Done: another session can reproduce the inventory and identify the applicable lane
and recovery limits for a proposed upgrade. Counts have no arbitrary pass threshold.

### 2. Add the smallest H1/H2 contract

Use one GitHub Issue per real slice, with a concise reusable template:

- H1: user outcome, north-star connection, completion criteria, allowed persistent
  structures/boundary changes and why they are worth their cost, exclusions, exact
  authorization scope, acceptance lane and rollback limits.
- Execution: current PR/head, reviewed base/head, independent verdict, stable finding
  IDs/dispositions, CI references and unrun evidence. Current state stays in the body;
  dated transitions belong in comments.
- H3: owner decision for new design intent, unknown recovery, reviewer disagreement,
  changes to validation meaning or exceeded budget. Two failed repair/review rounds
  stop automatic continuation for a decision.
- H2: cumulative changes against H1, maintenance/upgrade burden, open debt, and the
  owner's explanation of one normal journey and one failure/recovery journey.
  Record continue, narrow or simplify. An agent cannot attest to owner understanding.

Changes to tests are not automatically forbidden: distinguish adding coverage from
weakening existing assertions, fixtures, suite membership or gate semantics. Make
validation changes visible to independent review; altered acceptance meaning needs
an owner decision rather than silently changing the success criterion.

Done: the template is usable without copying workflow commands or creating a
parallel authorization system. No shared/global rules or rulesets change.

### 3. Exercise one real slice

After the baseline, select a bounded real product defect/feature or upstream update
with owner approval. Do not manufacture a dependency update or treat a documentation
PR as proof of runtime acceptance. Do not retroactively label PR 35 an H1-approved pilot.

Run H1 through implementation, independent review, applicable exact-head CI, authorized
merge and H2. Record manual interventions and reasons. End with an explicit decision
on whether any deterministic check is worth adding; creating more automation is not
a success criterion.

Done: one actual slice has the complete evidence chain and owner H2 conclusion.
If no suitable slice is approved, record the pilot as pending; do not claim the goal complete.

## Complexity and authority budget

Proposed additions: this plan, one maintenance/acceptance record, one Issue template
and minimal links from L0. Use the pilot Issue for execution evidence. Add no service,
database, controller, scheduled job, package dependency or global skill modification.

No blanket automatic merge authorization is introduced. For every PR in this goal, request
explicit owner merge approval.
Plan approval is not approval of a yet-unselected pilot's functional design or merge.

Exclude deployment, runner/system upgrades, changing branch protection, global
PERSONAL-REPO-AUTOMATION policy, live-provider actions and wholesale CI redesign.

## Owner confirmation

Lei confirmed: establish the current baseline, then H1/H2, then select a real pilot.
Every merge still requires his explicit approval. This authorizes baseline/template
implementation, not an unselected upgrade or an agent-authored H2 acceptance.

## Current progress (2026-10-23)

- [x] Goal created and existing CI/PR state inspected.
- [x] Draft plan and raw baseline comparison prepared.
- [x] Owner confirms this plan.
- [x] L0 independently reviewed and landed with evidence.
- [x] Maintenance and critical-dependency baseline reconciled.
- [x] H1/H2 Issue contract published.
- [x] Real pilot selected and H1 approved.
- [x] Pilot reviewed, validated and merged with authority.
- [x] Owner H2 recorded; goal completion checked.

## Historical read-only evidence while approval was pending (2026-10-22)

At L0 head `e5d2ac218856671d679aae852aa15c65a51735f9`, version catalog
entries are Kotlin 2.3.20, KSP 2.3.11, Compose Multiplatform 1.11.1, Room 3.0.1,
SQLite library 2.7.0 and Ktor 3.5.2. These are declared library versions, not
independently resolved binaries or runtime certification. `AppDatabase.kt` declares
schema 91. OHOS selects its separate toolchain through `enableOhosTarget`; therefore
the Dependabot comments describing the whole toolchain as an Alipay baseline are
not a reliable description of the default iOS configuration. The ignore rules do
exist. Reconcile policy rationale and actual consumers before proposing any update.

The QuickJS vendoring README states that sync overwrites vendored files and does
not replay local patches. Its recorded patch inventory must be checked against the
actual tree before using sync; a documented empty patch section is not byte-level
verification. This is a specific recovery concern for the planned dependency matrix.

PR 36's exact head and base remain unchanged, with no submitted reviews. Run
`39824694996` has the interruption job in progress and regular regressions queued
at the latest read. No runner intervention or new CI dispatch was performed.
