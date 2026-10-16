---
specId: ADR-002
title: Engine Boundaries and Upstream Validation
status: accepted
creationDate: 2026-10-16
lastUpdateDate: 2026-10-16
relatedSpecs: [ADR-001, SPEC-004]
---

# Engine Boundaries and Upstream Validation

## Context and approval

The native Swift UI consumes the real Kotlin engine through our exported bridge
and native adaptation layer. We reuse upstream source execution while owning the
reading experience, identity selection, navigation and durable resume requirements
described in [ADR-001](ADR-001-native-experience-and-upstream-ownership.md).
Compilation proves that components connect; it cannot establish compatible runtime
behavior, cancellation ordering, persistence or a usable reading journey.

On 2026-10-16 the owner approved recording these principles and strengthening the
existing boundaries. `accepted` follows ADR-001's repository convention and refers
to that decision. It does not claim approval of particular code, independent review,
merge, deployment or fresh device acceptance. Execution evidence belongs to the
implementation report and test results at their exact revisions.

## Decision

Before developing a feature, identify the dependencies and behavior it relies on.
Reuse existing checks and add the smallest necessary boundary evidence for the
actual risk. Keep upstream engine reuse and our UI responsibilities explicit.
Before updating upstream, validate the candidate in isolation against the retained
usable version; preserve its source revision and the applicable recovery path.
Changing persisted data may prevent a simple code rollback and needs human review.

For each relied-on behavior, distinguish:

| Basis | Required treatment |
| --- | --- |
| Upstream documented promise | Cite the exact upstream document and revision; check the consumed interface and behavior. |
| Behavior observed at a fixed revision | Record the executable observation and its limits; do not promote it to an upstream promise. |
| Our adaptation assumption | Name its owner and protect the requirement locally where necessary. Seek clarification if correctness still depends on an undocumented guarantee. |

Our `ReaderModel` generation checks reject stale detail/TOC completions after A is
replaced by B. That is our navigation invariant, not evidence that upstream promises
zero callbacks after cancellation. The bridge, engine scheduling and upstream runtime
have separate responsibilities. Questions about callback threads, cancellation
completion, close/restart lifetimes and errors versus empty results must be resolved
from cited promises or bounded tests; unresolved assumptions remain visible. This
decision introduces neither Pact/Broker nor a new testing dependency, and authorizes
no upstream messages or issues.

Classify a failed check before changing anything: an intentional upstream contract
change, an upstream regression, or an incorrect assumption/adaptation on our side.
Record the old/new behavior and smallest reproduction. Do not relax assertions,
remove tests or redefine expected behavior merely to obtain a green run. Prefer a
bounded local adaptation when it preserves the approved journey. Stop for human
assessment before changing data formats, public/shared contracts or core reading
semantics, or before spreading changes broadly into upstream code.

## Actual reuse boundary and maintenance cost

The source is vendored in this repository, not a floating remote runtime dependency.
The integration record pins KMP upstream to `04f62774a5406a37979dacaf3b5fd5b87c71fcc9`
([integration evidence](../../evidence/2026-10-15-upstream-sync.md)); our
`native-reader` revision includes subsequent local adaptations. Git revisions fix
what was tested, but do not establish a stable upstream library API or a promise
that arbitrary future upstream changes will remain compatible.

`native-ios-app/Sources/ReaderModel.swift` consumes our `ReaderEngine` snapshots,
requests and acknowledgements. `engine-ios/src/iosMain/kotlin/io/legado/engine/ReaderEngine.kt`
owns that export, translates failures and coordinates native shelf/resume writes.
`EngineHost.kt` registers process-wide providers and source leases. The engine
reuses rule analysis, networking, JavaScript and Room/storage from `core`, `data`
and `foundation`; it does not embed the upstream Compose screens.

There is still internal coupling: `IncrementalSearch.kt` imports `SearchScope`
from `io.legado.app.ui.book.search` and wraps `SearchModel.CallBack`, freezing
mutable results while SearchModel owns its result lock. `ReaderEngine.kt` relies
on existing book/chapter models, native DAOs and cache semantics. Provider
registration in `EngineHost.initialize()` has process-wide state and ordering.
These are compatibility dependencies at a pinned revision, not upstream promises.
The stable UI-facing behavior is our responsibility. A facade limits Swift exposure
but does not remove this coupling or its ongoing merge and regression cost.

Directory names are not isolation evidence. The following responsibilities are
already implemented and should be checked against approved requirements:

