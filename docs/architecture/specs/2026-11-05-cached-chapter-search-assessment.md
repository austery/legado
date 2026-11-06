# Cached chapter search: upstream characterization and proposed native boundary

Date: 2026-11-05, America/Toronto.
Status: seven characterization tests pass; proposed shared-contract budget awaits owner assessment.

## Owner boundary

Lei selected cached-chapter search after PR #64. The owner asked to verify upstream search against original-text coordinates before choosing the minimum integration, to prefer existing implementations, and to add no database table. Final independent review must use Antigravity Opus 5.5 or Gemini 4. This authorization covers the characterization and proposal. It does not approve a new shared interface, persistence change or later PR merge.

Baseline: merged PR #64, `033969f346db94b3d60bed97f820dd44334bb922`. Integrated KMP upstream: `d31c0a270e7c8610e9679dbbda5a6bee06927952`. No upstream upgrade is included.

## First verification boundary

The JVM characterization calls `SearchContentViewModelShared.searchChapter` and `searchAllChapters`. It uses real Room, SQLite, JvmBookStorage and ContentProcessorShared. A local HTTP listener counts any requests to the synthetic source. Existing book progress is compared before and after search. Tests do not invoke live sources or user databases.

Cases cover title insertion, title removal, length-changing replacement, Chinese and supplementary Unicode characters, literal/non-overlapping matching, partial cache coverage, missing bodies, cancellation and changed cache bodies. An identity-text processor is an explicitly injected diagnostic seam; its results do not establish an implemented native search route.

Configuration is a fail-closed fixture with only the fields needed by the real processor. Providers without a public reset use reflection only in fixture teardown to restore their exact prior nullable state. Each fixture closes its database, cancels its scope, stops its listener and deletes its owned directory. ContentProcessorShared registers a small title-cache set in a process-wide registry without a public removal API; this retained fixture state is bounded by the test worker lifetime. No production cleanup API is added for this test.

The existing empty-query guard is in SearchContentScreenModel, outside the shared search method. Runtime coverage of that UI guard, native cancellation/generation, stale-result refusal and the eventual navigation journey remains to be added to the implementation contract. No model capability flag or injected identity body proves actual Swift behavior.

## Results and minimum proposal

Seven JVM tests passed at `8dc4728c663c0b1d2c7a947a4028edbc79140974` with no failures or skips. The final candidate adds a direct check against NativeBodyCoordinates.paragraphStart. Final regression and review receipts are recorded separately at their exact candidate SHA.

| Observation | Consequence |
| --- | --- |
| Title insertion changes original UTF-16 offsets 5/12 to 15/22. Title removal changes another original offset 13 to 10. | A constant title-length correction cannot restore original coordinates. |
| A replacement creates `needle` hits absent from the original. Traditional-to-simplified conversion creates a `繁体` hit absent from the original. | Some processed hits have no original literal match. Do not translate these hits into native locations. |
| The injected original-body path returns literal, non-overlapping UTF-16 offsets, including Chinese text after an emoji. | Reuse the upstream matching and snippet algorithm on the original cached body. The injection itself is not a native implementation. |
| Cached search follows catalog order and skips missing bodies. The synthetic source receives zero requests. | Reuse catalog/cache access. Report actual coverage instead of treating missing text as a searched chapter with no matches. |
| Cancellation after the first published chapter prevents reading the next. A new search reads changed cache text. | Retain cancellation and add native generation checks. Upstream results alone cannot reject a stale navigation request. |
| The persisted shared Book row is unchanged. | Searching need not change shared progress. Native resume/bookmark state still needs implementation-level assertions. |

The first run failed in five fixture teardown assertions. The expected Book object had lazily initialized an in-memory read configuration during processing. The persisted row had not changed. The fixture now compares separate persisted before/after snapshots, retaining full-row equality. Failed logs and XML remain part of the evidence.

### Proposed minimum integration, pending H1 assessment

1. Search only the current shelf book's cached chapters, in catalog order. Match the original cached body literally and case-sensitively. Exclude titles, replacement rules, conversion, regular expressions, other books and downloads. Blank input starts no search.
2. Extract only the existing pure matching/snippet logic into the lower data module. Both the upstream search model and native adapter call it. Keep upstream processed-text behavior unchanged. Do not make engine-ios depend on the UI module, replace a process-wide provider, or fork parsing/source rules.
3. Add two bridge operations: search cached chapters and open a verified hit. Search returns typed results plus coverage and completion status. Each hit carries exact source/book/chapter identity, original-body version, SHA-256, UTF-16 length and match range. Keep all results in memory. Reuse existing NativeBodyCoordinates and cache-only reading paths.
4. Bound each request to 200 hits. Show an explicit truncated state when more matches exist. Distinguish no matches, no cached text, partial coverage, cancellation and failure. A new query or book change cancels the old task and invalidates its generation; obsolete batches cannot update the view.
5. Before opening a hit, recheck identity, cached body fingerprint and literal range. Reject stale or missing text with a rerun action. Do not fetch or silently jump elsewhere. Use the existing paragraph coordinate for navigation; highlight the exact match in that paragraph. Search itself writes no progress. A successful explicit navigation uses the existing guarded resume path.
6. Add one search sheet and an entry from the reader. Reuse existing loading/error patterns and current-chapter highlighting where compatible. Keep existing current-chapter find behavior intact.

Budget: one shared pure helper, two bridge operations and their typed DTOs, one native sheet. Zero new tables, migrations, dependencies, persistent indexes or search history. Shared-interface changes require owner assessment under ADR-002 before production implementation. If the extraction cannot preserve upstream behavior in this budget, return the trade-off to the owner.

Acceptance must cover literal/Unicode parity, partial and missing caches, visible truncation, empty query, cancellation and stale generations, changed-body/source rejection, zero search network requests, unchanged native persisted state during search, and an actual simulator search-to-hit navigation journey. JVM characterization does not establish these future native behaviors.

## Review and delivery gates

Antigravity CLI is installed as `~/.local/bin/agy`. Its live model list includes `claude-opus-5-5-high` and `gemini-4-argon-high`. Review targets an immutable characterization/proposal candidate and its evidence. This review cannot certify unimplemented product behavior. Product H2, owner approval of the proposed shared-interface budget and explicit approval for any later PR merge remain separate.
