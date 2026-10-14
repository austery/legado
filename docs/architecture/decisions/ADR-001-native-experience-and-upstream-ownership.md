---
specId: ADR-001
title: Native Experience and Upstream Ownership
status: accepted
creationDate: 2026-10-13
lastUpdateDate: 2026-10-14
relatedSpecs: [SPEC-001, SPEC-003]
---

# Native Experience and Upstream Ownership

Build a native iPad reading experience guided by selected Wanyuan reading journeys, while reusing the existing Legado/KMP runtime and keeping one final authority for each category of state. Optimize for useful, coherent reading and sustainable upstream integration rather than feature parity or a zero-diff fork.

The owner accepted the initial architectural boundary on 2026-10-13 after two bounded discussion rounds. That acceptance authorized recording the decision and revising the SPEC-003 draft, not implementation or a storage migration. Subsequent C3-A authorization and implementation are recorded separately in SPEC-003. On 2026-10-14, the owner confirmed the bounded MVP and evidence-triggered reassessment policy below. This revision records that policy; it does not authorize a new storage migration, runtime replacement, deployment or merge. Existing C2 acceptance is unchanged.

## Established principles

- Wanyuan is a reference for observed interaction and information organization. Its private implementation and complete feature inventory are not requirements.
- Native UI owns presentation, device text layout and interaction. The existing runtime remains responsible for source rules, networking, JavaScript and execution state. The current MVP reuses existing book, chapter and content storage with reviewed native extensions. Reusing those models does not permanently delegate product identity and resume semantics to upstream.
- UI and behavior ship as complete useful journeys. A matching screen with missing behavior is not feature completion; peripheral functionality may remain out of scope.
- Prefer existing capabilities and narrow exports. Do not introduce a second book database or duplicate parsing/business subsystems merely to simplify the frontend. One final authority per category of state prohibits competing shelf/progress writers; it does not prescribe one physical database forever. Any later separation requires its own evidence, decision and migration review.
- Source selection for searching, source selection for browsing discovery, and changing an existing book's active source are distinct operations.

## Owner-confirmed policy (round 1, 2026-10-13)

Evaluate conflicts case by case. Upstream reuse is a strong preference because the enduring value is maintained rule execution and adaptation to changing source websites. There is no blanket rule that every product requirement yields to upstream, nor permission to accept every shared-layer change. Compare concrete user value, changed responsibilities, and the ongoing cost of integrating upstream updates before deciding each exception.

The required compatibility goal is **A: continue integrating upstream code and using original community source rules**. **B: exchanging shelf/progress data with another reader** and **C: opening the modified database in an unmodified old client** are not project goals. They must not drive additional architecture merely as hypothetical future requirements. Preserving this application's existing data during its own upgrades remains required.

Runtime maintenance and community source-rule maintenance are complementary. Reusing the engine does not establish that its maintainers keep every individual website rule working. The project should avoid creating its own ongoing per-site adaptation burden.

Small native persistence extensions are permitted in principle, provided their impact on continued upstream integration is controlled and explicitly reviewed. This is not a guarantee of conflict-free merges. Identity-rule changes require separate case-by-case decisions. The original acceptance did not approve a particular resume table or identity migration. Subsequent scoped decisions and implementation evidence belong to SPEC-003; this revision does not revoke them or reduce C3-A requirements.

## Alternatives and consequences

| Alternative | Assessment |
| --- | --- |
| Reproduce Wanyuan's full product and storage design | Adds low-value scope and a competing domain model; inconsistent with the stated personal-reading goal. |
| Permit only visual changes and no shared-code differences | Minimizes literal diff but can prevent durable resume or already requested identity behavior. Not assumed to be the owner's intent. |
| Reuse the runtime with bounded native contracts and reviewed exceptions | Accepted direction; integration and migration costs remain real and must be visible. |
| Introduce independent product storage now | Deferred: the bounded MVP reuses existing storage; separation must demonstrate a concrete product or maintenance benefit and reliable recovery. |
| Rewrite the source-execution runtime now | Not selected: this would take over rule, JavaScript and network compatibility work before a necessary capability limitation has been demonstrated. |

