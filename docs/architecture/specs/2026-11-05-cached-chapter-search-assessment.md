# Cached chapter search: upstream characterization and proposed native boundary

Date: 2026-11-05, America/Toronto.
Status: characterization authorized; results and implementation contract pending.

## Owner boundary

Lei selected cached-chapter search after PR #64. The owner asked to verify upstream search against original-text coordinates before choosing the minimum integration, to prefer existing implementations, and to add no database table. Final independent review must use Antigravity Opus 5.5 or Gemini 4. This authorization covers the characterization and proposal. It does not approve a new shared interface, persistence change or later PR merge.

Baseline: merged PR #64, `033969f346db94b3d60bed97f820dd44334bb922`. Integrated KMP upstream: `d31c0a270e7c8610e9679dbbda5a6bee06927952`. No upstream upgrade is included.

## First verification boundary

The JVM characterization calls `SearchContentViewModelShared.searchChapter` and `searchAllChapters`. It uses real Room, SQLite, JvmBookStorage and ContentProcessorShared. A local HTTP listener counts any requests to the synthetic source. Existing book progress is compared before and after search. Tests do not invoke live sources or user databases.

Cases cover title insertion, title removal, length-changing replacement, Chinese and supplementary Unicode characters, literal/non-overlapping matching, partial cache coverage, missing bodies, cancellation and changed cache bodies. An identity-text processor is an explicitly injected diagnostic seam; its results do not establish an implemented native search route.

Configuration is a fail-closed fixture with only the fields needed by the real processor. Providers without a public reset use reflection only in fixture teardown to restore their exact prior nullable state. Each fixture closes its database, cancels its scope, stops its listener and deletes its owned directory. ContentProcessorShared registers a small title-cache set in a process-wide registry without a public removal API; this retained fixture state is bounded by the test worker lifetime. No production cleanup API is added for this test.

The existing empty-query guard is in SearchContentScreenModel, outside the shared search method. Runtime coverage of that UI guard, native cancellation/generation, stale-result refusal and the eventual navigation journey remains to be added to the implementation contract. No model capability flag or injected identity body proves actual Swift behavior.

## Results and minimum proposal

Pending executable results. Do not copy processed-text offsets into the native reader or change global provider configuration to bypass this boundary.

## Review and delivery gates

Antigravity CLI is installed as `~/.local/bin/agy`. Its live model list includes `claude-opus-5-5-high` and `gemini-4-argon-high`. Review will target an immutable candidate and the resulting evidence. Product H2, a concrete implementation budget and explicit approval for any later PR merge remain separate.
