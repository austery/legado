# SPEC-009: Native in-chapter find

Date:2026-10-25. Status: Implemented; PR59 is DRAFT again while review E01 remains open. Local5ed restores direct-landscape input and has two terminal2/2 passes plus an intermittent900-second confirmation timeout; later callback tracing identifies a keyboard-animation callback imbalance, while no production fix is established. Remote84c23a8c0 C1 success remains revision-bound. Copy follow-up is separated under owner-approved H3 (Issue58); owner H2 and explicit no-merge hold remain. Lei approved the entire proposed H1 in this chat on2026-10-25; no feature code/tests had changed at approval.

## Outcome

While reading a loaded novel chapter, find a word or phrase, see its occurrence count, and explicitly move between occurrences in both portrait scrolling and landscape two-page reading.

## Source baseline and rationale

Product/remote native-reader:bcf99c6e193e954a586f8d0f8e094c6c25d9bf9d, merged bookshelf PR55. Current integration sourcec1d2da9 has an identical tree. PLAN-005 coverage row5 lists text search alongside now-delivered shelf management. It is a candidate rather than an already approved feature. Existing ReaderScreen passes the loaded chapter body/identity to ReadingText; AnchoredTextView preserves original UTF-16 coordinates and paragraph restoration. Native selection and controls were previously accepted and must retain their behavior.

Relevant sources: native-ios-app/Sources/NativeReaderApp.swift:70,414; native-ios-app/Sources/ReadingText.swift:110,321; docs/architecture/specs/PLAN-005-native-ui-feature-expansion.md:72. These establish feasibility and integration seams, not an executed prototype.

## H1 — owner-approved observable contract

1. A visible reader action named Find in chapter opens a compact query panel. It operates on the complete currently loaded chapter, including text beyond the visible page/spread. It is explicit about this scope.
2. Literal, case-sensitive queries produce non-overlapping occurrences in original-body order. No regular expressions, spelling expansion or source-body normalization. Chinese, Latin text, punctuation and emoji must use valid original UTF-16 ranges.
3. Typing/editing a query computes count/highlights without automatically navigating or saving reading progress. Empty input clears results and disables navigation; no matches shows an explicit empty state.
4. Previous/Next explicitly selects an occurrence and reveals it; show the selected occurrence number and total. Navigation wraps at the first/last occurrence. Source/book/chapter identity and valid UTF-16 boundaries must be checked before applying a result.
5. Explicit result navigation is an intentional reading action and follows the existing accepted paragraph-position save/failure flow. Merely opening/closing the panel, highlighting or relayout must not create reading progress. Closing removes find UI/highlights but does not undo an explicit jump.
6. Portrait and two-page landscape use the same full chapter result list. Rotation and typography reflow preserve the selected occurrence when the same chapter is active; highlights must not alter body text, interfere with native selection/Copy or become independent saved coordinates.
7. Leaving the reading session or changing source/book/chapter closes and clears transient find state; late computation cannot reveal or save a result in a different chapter. No search history or query/result persistence.
8. Find uses loaded content and makes no chapter/source network request. Existing reading, shelf/groups, source switching, cache and failure/retry controls remain usable.

## Complexity budget

Zero new tables, schema migrations, dependencies, engine exports or KMP/runtime changes. Swift owns transient query/result/highlight/navigation state. Reuse the existing reading token, UTF-16/text layout and save coordinator. Add only the narrow presentation interface needed to reveal/highlight original text ranges. A requirement for broader storage/engine contracts triggers owner reassessment before implementation.

## Exclusions

Whole-book/cross-chapter search, automatic chapter fetching, search across cached books, replacement rules, bookmarks, notes, history, nested product settings, new media/formats, backup/sync and distribution are not part of this slice. The proposal does not decide against future whole-book search; that needs a separate scope and coverage contract.

## Acceptance and recovery

- Public behavior tests cover empty/no-match/repeated queries and original UTF-16 ranges with Chinese/Latin/emoji/punctuation, including boundaries near paragraphs and page splits.
- Actual iPad-simulator controls: open a loaded long chapter -> enter a query occurring off-screen -> count -> explicit Next/Previous -> verify highlighted original occurrence and visible location -> portrait/landscape -> typography reflow -> close -> reopen/relaunch with the accepted saved paragraph. Assert typing/highlighting alone does not change durable progress.
- A second actual journey covers no matches/clear, native selection/Copy, chapter/source change and stale results, and a rejected position save after an explicit result jump. Preserve existing failure/negative/count gates; no parallel test harness.
- Use the validation map's applicable C1 and risk-selected UI regressions on immutable revisions; review validator changes independently. These are synthetic simulator checks, not physical-device/live-source/natural-use acceptance.
- Transient find state is disposable; no persistent format is changed. Intentional result navigation can change the existing saved paragraph. Cancel/close is not data undo. Save failure uses the existing retry/discard decision and must preserve readable content.

