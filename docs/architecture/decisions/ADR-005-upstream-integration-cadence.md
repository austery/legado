---
specId: ADR-005
title: Upstream Integration Cadence
status: accepted
creationDate: 2026-11-08
lastUpdateDate: 2026-11-08
relatedSpecs: [ADR-001, ADR-002]
---

# Upstream Integration Cadence

## Approval

Lei approved this direction in the Claude Code session on 2026-11-08 ("按照建议做").
The approval covers the cadence and triggers below. It does not authorize a
new workflow, a scheduled job, or any merge; each of those still needs its own
approval.

## Context

This product depends on the KMP upstream for the reading runtime and source
compatibility, and will for a long time
([ADR-001](ADR-001-native-experience-and-upstream-ownership.md)). The upstream is
`huajideshutiao/legado`, the parent of this fork. On 2026-11-08 it looked like
this:

- One person writes almost all changes. Of the 660 upstream commits from
  2026-09-01 to `83657e548`, 656 carry the maintainer's author names (`薯条`,
  `huajideshutiao`).
- There is no published roadmap: the repository has no milestones.
- It changes daily: about three commits a day in late October 2026.
- It publishes a release about twice a month (tags such as `3.26.110111` on
  2026-11-01 and `3.26.100113` on 2026-10-01).
- One integration can be large. PR #68 (merge commit `c23dc76de`, upstream
  `83657e548`) changed 539 files and removed about 100,000 lines. It also changed
  two inherited workflows, `ios.yml` and `sync-quickjs-ng.yml`.
- This repository integrated upstream about every one to two weeks
  (2026-10-15, 2026-10-22, 2026-11-06). On 2026-11-08 it was level with
  upstream `83657e548`.

The rules for *how* to integrate already exist:

- the North Star non-goal "not chasing the latest upstream";
- [ADR-002](ADR-002-engine-boundaries-and-upstream-validation.md): validate a
  candidate in isolation, keep the last validated revision, do not patch core
  parsing privately;
- the [impact radius map](../../agents/impact-radius.md): every upstream
  integration merge is Trunk and an Always stop, and its `.github/` changes are
  reviewed on their own.

What was missing is *when* to integrate. Without a rule, two failures are
likely: long gaps that make each merge huge, or merges that only chase the
newest commit.

## Decision

### Dry-run on each upstream release

When upstream publishes a release, an AI session test-merges the mirror
(`master`) into a throwaway branch from `native-reader` and runs C1 there. It
does not open a merge PR. It reports:

- the upstream range and commit count;
- files changed, and merge conflicts by path;
- `.github/` changes and the state of the inherited publishing guards (see the
  impact radius map);
- whether the Room schema version or any Structure path moved;
- which Trunk paths the merge touches, and the C1 result.

The report goes to Lei as a short summary. The throwaway branch and its
resources are removed afterwards.

### Integrate only on a trigger

A real integration PR starts only when one of these holds:

1. Lei wants an upstream capability (the upstream-first rule in `AGENTS.md`).
2. Upstream fixes a security or compatibility problem that affects this app or
   community sources.
3. The lag exceeds about two weeks of upstream changes, so the next merge stays
   reviewable.

Each integration PR follows the existing process: an H1, isolated validation
and recovery per ADR-002, the impact radius map's checks, and Lei's explicit
merge approval.

### If upstream stops

If upstream stops changing or disappears, this repository stays on the last
validated revision. Community source rules are maintained mostly outside the
runtime, and the original Android Legado remains active, so reading is not
affected in the short term. A longer stop is a reason to reassess under
ADR-001's escalation policy. No action is taken now.

## Alternatives

| Option | Assessment |
| --- | --- |
| Merge every upstream commit or release | Chases the newest upstream, which the North Star rules out, and spends review effort on changes with no value here. |
| Merge only when something breaks | Lets the gap grow until one merge is too large to review; conflicts accumulate unseen. |
| Dry-run each release, integrate on a trigger | Selected. Conflicts and inherited-workflow changes become visible early; merges stay small enough to review; Lei decides only whether to merge. |

## Consequences

- Each dry-run uses the shared self-hosted runner, about twice a month. It must
  follow the runner rules (machine lock, fixture ports).
- How the dry-run starts is not decided here. Today an AI session runs it when
  asked or when it notices a new upstream release. A scheduled job or new
  workflow is a CI change and needs Lei's separate approval.
- The two-week threshold is a starting point. Change it in this ADR when the
  dry-run reports show a better value.
