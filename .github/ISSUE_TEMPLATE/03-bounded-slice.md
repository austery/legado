---
name: Bounded native-reader slice
about: Define H1 scope, revision-bound evidence and the owner's H2 decision.
title: "[Slice] "
labels: ''
assignees: ''
---

## H1 — owner-approved boundary

- User outcome and north-star connection:
- Observable completion criteria:
- Complexity budget: allowed persistent structures, shared contracts and dependencies; why each is worth its maintenance cost. State zero where appropriate:
- Explicit exclusions:
- Acceptance lanes and what they cannot verify (see `docs/VALIDATION.md`):
- Recovery method, evidence and limits for both code and written data:
- Owner approval reference (actual message/comment, identity and date; leave pending until given):
- Authorized implementation scope:
- Merge authorization: **requires Lei's explicit approval for this PR**. H1 approval does not authorize merging.

## Current execution state

Keep this section current. Record dated transitions in comments.

- Development session and approved source requirement:
- PR and exact base/head SHAs:
- Risk: Door (Two-way = demonstrated recovery of code and written state; One-way = irreversible or impractical recovery; Unknown = insufficient evidence) / Radius (Leaf = contained component; Branch = named related consumers with demonstrated containment; Trunk = shared or cross-subsystem behavior). Record consumers, failure propagation and unknowns:
- Independent reviewer, reviewed base/head, verdict and report:
- Findings: stable ID → blocking/nonblocking → disposition → evidence:
- Local validation, exact-head required CI, and unrun lanes:
- Validator changes (assertions, fixtures, suite membership, thresholds, gate semantics) and independent justification; write none if absent:
- Owner merge approval reference and actual merge SHA (pending until confirmed):
- Merged-head CI (separate from PR evidence):

## H3 — exceptions

Stop the affected work for an owner decision if scope/budget expands, data recovery
is unknown, review disagrees, acceptance meaning changes, or two repair/review rounds
fail to close the findings. Adding coverage is not itself a forbidden validator
change; weakening the criterion requires explicit assessment. Record the decision
and its scope here, linking the owner message. Do not infer approval from agent text.

## H2 — owner understanding and value check

- Delivered outcome against H1:
- Cumulative changes: persistent structures, upstream modifications, adaptation decisions and deferred debt relative to `docs/MAINTENANCE.md`:
- Maintenance effort / manual interventions and reasons (unknown is not zero):
- Agent's short normal-journey and failure/recovery explanation, with evidence:
- Owner's assessment: can I explain both journeys, and is the maintenance burden worth the result?
- Owner decision and reference: continue / narrow / simplify:
- Remaining obligations and follow-up owner:

H2 remains pending until the owner supplies their assessment. A green check or an
agent-authored explanation cannot complete it. Close the slice only when its
promised outcome, review dispositions, required validation, approved merge and H2
are accounted for; otherwise retain the missing obligation explicitly.
