---
specId: SPEC-008
title: Native Discovery and Category Browsing
status: In Progress
priority: P1 - Core Feature
creationDate: 2026-10-21
lastUpdateDate: 2026-10-22
owner: User (AI-Assisted)
relatedSpecs: [PLAN-005, SPEC-004, SPEC-007]
---

# SPEC-008: Native Discovery and Category Browsing

Owner-approved on 2026-10-21: implement the confirmed discovery proposal, update Specs first,
validate in the simulator, run complete C1, independently review and create one task PR.
Continue this as one goal until verified merge readiness.
On 2026-10-22 the owner authorized repairing the identified upstream Native JS context boundary
first, then merging this delivery after complete gates and independent review. This supersedes
the original do-not-merge instruction for this task; it does not authorize unrelated core changes
or upstream communication.
Baseline: `68f6ab619452dc21c853a1cc3ae38b7085f680f7` (merged PR33).

## 1. Product outcome

Enable readers who do not know a book title to browse a source's categories/rankings and
follow Discover -> source -> category -> paginated books -> existing details/catalog ->
trial reading or explicit shelf admission. Keep Discover distinct from Sources management.
Use the established native UI style; retained Wanyuan evidence is incomplete and does not
establish exact Discovery-screen parity. No invented recommendations, cover/update metadata
or nonworking controls. Bookmarks and in-book text search remain the next candidate slice.

## 2. Approved scope

1. Add an independent Discover destination beside Library, Search and Sources. List text
   sources with source-name/address and group filters in existing custom order. Explain
   no-source/no-discovery/disabled states and provide a working route to management.
2. Keep source enabled and enabledExplore separate. Eligible browsing requires enabled text
   source, enabledExplore and a discovery entry. Source disable retains the native all-network
   disable contract (SPEC-007); upstream flowExplore only filters enabledExplore/hasExploreUrl.
   Expose discovery visibility through the existing enabledExplore persistence, without toggling
   source enabled or changing custom order, source rules, shelf identity or progress.
3. Reuse BookSource.exploreKinds() for string/JSON/JS-produced category lists. Preserve headings;
   show explicit unsupported states for action-only script buttons, arbitrary plugin forms or
   browser-dependent entries rather than treating their script as a URL. Treat upstream ERROR
   entries as failures, never navigation destinations or empty-success results. An initial real
   KMP probe must characterize these forms before feature development relies on them.
4. Reuse WebBook.getBookListAwait(isSearch=false), BookListPager and upstream URL option parsing
   for ordinary category browsing. Support native selection for upstream enumerated URL options
   when exposed; reset the listing on category/source/option replacement. Publish resolved options
   before request completion: a failed first request must retain choices needed to recover, and an
   obsolete URL resolver must not restore a replaced category's filters. No independent parser.
   Dynamic forms outside the existing enumerated rule-option model remain explicitly unsupported.
5. Refresh, load more/end-of-list, retry and cancellation work. A failed later page preserves
   loaded books and the failed page/cursor; retry cannot skip it. Preserve continuation URLs,
   deduplicate by exact source/book identity and follow upstream duplicate-only end-of-list rules.
6. Reuse existing exact-book details, catalog, trial reading and shelf operations. Returning from
   details/reading retains discovery source/category/list context and scroll position where the
   view survives. Discovery browsing must not replace an existing shelf entry/source or write
   reading progress. Existing accepted reading-save guards remain authoritative.
7. Source/category/option replacement, cancel, leaving discovery and engine close retire obsolete
   work. Source changes (disable/import/replacement/discovery visibility), including from another
   engine, visibly terminate obsolete loading and prevent late categories/results/cache writes.
   Completed books may remain visible as incomplete results; pagination must be disabled after
   invalidation. Silent local retirement must not deliver stale terminal updates to a new session.
8. Show loading, empty, unavailable, cancelled/incomplete, network/rule and interaction-required
   states truthfully. Repeated equal failures must leave loading and permit retry. Login/captcha
   and background WebView remain their current typed INTERACTION_REQUIRED/UNSUPPORTED boundary.