| Meaning | Current authority |
| --- | --- |
| Exact source entry | `ReaderEngine` resolves source/book/chapter IDs; `ReaderModel.select` passes the exact candidate. A book URL alone is insufficient without source validation. |
| Cross-source work grouping | `IncrementalSearch.publish` groups exact nonblank title/author pairs, preserving individual source/book candidates; missing authors stay separate. This is our search projection, not universal literary equivalence. |
| Shelf reuse/deduplication | `data/.../dao/NativeShelfDao.addToShelf` prefers exact source/URL, then an unambiguous known title/author match; it preserves the existing active source, catalog and progress. Shared `BookDao` is another writer requiring compatibility review. |
| Reading position | `NativeResumeDao` validates guarded writes/projection; `ReaderEngine` checks identity, token, fingerprint and revision; `NativeBodyCoordinates` defines canonical UTF-16 paragraph coordinates; Swift TextKit converts the visible paragraph to that coordinate. A visual page number is not persisted position. |

These policies follow ADR-001 and the existing SPEC-004/native journey requirements.
They are not inferred from upstream folder names or copied from a reference reader.
The reference product supplies selected observed journeys; active-source replacement
and cross-source location matching remain outside this slice. An ambiguous phrase
such as “relative value of a book” has no definition here and authorizes no semantic
change. Changes to equivalence, deduplication or position interpretation need a
specific requirement and human decision before implementation.

Current focused tests can characterize these dependencies and protect our adapter;
they cannot manufacture an upstream guarantee or prove the architecture optimal.
Small adaptations are appropriate only while requirements and failure propagation
remain bounded. Retain the last validated version and stop an upgrade for human
assessment when undocumented lifecycle assumptions cannot be protected locally,
core behavior fails reproducibly, or adaptations repeatedly spread into upstream
writers/models. Automatically following the newest upstream revision is not a goal.
This decision does not authorize extracting an architecture or changing a public API.

## Evidence and scope

| Evidence | What it establishes and what it does not |
| --- | --- |
| Unit test | Local decisions and failure handling under controlled inputs; a fake writer is not a real transaction. |
| Interface/behavior compatibility check | A particular consumed promise or assumption holds across a defined boundary at tested revisions; not every boundary test is a contract test. |
| Cross-module integration/timing test | Real bridge, scheduling, storage or adaptation interactions satisfy observable identity, order and recovery requirements in the tested scenario. |
| Hosted view test | The app view renders and connects selected actions/state to the model in a test host; not an end-to-end user tapping journey. |
| End-to-end UI test or device walkthrough | Actual UI operations and system interactions exercised by that run, with platform and revision limits; does not imply every failure path was tested. |
| Build/link | Types, symbols and build configuration connect; no runtime behavioral claim. |

Contract describes the agreement or property being checked; integration describes
which real components are combined. The two can overlap. Semantic assertions such
as source/book/chapter identity and persisted paragraph position are required where
relied upon; a schema check alone cannot establish them. No framework automatically
proves all business semantics, timing or recovery.

Choose targeted checks and necessary regression suites from changed dependencies,
failure propagation and recovery risks. Do not default to revalidating every
platform or reviving deferred acceptance work. Record skipped, failed and unrun
checks explicitly. Tests should demonstrate that corresponding protection failures
are observable, where practical using temporary isolated mutations restored before
publication. Coverage percentage is not the acceptance goal.

## Alternatives and consequences

| Option | Assessment |
| --- | --- |
| Trust compilation or visual similarity | Insufficient evidence for identity, timing and durable progress. |
| Rebuild upstream capabilities or run every platform for each change | Adds maintenance and validation cost without a demonstrated boundary need. |
| Reuse the engine with explicit responsibilities and risk-driven evidence | Selected; requires maintaining focused checks and documenting assumptions. |

The benefit is sustainable upstream integration with inspectable product behavior.
The cost is maintaining fixtures and tests as real dependencies evolve. Local
protection cannot silently redefine a shared contract. Commands, suite inventories
and operational safety checks live in testing documentation rather than duplicating
them in this long-lived decision.

## Decision history and related evidence

| Date | Decision | Scope |
| --- | --- | --- |
| 2026-10-16 | Owner accepted the principles and authorized bounded ADR/test/tool implementation. | Concrete implementation remains subject to independent review; no merge authorization in this task. |

- [Native product test guidance](../../../native-ios-app/README.md#validation-status).
- [Path C test tooling](../../../scripts/path-c/README.md).
- [SPEC-004](../specs/SPEC-004-multi-source-search-and-candidates.md).