An additive resume table changes Room schema compatibility. Avoiding a new table does not automatically avoid semantic divergence. At the original C2 baseline, unknown-author coexistence conflicted with the title/author uniqueness constraint. The merged C3-A implementation uses a reviewed index migration and guarded writes; this is a scoped product-versus-shared-model decision, not a visual detail.

## Deferred decisions

This ADR does not select a resume table, a Book column, an index migration, a checkpoint format, or an event protocol. Their scoped decisions, authorization and implementation status are recorded in SPEC-003 under the confirmed compatibility policy. Known-author duplicate additions retain the existing source/progress; missing-author entries must not silently merge. Any reduction of the previously requested coexistence behavior requires an explicit owner decision.

## Discussion boundary

The original discussion rounds and the 2026-10-14 clarification are complete. The owner confirmed bounded native storage extensions, continued upstream integration, and case-by-case review of product conflicts. No further interview is required to record this consensus. C3-A merged through [PR #8](https://github.com/austery/legado/pull/8) at `7e8c522ead9cf4b3301e8dc6fd87b42a61b2ed7f`; its [post-merge C1 Engine CI](https://github.com/austery/legado/actions/runs/38530829109) succeeded. Earlier build 4 physical-device acceptance predates the later review fixes; this publication does not claim fresh device validation.

## Bounded MVP and reassessment policy (2026-10-14)

Complete the agreed minimum reading journey: search, details, table of contents, chapter reading, bookshelf and durable resume, including reopening the saved current chapter offline. Reuse the existing runtime and implemented storage capabilities. Do not expand features or begin an additional storage redesign to preempt hypothetical future conflicts. Necessary persistence and recovery are part of the complete journey, not optional polish. Existing scoped implementation and acceptance remain valid within their recorded limits.

Evaluate actual behavior against the agreed product requirements. Similar models do not prove compatible identity or progress semantics; different models do not by themselves justify rebuilding storage. A facade can hide upstream types without removing internal writer, lifecycle or schema coupling.

Reopen the architectural decision when a reproducible core requirement is blocked by the existing model, or when bounded adaptations repeatedly spread into upstream readers/writers and make integration maintenance unsustainable. Record the specific behavior, affected paths, attempted adaptation and observed cost before choosing a larger change.

Use the smallest effective response:

1. Continue reuse when existing capabilities satisfy the frozen journey.
2. Apply a reviewed local adaptation when a conflict remains bounded.
3. Evaluate independent product models/storage when core product semantics or recurring integration cost justify it, while retaining source-execution reuse where feasible.
4. Consider replacing or rewriting source execution only when a required runtime capability cannot be supported sustainably. A bookshelf or resume conflict alone is insufficient evidence for this step.

Product storage separation and source-runtime replacement are distinct decisions. Neither is preapproved. A concrete selection of either should receive a separate ADR with alternatives, compatibility costs, data ownership and recovery consequences. Upstream is not reduced to occasional release inspiration by this MVP decision.

## Decision history

| Date | Decision | Scope |
| --- | --- | --- |
| 2026-10-13 | Accept native reading experience, runtime reuse and reviewed persistence exceptions. | Initial architecture acceptance; later C3-A authorization and evidence are recorded in SPEC-003. |
| 2026-10-14 | Prioritize a bounded complete MVP using existing capabilities; reassess separation only on concrete core limitations or recurring maintenance cost. | Clarifies state authority and escalation criteria; no new implementation, migration or merge authorization. |

## Evidence and related documents

- [SPEC-004 proposed multi-source search slice](../specs/SPEC-004-multi-source-search-and-candidates.md).
- [C3-A implementation, validation summary and limitations: PR #8](https://github.com/austery/legado/pull/8).
- [C2 native reading implementation: PR #9](https://github.com/austery/legado/pull/9).
- [C3-A post-merge C1 Engine CI](https://github.com/austery/legado/actions/runs/38530829109).

Earlier SPEC-001/SPEC-003, Wanyuan surveys, device walkthroughs and the glossary remain in the local evidence archive and are not published by this documentation change. This ADR states the governing decision directly; those archive references are supporting history, not required remote links.