## 3. Authority and cache lifecycle

Swift owns UI/navigation and consumes immutable typed snapshots. Our engine-ios adapter owns
native discovery sessions, source resolution, request ownership and result registration. Upstream
KMP retains source parsing, JS/HTTP execution, category parsing and pagination. No schema migration,
second source registry or alternate core parser. Register/reuse the existing native category-cache
provider through EngineHost; invalidate category caches on source-rule replacement (including the
same source identity/unchanged category URL). Cancelled old work cannot repopulate stale caches.
Do not hold EngineHost.gate while waiting for a discovery network/script worker to finish; source
mutation and externally visible terminal delivery must not deadlock each other.

## 4. Initial capability characterization

Pin observations to this baseline. Observe real KMP plain/JSON/JS category parsing, headings and
script-button representation, malformed-vs-empty behavior, URL options, discovery-rule selection,
normal/continuation pagination and duplicate-only stopping. Include cancellation/cache behavior
where upstream catches errors. These are bounded observations, not promises about arbitrary
community sources. Record any unsupported native host interaction explicitly. No core-rule fixes
or upstream messages are authorized beyond the bounded exception below; apply ADR-002 otherwise.

## 5. Acceptance

- [ ] Eligible source listing, source/group filters and independent discovery visibility persist.
- [ ] String/JSON/JS categories, headings, malformed categories, empty and unsupported actions have
      distinct useful UI states; no error stack trace or action script is followed as a URL.
- [ ] Real discovery uses ruleExplore, including upstream enumerated options, ordinary pages,
      continuation URLs, duplicate-only stopping and exact-identity result registration.
- [ ] Failure/retry preserves earlier pages and retries the same cursor; refresh resets intentionally.
- [ ] Held source/category/option replacement and cancellation block late publication.
- [ ] Another engine's source disable/import produces visible terminal state and cannot restore
      stale categories/results/cache entries, including identical source ID/category URL updates.
- [ ] Details/catalog/trial-read/add-to-shelf/return/relaunch preserve exact source identity and
      existing shelf/progress; browsing does not implicitly admit a book.
- [ ] Actual iPad portrait/landscape UI journeys and screenshots cover principal and failure states.
- [ ] All existing native reading/search/source/switch/cache/global-preference tests remain green.
- [ ] Complete automatic C1 at the final PR head passes both original jobs and required aggregate;
      no assertion, skip gate, timeout or required check is weakened. Publish one reviewed PR.

## 6. Deferred slices and evidence boundaries

Authentication/WebView/captcha UI, arbitrary plugin discovery/filter forms, pinned/favorite discovery
entries, source editing/debugging/deletion, personalized recommendation feeds, bookmarks, in-book
search, local formats and TTS remain subsequent slices, not permanent full-feature exclusions.
Controlled simulator sources do not certify live community sources or a physical device.
Use the approved complete local automatic C1 profile; hosted startup diagnosis remains independent.
Preserve the primary checkout, user data, unrelated tasks and shared caches. Record exact owned
simulator UUIDs and remove them after retaining each run's evidence. Keep the active PR checkout.

## 7. Owner-approved Native context exception (2026-10-22)

A real category-script browser rejection became RULE instead of INTERACTION_REQUIRED because
Native runScriptWithContext did not propagate its coroutine context when no thread-local JS scope
existed. After diagnosis and the ADR-002 human-assessment boundary, the owner authorized fixing
this upstream Native context entry before merging the delivery. Establish a temporary owned scope
only for a missing entry scope; preserve/restore borrowed scopes, nested contexts, operation-local
failures and cancellation. Do not replace category parsing, source-rule semantics or data formats.
Protect caught/uncaught rejection, nested restoration, concurrent operation isolation and cooperative cancellation
in host helpers with real Native regressions, retaining all product assertions and C1 gates.
The implementation is shared Native code; iOS simulator evidence does not establish OHOS acceptance.
Merge requires complete exact-head C1, simulator acceptance and final independent review, followed
by bounded finish-branch cleanup.
