# Required reading journeys and deferred features

Date: 2026-11-06, America/Toronto.
Status: Priorities confirmed by the owner in conversation on 2026-11-06.

This checklist is the "required user journeys" item of the accepted north star. It lists which features the native reader must have, which wait, and which are out of scope. It does not approve any implementation. Each required item still needs its own H1 Issue under the [bounded delivery contract](PLAN-legado-bounded-delivery-loop.md), its own acceptance and an explicit merge approval.

Inputs: the [upstream feature reuse inventory](2026-11-05-upstream-feature-reuse-inventory.md), the owner's local Wanyuan feature survey (not committed to this repository) and merged native deliveries up to PR #66 (`7e05dfb96`).

## Product scope

- Target device: iPad. iPhone is not a formal target.
- Distribution: personal sideloading only. No App Store or TestFlight distribution is planned, so the product does not need an App Store positioning change.
- Wanyuan Reader is a reference for gaps, not a parity target. This follows the north-star clarification of 2026-10-23.

## Delivered journeys to protect

Future work must not regress these journeys. Each one has its own delivery evidence.

| Journey | Delivery |
| --- | --- |
| Multi-source incremental search and candidate selection | SPEC-004 |
| Book details, catalog filter and current-chapter position | PR #30 |
| Continuous reading, persisted global typography | PR #30 |
| iPad landscape two-page reading | [PR #47](https://github.com/austery/legado/pull/47), PR #63 |
| Reading controls and native text selection | [PR #49](https://github.com/austery/legado/pull/49) |
| Shelf admission, paragraph resume after relaunch | SPEC-003 |
| Shelf groups, grid/list, six sort modes | [PR #55](https://github.com/austery/legado/pull/55), [PR #64](https://github.com/austery/legado/pull/64) |
| Explicit source switching | [SPEC-005](SPEC-005-explicit-source-switching.md) |
| Bounded offline cache (next 20) and next-2 prefetch | [SPEC-006](SPEC-006-offline-reading-and-cache-controls.md) |
| Source management and discovery | [SPEC-007](SPEC-007-native-source-management.md), [SPEC-008](SPEC-008-native-discovery.md) |
| Source-bound paragraph bookmarks | [PR #62](https://github.com/austery/legado/pull/62) |
| Current-chapter find and cached-chapter search | [SPEC-009](SPEC-009-native-in-chapter-find.md), [PR #65](https://github.com/austery/legado/pull/65) |
| Manual new-chapter check for one shelf book | [PR #66](https://github.com/austery/legado/pull/66) |

## Required (P0)

| Item | Current gap |
| --- | --- |
| Batch update check for shelf books, with update indicators | Only one book can be checked at a time (PR #66). |
| Whole-book download with a download queue | Manual caching stops at the next 20 chapters. |
| Paged reading in iPad portrait | Portrait shows continuous scrolling only. Spreads activate only in iPad landscape at 900 points or wider (`native-ios-app/Sources/ReadingText.swift:262`). |
| Source health check and batch validation | No native workflow detects or reports broken sources. This also supports the north-star source-resilience criterion. |
| Reverse catalog order | Not available in the native catalog. |
| Reading history | No native history of recently read books outside the shelf. |

## Important, not urgent (P1)

| Item | Note |
| --- | --- |
| Reading operation settings: keep screen on, volume-key paging, auto page, tap zones | Upstream has configuration and logic in its Compose reader. Native needs Swift UI and platform verification. |
| Typography details: background image, custom font import, header and footer | Upstream has storage directories and Compose settings. Native needs Swift UI. |
| Reading-time statistics | No native entry. |

Upstream code for a P1 item reduces work but does not prove that the item works on iOS. Verify each item through the native bridge before promising it.

## Deferred

- Progress sync between iPad and iPhone.
- Batch shelf management (move or remove many books at once).
- Traditional/simplified Chinese conversion and an eye-care mode.
- TXT and EPUB export.
- Replacement and purification rules.
- Interactive source login and captcha.
- Read aloud (TTS). Upstream has iOS implementations (`data/src/iosMain/kotlin/io/legado/app/help/tts/IosSystemTtsEngine.kt`, `HttpTtsPlayer.ios.kt`), so prefer reuse when this item is selected.
- RSS and the in-app browser.
- Local TXT import remains on `codex/local-txt-import`, paused at H3. Its priority is unchanged by this checklist.

## Removed

| Item | Reason |
| --- | --- |
| In-app backup and restore | The owner relies on iCloud device backup. The database (`legado.db`) and the chapter cache (`book_cache`) are both under the app Documents directory (`data/src/nativeMain/kotlin/io/legado/app/help/storage/NativeDataStorage.native.kt:15`), which iCloud device backup includes. Deleting the app still deletes this data; reinstalling over an existing build keeps it. |
| App Store positioning as a plain TXT reader | Not needed while distribution is personal sideloading. Reassess if distribution changes. |

## Physical-device trial status

On 2026-11-06, `xcrun devicectl device info apps --include-all-apps` on the owner's iPad Air (5th generation) listed AltStore, Wanyuan Reader and Fanqie Novel, but not the native reader (`io.legado.pathc.nativereader`). The north-star 14-day physical-device trial has therefore not started. All acceptance to date is simulator evidence.
