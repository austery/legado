# Bookshelf grouping reuse assessment

Date: 2026-10-24. Static source inspection only; no runtime characterization, build or tests were run.

Implementation scope and acceptance are now published in [Issue #51](https://github.com/austery/legado/issues/51), labeled `ready-for-agent`. The owner confirmed the test seams during to-spec synthesis. This source assessment preserves the earlier discussion; the Issue is the current execution contract. No feature implementation was performed in the specification session.

Product base: `3d62b46320c3aba7fd00635d8473804a2c028a3f`.
Integrated upstream inspected: `d31c0a270e7c8610e9679dbbda5a6bee06927952`.
This record captures design discussion, not implementation or merge authorization.

## Owner decisions

- A shelf entry may belong to multiple flat groups. There are no nested groups.
- Home contains group entries and ungrouped books; grouped books appear inside their groups.
- Removing a book from its last group makes it ungrouped. Deleting a group preserves its books and reading records.
- New shelf entries are ungrouped. Removing a book from the shelf ends all group memberships but retains its reading record. Explicitly adding it again preserves that record and starts ungrouped.
- Trial reading and caching do not imply shelf admission. Book caching and source management remain separate concerns.
- A book's group assignment uses a multi-selection checklist opened from its context menu; clearing all selections makes it ungrouped. Inside a group, offer a direct remove-from-this-group action.
- Support basic book multi-selection and select-all for group assignment, removal from the current group and removal from the shelf. Invert-selection and interval-selection are outside this agreed interaction scope.
- Support both cover-grid and list presentation with a user-controlled switch. The owner selected both modes (Q13 C); a grid-only first delivery is not the agreed scope.

Canonical vocabulary is in [GLOSSARY.md](../../GLOSSARY.md).

## Reuse findings

The following existing upstream paths were compared with the product base. `BookGroup`, `BookGroupDao`, `GroupViewModelShared` and `BookshelfScreen2` have no differences at those revisions. Book and BookDao have existing native identity adaptations; grouping fields and the cited grouping query semantics remain available.

| Requirement | Source evidence | Assessment |
| --- | --- | --- |
| Flat, non-exclusive membership | `data/src/commonMain/kotlin/io/legado/app/data/entities/Book.kt:92`; `data/src/commonMain/kotlin/io/legado/app/data/entities/BookGroup.kt:11`; `data/src/commonMain/kotlin/io/legado/app/data/dao/BookDao.kt:57` | Existing group records and membership bit mask represent this without a new schema. |
| Groups and ungrouped books at home | `ui/src/sharedUiMain/kotlin/io/legado/app/ui/bookshelf/BookshelfScreen2.kt:108` | Existing upstream presentation combines groups and root books. Native Swift presentation still needs implementation; upstream Compose screens are not embedded. |
| Delete group without deleting books | `ui/src/commonMain/kotlin/io/legado/app/ui/book/group/GroupViewModelShared.kt:108`; `data/src/commonMain/kotlin/io/legado/app/data/dao/BookDao.kt:255` | Existing behavior deletes the group and clears its membership bit. Its two writes are not wrapped in a transaction here; native failure behavior needs its own characterization and guarded operation. |
| Retain reading record on shelf removal | `data/src/commonMain/kotlin/io/legado/app/data/dao/NativeShelfDao.kt:120` | Existing native operation marks the book off-shelf. This is our adaptation, not upstream management-page deletion. |
| Re-add without restoring groups | `data/src/commonMain/kotlin/io/legado/app/data/dao/NativeShelfDao.kt:179` | Current reuse restores the shelf flag without clearing groups. The accepted behavior needs a bounded native write change. |
| Native group controls | `engine-ios/src/iosMain/kotlin/io/legado/engine/ReaderEngine.kt:40` and `:307` | Current shelf snapshots and exports lack group management. Narrow exports and native presentation are required; existing storage alone does not complete the feature. |

## Capacity and accepted decision

Membership uses a signed 64-bit mask. Positive single-bit IDs provide 63 usable custom-group positions. `BookGroupDao.kt:55` allows a nominal 64 records, and `:73` allocates by shifting; the sign-bit ID is incompatible with queries requiring positive intersections at `BookDao.kt:57` and positive group IDs at `BookGroupDao.kt:61`. A zero-ID record can also consume the count allowance without representing a usable group.

Owner accepted Q10 on 2026-10-24: reuse the existing representation, allocate only valid positive group bits, and report capacity exhaustion rather than introducing new storage to promise unlimited groups. The scope is native presentation, narrow exports and necessary guarded writes. This is a source-derived limit, not runtime acceptance evidence or authorization to repair unrelated upstream consumers. Implementation and merge remain unauthorized by this discussion.

No schema change appears necessary for the agreed behavior. This remains a design assessment until real storage/bridge failure-path and UI validation are performed under the repository validation map.

## Discussion stopping point

On 2026-10-24, the owner accepted Q11 and Q12 and selected Q13 C, then asked whether remaining detail warranted more discussion. Core relationships, storage reuse and principal interactions are settled sufficiently to stop the interview. Menu placement, icons, spacing and similar reversible presentation choices can be evaluated in a concrete UI review. No additional interview answers or implementation authorization are inferred from stopping. A reviewable H1 must still define bounded delivery, defaults, acceptance and recovery before implementation; owner confirmation of that boundary and explicit PR merge approval remain separate.