## Delivery gates

Owner H1 approval -> task-owned feature branch based on current native-reader -> implementation and focused actual UI evidence -> independent review and exact-head C1 -> PR. Owner H2 and explicit merge approval remain separate. No new continuous goal is started by this proposal.

## Current execution state

Basebcf99c6e193e954a586f8d0f8e094c6c25d9bf9d; task branchcodex/chapter-find. Remote PR59 remains84c23a8c0 with its4-job successful C1, and is DRAFT/unmerged again. Local5ed restores the exact direct-landscape input order; two canonical main/direct invocations passed2/2, but a separate four-method confirmation reproduced idleness waits and timed out. Temporary diagnostic patches were preserved then restored; later callback tracing locates a keyboard-animation synchronization failure, but no production fix is retained. E01 remains open and this local continuation is unpublished, with no new-head C1 claim. Narrow5ed independent code review: Standards0/Spec0 deviations; that does not certify the failed confirmation. Existing allowed Swift/view/NativeReaderUI seams, paragraph recovery limits and zero engine/schema/dependency budget remain. Risk: intentional navigation writes existing progress; closing is not undo. Owner H2 and explicit no-merge hold remain. See the evidence ledger for exact sources, mixed results and diagnostic limitations.

## H2 — owner assessment

Pending runnable preview and Lei's normal/failure-journey and value/maintenance assessment. Simulator success does not supply H2 or physical-device acceptance. **Merge authorization: explicitly withheld.**

## Implementation clarification: latest intentional reading action

The selected occurrence identity/query survives reflow while the chapter remains active. A later manual scroll/page turn is a new intentional reading action and supersedes the earlier temporary reveal focus. Subsequent reflow follows the latest accepted reading paragraph; Next/Previous can explicitly reveal the retained result again. This preserves H1.8 existing reading behavior and H1.5 intentional-position authority, without adding a new persistence contract. The standard-review P2 interleaving was reproduced by a real UIKit paging/reflow test before the narrow fix.


## H3 — owner-approved Copy follow-up

On2026-10-25 Lei explicitly answered: keep this scope and follow up the Copy menu separately. Native selection must remain usable; this slice does not certify that the touch Copy menu appears or writes the clipboard. The pre-feature baseline reproduction and remaining obligation are tracked in https://github.com/austery/legado/issues/58. The prior native Copy criterion is superseded only to this extent; no engine/storage budget expansion, timeout relaxation or merge authorization is granted. The actual no-match/clear/selection/save-failure/chapter-retirement journey retains its other assertions. Its Copy-menu assertions move to the separately tracked reproduction at source9268b1c15; no passing Copy claim is made. The earlier landscape timeout remains preserved evidence; the subsequent canonical landscape recovery journey passed with the unchanged deadline and assertion set. The later [keyboard diagnostic report](../../evidence/2026-10-25-chapter-find-e01-keyboard.md) locates the animation-idleness mechanism, with no established repair; this does not certify every gesture order or physical-device behavior.


## External review E01 current state

Review-v1: https://github.com/austery/legado/pull/59#issuecomment-6405269726. Accept the direct-landscape input evidence gap. Local5ed now rotates before opening Find/typing with original failure/retry/chapter assertions and900-second driver deadline. Two clean main/direct runs passed; a fresh four-method confirmation reproduced animation-idleness waits and timed out. Temporary existing-host contrasts were saved and removed without a production fix. The same original observer later passed again, so no experimental change is attributed as a fix. E01 remains open, PR stays draft, and no continuation is pushed while acceptance is incomplete. The later [keyboard diagnostic report](../../evidence/2026-10-25-chapter-find-e01-keyboard.md) confirms a deallocated keyboard animation state with one missing stop callback in both an independent app and the actual reader, corresponding to XCTest counter1. Focus/material reverse controls do not establish a repair. E01 remains open for reliable acceptance. Neither this mixed result nor old C1 supplies owner H2 or merge permission.
