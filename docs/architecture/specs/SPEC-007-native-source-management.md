---
specId: SPEC-007
title: Native Source Management
status: Implemented
priority: P1 - Core Feature
creationDate: 2026-10-21
lastUpdateDate: 2026-10-21
owner: User (AI-Assisted)
relatedSpecs:
  - PLAN-005
  - SPEC-004
  - SPEC-006
tags:
  - native-reader
  - source-management
---

# SPEC-007: Native Source Management

Owner-approved implementation scope, 2026-10-21: reuse upstream source rules and persistence, with Wanyuan Reader as the interaction reference. See [source-management investigation](2026-10-21-source-management-investigation.md) for upstream behavior, native gaps, and the reasons for the approved group and import policies. Postmerge CI attempt 2 also failed during simulator startup; the merged validation baseline remains unresolved.

## 1. Goal

Let readers inspect and control their imported text sources without reimporting files to recover disabled sources or accidentally replacing working rules.

## 2. Verified baseline

Inspected merged revision: `daa5ce0e5f96f36bc0bdac805d1f1cda4a1ca9a0` (PR #32).

- `engine-ios/src/iosMain/kotlin/io/legado/engine/ReaderEngine.kt:180-205`: listSources exposes only enabled text sources. Import decodes all objects first, then silently replaces existing identities; the last duplicate in a file wins.
- `native-ios-app/Sources/NativeReaderApp.swift:220-245`: the Sources page provides file import, refresh and an enabled-source list. There are no management toggles or conflict preview.
- `data/src/commonMain/kotlin/io/legado/app/data/dao/BookSourceDao.kt:145-175,227-244,273-286`: existing persistence exposes full source parts, group metadata and enable/group mutations. Reuse it rather than adding a second registry.
- `data/src/commonMain/kotlin/io/legado/app/model/webBook/WebBook.kt:91-115` supports discovery execution through isSearch=false. Discovery categories, pagination and interactive verification still need a separate native UI contract.

PR-head C1 passed. The first merged-head C1 failed before native test execution because its cloud simulator boot exceeded 180 seconds; shutdown/delete also timed out. The independent process-restart job passed. The second attempt passed 107 Kotlin Native tests but timed out starting the Swift product simulator before tests began. Startup diagnosis remains open; no timeout or assertion has been weakened. Do not treat the merged baseline as verified until that run succeeds.

## 3. Approved first delivery

1. Show all imported text sources, including disabled ones. Display name, identity, existing groups and enabled state. Filter by name/identity, enabled state and existing group; preserve selection across view-only filtering.
2. Enable or disable individual sources and explicitly selected batches. Persist changes through KMP. Disabled sources disappear from new search and source-switch candidate discovery, while their rules, shelf entries, cached chapters and resume records remain intact. Existing cached reading remains available; uncached requests explain that the source is disabled.
3. Preview local JSON import before mutation: new identities, replacements, disabled entries and duplicate identities. Follow upstream defaults: select new identities and versions with a newer lastUpdateTime. Show timestamps as advisory, not proof of changed rules. Allow explicit replacement selection. Preserve existing custom order and, by default, local name, group, enabled and discovery-enabled settings; expose these retention choices in the preview. Preserve the current last-object-wins rule for duplicates only after exposing it in the preview. Parse/schema failures and cancelled previews make no persistent changes. Confirmed imports are atomic; if affected identities change after preview, require a refreshed preview.
4. Export explicitly selected source configurations through the system file/share interface. Use the existing supported Legado source schema, including disabled state and groups; do not export runtime cookie jars, book data or reading history. Configuration fields such as configured headers remain source configuration and must not be silently stripped. Define supported-field round-trip behavior; do not promise byte-identical or unknown-field preservation without evidence.

5. Add and remove group membership for individual or selected sources using upstream separator parsing and normalized comma-separated storage, normalized and deduplicated. Groups are filters, not a second source registry.

Default layout: searchable source list, enabled/all/disabled and group filters, import, direct enable switches. Selection mode exposes batch enable/disable, group membership and export. Source details hold identity and configuration information. Source deletion, rule editing/debugging, login/browser interaction, subscription updates, discovery browsing and bulk network checks remain subsequent slices, not permanent exclusions from PLAN-005. Do not label unimplemented controls as working.

The owner confirmed Wanyuan Reader as the visual/interaction reference. Existing verified reference evidence should inform layout; report any missing current-screen evidence without inventing fidelity claims.

## 4. Lifecycle and authority

- Swift presents typed snapshots and explicit actions; KMP and the existing source database own mutations. No schema migration, second source store or new identity convention.
- Source enable/replacement operations retire affected search/cache work before mutation. Late callbacks cannot revive disabled sources, write stale bodies or change candidate selection. Define cross-engine coordination using the existing engine boundary and verify it behaviorally.
- Changing rules or enabled state never changes a shelf book's source identity or resume. It never clears an existing chapter cache implicitly.
- Read-only filtering/export must not cancel reading or write progress. Return to the displayed chapter at the same paragraph.
- Reject stale import confirmation rather than overwriting a source changed after preview. Report concrete committed results and errors.

## 5. Simulator acceptance

- [x] Enabled/disabled list, filters and batch selection remain usable in portrait and landscape.
- [x] Group additions/removals survive relaunch; filters and selection remain consistent after membership changes.
- [x] Enable state survives process relaunch; search includes only enabled text sources.
- [x] Disable a source with a held request: no late search/cache publication, saved reading position unchanged.
- [x] A disabled source's verified cached chapter opens offline; missing text gives an actionable disabled-source error.
- [x] Preview/cancel, malformed input, duplicate identities, explicit replacement and stale confirmation obey their contracts.
- [x] Injected persistence failure leaves the pre-import source set unchanged.
- [x] Export/reimport preserves supported rules, identity, enabled state and groups without runtime session data.
- [x] Existing source switching, offline caching, protected clearing, resume and global typography regressions remain green.
- [x] Run real Swift/KMP and actual iPad simulator UI flows and independent review.
- Exact-head required C1 is an acceptance gate; use the task PR check runs as its current authority. Physical-device acceptance is separate and has not been performed.

## 6. Delivery sequence

Implementation is authorized. Use an isolated task branch from the merged baseline. Update this specification first, implement the typed management boundary, list/toggle/filter/group UI, transactional import preview and selected export. Investigate simulator startup with retained diagnostics, and require passing product validation before PR publication. Required C1 must pass at the exact PR head before acceptance. Keep the primary checkout and user data intact. Publish the verified task PR; merging requires applicable authorization.

## 7. Status history

| Date | Status | Note |
| --- | --- | --- |
| 2026-10-21 | Implemented | Owner-approved scope implemented; local product, iPad UI, interruption and restart acceptance passed. Required C1 is tracked on the task PR. |

## 8. Local acceptance

Implementation and simulator evidence are recorded in [the acceptance report](../../evidence/2026-10-21-source-management/acceptance.md).
The final local product run passed 60 tests, actual iPad UI passed 10 journeys,
all four process-interruption boundaries passed, and offline restart passed.
Required C1 remains an explicit PR gate; these local results do not claim hosted CI success.

## 9. Approved CI execution policy (2026-10-21)

The owner approved routing automatic PR/push C1 through the existing complete local
profile while hosted simulator responsiveness remains unresolved. Explicit manual
cloud execution remains available for diagnosis; its dispatch default is unchanged.
Both regression jobs, exact-head checkout, original test commands/timeouts and the
required `C1 engine regression` aggregate remain unchanged. Local evidence retains
the existing seven-day upload policy. An unavailable local runner leaves checks
pending rather than falling back or passing. No service restart, global configuration
change, branch-protection change or PR merge is authorized by this policy adjustment.
Acceptance still requires the new PR head's associated automatic C1 to pass; an older
head or manual profile result is not sufficient. Hosted failure logs remain evidence
of an unresolved infrastructure issue, not a claimed product fix.
