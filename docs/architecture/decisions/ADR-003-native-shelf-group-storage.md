---
specId: ADR-003
title: Native Shelf Group Storage
status: accepted
creationDate: 2026-10-24
lastUpdateDate: 2026-10-24
relatedSpecs: [ADR-001, ADR-002]
---

# Native Shelf Group Storage

Reuse the existing KMP book-group records and book membership mask for the native shelf. The owner accepted this boundary in Q10 on 2026-10-24 after reviewing [the pinned source assessment](../../evidence/2026-10-24-bookshelf-reuse.md). The accepted product vocabulary is in [GLOSSARY.md](../../../GLOSSARY.md).

The existing representation supports the agreed flat, non-exclusive groups and avoids a new persistence format and its migration and upstream-integration costs. Accept at most 63 custom groups using positive single-bit IDs; do not allocate the sign bit, which existing membership queries cannot recognize correctly. Unlimited groups and nested containers do not justify replacing storage for this slice.

Native presentation and narrow exports still need implementation. Necessary guarded writes must preserve reading records while applying the accepted shelf and group membership rules; existing upstream whole-record updates and multi-step callbacks are not sufficient evidence of safe native failure behavior. Characterize real storage and bridge behavior before claiming acceptance. Changes remain subject to ADR-002 and the repository validation map.

This architectural decision alone does not authorize implementation, a schema migration, merge or changes to unrelated upstream consumers. Principal interaction choices are recorded in the source assessment. The subsequent execution scope, H1, owner-confirmed test seams and pending H2 are published in [Issue #51](https://github.com/austery/legado/issues/51); merge still requires Lei's explicit approval for the resulting PR.
