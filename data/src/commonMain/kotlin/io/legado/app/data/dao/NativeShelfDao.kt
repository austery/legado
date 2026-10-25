package io.legado.app.data.dao

import androidx.room3.Dao
import androidx.room3.Insert
import androidx.room3.OnConflictStrategy
import androidx.room3.Query
import androidx.room3.Transaction
import io.legado.app.constant.BookType
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookGroup
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.NativeReadingResume
import io.legado.app.data.entities.BookSource
import io.legado.app.utils.systemCurrentTimeMillis

/** Native shelf policy; deliberately separate from the legacy replacement writer. */
@Dao
abstract class NativeShelfDao {
    @Query("SELECT * FROM book_groups ORDER BY `order`, groupId")
    protected abstract suspend fun storedGroups(): List<BookGroup>

    @Insert(onConflict = OnConflictStrategy.ABORT)
    protected abstract suspend fun insertGroup(group: BookGroup)

    @Query("UPDATE books SET `group` = `group` & :retainedMask WHERE (`group` & :retainedMask) != `group`")
    protected abstract suspend fun retainGroupBits(retainedMask: Long)

    /** Organization tokens exclude reading progress, but include every membership authority. */
    @Transaction
    open suspend fun organization(): NativeShelfOrganization {
        val records = storedGroups().filter { isCustomGroup(it.groupId) }
        val shelf = listBooks()
        val identity = buildString {
            fun field(value: String) { append(value.length).append(':').append(value) }
            records.forEach { field(it.groupId.toString()); field(it.groupName); field(it.order.toString()) }
            append('|')
            shelf.sortedBy { it.bookUrl }.forEach {
                field(it.bookUrl); field(it.origin); field(it.group.toString())
            }
        }
        return NativeShelfOrganization(shelf, records, NativeBodyCoordinates.sha256(identity))
    }

    @Transaction
    open suspend fun createGroup(name: String, expectedToken: String): NativeShelfOrganization {
        val before = requireOrganization(expectedToken)
        val trimmed = requireGroupName(name, before.groups)
        val occupied = storedGroups().filter { it.groupId > 0 }.fold(0L) { mask, group -> mask or group.groupId }
        val id = (0..62).map { 1L shl it }.firstOrNull { it and occupied == 0L }
            ?: throw NativeShelfException(NativeShelfFailure.GROUP_CAPACITY, "The shelf supports at most 63 custom groups")
        val order = before.groups.maxOfOrNull { it.order } ?: 0
        if (order == Int.MAX_VALUE) invalidGroup("Group ordering capacity is exhausted")
        // Stale membership bits cannot become membership in a newly allocated group.
        retainGroupBits(id.inv())
        insertGroup(BookGroup(groupId = id, groupName = trimmed, order = order + 1))
        return organization()
    }

    @Query("UPDATE book_groups SET groupName = :name WHERE groupId = :id")
    protected abstract suspend fun patchGroupName(id: Long, name: String)

    @Query("DELETE FROM book_groups WHERE groupId = :id")
    protected abstract suspend fun deleteGroupRecord(id: Long)

    @Transaction
    open suspend fun renameGroup(id: Long, name: String, expectedToken: String): NativeShelfOrganization {
        val before = requireOrganization(expectedToken)
        requireGroup(id, before)
        patchGroupName(id, requireGroupName(name, before.groups, id))
        return organization()
    }

    @Transaction
    open suspend fun deleteGroup(id: Long, expectedToken: String): NativeShelfOrganization {
        val before = requireOrganization(expectedToken)
        requireGroup(id, before)
        retainGroupBits(id.inv())
        deleteGroupRecord(id)
        return organization()
    }

    private fun requireGroup(id: Long, state: NativeShelfOrganization) {
        if (state.groups.none { it.groupId == id }) {
            throw NativeShelfException(NativeShelfFailure.STALE_ORGANIZATION, "The group no longer exists; refresh the shelf")
        }
    }

    @Query("UPDATE books SET `group` = (`group` | :addedMask) & :retainedMask WHERE bookUrl = :bookUrl")
    protected abstract suspend fun patchGroups(bookUrl: String, addedMask: Long, retainedMask: Long)

    /** Only explicitly changed groups are patched; untouched mixed memberships survive. */
    @Transaction
    open suspend fun changeGroups(targets: List<NativeShelfTarget>, added: List<Long>, removed: List<Long>,
        expectedToken: String): NativeShelfOrganization {
        val before = requireOrganization(expectedToken)
        val selected = requireTargets(targets)
        val known = before.groups.map { it.groupId }.toSet()
        if (added.any { it !in known } || removed.any { it !in known } || added.any { it in removed }) {
            invalidGroup("Choose existing groups without conflicting changes")
        }
        val addedMask = added.fold(0L) { mask, id -> mask or id }
        val removedMask = removed.fold(0L) { mask, id -> mask or id }
        selected.forEach { patchGroups(it.bookUrl, addedMask, removedMask.inv()) }
        return organization()
    }

    @Transaction
    open suspend fun removeBooks(targets: List<NativeShelfTarget>, expectedToken: String): NativeShelfOrganization {
        requireOrganization(expectedToken)
        val selected = requireTargets(targets)
        selected.forEach { markRemoved(it.bookUrl) }
        return organization()
    }

    private suspend fun requireTargets(targets: List<NativeShelfTarget>): List<Book> {
        if (targets.isEmpty() || targets.distinct().size != targets.size) invalidGroup("Select distinct shelf books")
        return targets.map { target -> openBook(target.sourceId, target.bookUrl).book }
    }

    private suspend fun requireOrganization(expectedToken: String): NativeShelfOrganization {
        val state = organization()
        if (expectedToken.isEmpty() || expectedToken != state.token) {
            throw NativeShelfException(NativeShelfFailure.STALE_ORGANIZATION, "Shelf organization changed; refresh and try again")
        }
        return state
    }

    private fun requireGroupName(name: String, groups: List<BookGroup>, except: Long? = null): String {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) invalidGroup("Enter a group name")
        if (groups.any { it.groupId != except && it.groupName.trim() == trimmed }) {
            invalidGroup("A group with that name already exists")
        }
        return trimmed
    }

    private fun isCustomGroup(id: Long): Boolean = id > 0 && id and (id - 1) == 0L

    private fun invalidGroup(message: String): Nothing =
        throw NativeShelfException(NativeShelfFailure.INVALID_INPUT, message)

    /** Include removed entries when checking physical cache ownership. */
    @Query("SELECT * FROM books")
    abstract suspend fun cacheOwners(): List<Book>

    @Query("SELECT * FROM books WHERE bookUrl = :bookUrl")
    protected abstract suspend fun findBook(bookUrl: String): Book?

    @Query("SELECT * FROM books WHERE name = :name AND author = :author")
    protected abstract suspend fun findKnownIdentity(name: String, author: String): List<Book>

    @Query("SELECT * FROM chapters WHERE bookUrl = :bookUrl ORDER BY `index`, url")
    protected abstract suspend fun chapters(bookUrl: String): List<BookChapter>

    @Insert(onConflict = OnConflictStrategy.ABORT)
    protected abstract suspend fun insertBook(book: Book)

    @Insert(onConflict = OnConflictStrategy.ABORT)
    protected abstract suspend fun insertChapters(chapters: List<BookChapter>)

    @Query("SELECT * FROM native_reading_resume WHERE bookUrl = :bookUrl")
    abstract suspend fun resume(bookUrl: String): NativeReadingResume?

    @Query("DELETE FROM books WHERE bookUrl = :bookUrl")
    protected abstract suspend fun deleteBook(bookUrl: String)

    @Insert(onConflict = OnConflictStrategy.ABORT)
    protected abstract suspend fun insertResume(resume: NativeReadingResume)

    @Query("SELECT bookUrl, name, author FROM books")
    protected abstract suspend fun switchIdentities(): List<NativeWorkIdentity>

    @Query("SELECT * FROM book_sources WHERE bookSourceUrl = :sourceId")
    protected abstract suspend fun switchSourceRecord(sourceId: String): BookSource?

    /** Publish and verify the body under the transaction's URL-ownership guard before committing. */
    @Transaction
    open suspend fun switchSource(sourceId: String, bookUrl: String, expectedRevision: Long,
        expectedProjection: NativeChapterProjection, candidate: Book, catalog: List<BookChapter>,
        chapterUrl: String, body: String, expectedSource: BookSource,
        publishBody: () -> Unit = {}): NativeShelfEntry {
        val existing = openBook(sourceId, bookUrl).book
        val previous = resume(bookUrl)
        if ((previous?.revision ?: 0L) != expectedRevision || expectedRevision < 0 ||
            expectedRevision == Long.MAX_VALUE || NativeChapterProjection.from(existing) != expectedProjection) {
            throw NativeResumeException(NativeResumeFailure.STALE_REVISION, "Reading state changed; prepare the switch again")
        }
        if (previous != null && (previous.sourceId != sourceId ||
                previous.textVersion != NativeBodyCoordinates.VERSION || previous.revision <= 0)) {
            throw NativeResumeException(NativeResumeFailure.UNSUPPORTED_VERSION, "Existing resume cannot be safely replaced")
        }
        requireTextBook(candidate)
        val targetSource = switchSourceRecord(candidate.origin)
        if (targetSource == null || !targetSource.enabled || targetSource.bookSourceType != 0 ||
            targetSource != expectedSource) {
            throw NativeResumeException(NativeResumeFailure.STALE_REVISION, "Replacement source changed; prepare again")
        }
        if (candidate.name.trim().isEmpty() || candidate.author.trim().isEmpty() ||
            candidate.name.trim() != existing.name.trim() || candidate.author.trim() != existing.author.trim() ||
            candidate.origin.isBlank() || candidate.bookUrl.isBlank() || candidate.bookUrl == bookUrl ||
            findBook(candidate.bookUrl) != null) {
            throw NativeShelfException(NativeShelfFailure.IDENTITY_CONFLICT, "Replacement identity conflicts with the shelf")
        }
        if (switchIdentities().any { it.bookUrl != bookUrl &&
                it.name.trim() == existing.name.trim() && it.author.trim() == existing.author.trim() }) {
            throw NativeShelfException(NativeShelfFailure.AMBIGUOUS_IDENTITY, "Multiple records identify this work")
        }
        if (body.isEmpty() || catalog.isEmpty() ||
            catalog.any { it.bookUrl != candidate.bookUrl || it.url.isBlank() || it.index < 0 } ||
            catalog.map { it.url }.distinct().size != catalog.size ||
            catalog.map { it.index }.distinct().size != catalog.size) {
            throw NativeShelfException(NativeShelfFailure.INVALID_INPUT, "A verified replacement chapter and catalog are required")
        }
        val chapter = catalog.singleOrNull { it.url == chapterUrl && !it.isVolume }
            ?: throw NativeShelfException(NativeShelfFailure.INVALID_INPUT, "Choose a readable replacement chapter")
        val now = systemCurrentTimeMillis()
        val replacement = candidate.copy(
            name = existing.name, author = existing.author,
            customTag = existing.customTag, customCoverUrl = existing.customCoverUrl,
            customIntro = existing.customIntro, group = existing.group, order = existing.order,
            canUpdate = existing.canUpdate, readConfig = existing.readConfig,
            type = candidate.type and BookType.notShelf.inv(),
            totalChapterNum = catalog.size, durChapterIndex = chapter.index,
            durChapterTitle = chapter.title, durChapterPos = 0, durChapterTime = now,
            syncTime = 0L
        )
        // Acquire the write lock before publishing. Failure rolls back this deletion and its cascades.
        deleteBook(bookUrl)
        publishBody()
        insertBook(replacement)
        insertChapters(catalog)
        insertResume(NativeReadingResume(replacement.bookUrl, replacement.origin, chapter.url,
            chapter.index, NativeBodyCoordinates.VERSION, NativeBodyCoordinates.sha256(body),
            body.length, 0, expectedRevision + 1, now))
        return NativeShelfEntry(replacement, chapters(replacement.bookUrl))
    }

    @Query("UPDATE books SET type = type & ${BookType.notShelf.inv()}, `group` = 0 WHERE bookUrl = :bookUrl")
    protected abstract suspend fun restoreShelfFlag(bookUrl: String)

    @Query("SELECT * FROM books WHERE type & ${BookType.text} != 0 AND type & ${BookType.local} = 0 AND type & ${BookType.notShelf} = 0 AND origin != '${BookType.localTag}' AND origin NOT LIKE '${BookType.webDavTag}%' ORDER BY durChapterTime DESC, bookUrl ASC")
    abstract suspend fun listBooks(): List<Book>

    @Query("UPDATE books SET type = type | ${BookType.notShelf}, `group` = 0 WHERE bookUrl = :bookUrl")
    protected abstract suspend fun markRemoved(bookUrl: String)

    @Transaction
    open suspend fun removeFromShelf(sourceId: String, bookUrl: String) {
        val existing = exactBook(sourceId, bookUrl)
        requireTextBook(existing)
        markRemoved(bookUrl)
    }

    @Transaction
    open suspend fun openBook(sourceId: String, bookUrl: String): NativeShelfEntry {
        val existing = exactBook(sourceId, bookUrl)
        requireTextBook(existing)
        if (existing.type and BookType.notShelf != 0) {
            throw NativeShelfException(NativeShelfFailure.NOT_ON_SHELF, "Book was removed from the shelf")
        }
        return NativeShelfEntry(existing, chapters(bookUrl))
    }

    private suspend fun exactBook(sourceId: String, bookUrl: String): Book {
        val existing = findBook(bookUrl)
            ?: throw NativeShelfException(NativeShelfFailure.NOT_ON_SHELF, "Book is not stored")
        if (existing.origin != sourceId) {
            throw NativeShelfException(NativeShelfFailure.IDENTITY_CONFLICT, "Book source does not match")
        }
        return existing
    }

    /** Reuse exact records first; known title/author matching never changes their active source. */
    @Transaction
    open suspend fun addToShelf(candidate: Book, catalog: List<BookChapter>): NativeShelfEntry {
        if (candidate.bookUrl.isBlank() || candidate.origin.isBlank()) {
            throw NativeShelfException(NativeShelfFailure.INVALID_INPUT, "Book URL and source are required")
        }
        val exact = findBook(candidate.bookUrl)
        if (exact != null && exact.origin == candidate.origin) return reuse(exact)
        if (candidate.name.isNotBlank() && candidate.author.isNotBlank()) {
            val matches = findKnownIdentity(candidate.name, candidate.author)
            if (matches.size > 1) {
                throw NativeShelfException(NativeShelfFailure.AMBIGUOUS_IDENTITY, "Multiple known-author records match")
            }
            matches.singleOrNull()?.let { return reuse(it) }
        }
        if (exact != null) {
            throw NativeShelfException(NativeShelfFailure.IDENTITY_CONFLICT, "Book URL belongs to another source")
        }
        requireTextBook(candidate)
        if (catalog.isEmpty() || catalog.any { it.bookUrl != candidate.bookUrl || it.url.isBlank() || it.index < 0 } ||
            catalog.map { it.url }.distinct().size != catalog.size ||
            catalog.map { it.index }.distinct().size != catalog.size) {
            throw NativeShelfException(NativeShelfFailure.INVALID_INPUT, "A valid catalog for this exact book is required")
        }
        val added = candidate.copy(type = candidate.type and BookType.notShelf.inv(), group = 0)
        insertBook(added)
        insertChapters(catalog)
        return NativeShelfEntry(added, chapters(added.bookUrl))
    }

    private suspend fun reuse(existing: Book): NativeShelfEntry {
        requireTextBook(existing)
        val removed = existing.type and BookType.notShelf != 0
        if (removed) restoreShelfFlag(existing.bookUrl)
        return NativeShelfEntry(existing.copy(type = existing.type and BookType.notShelf.inv(),
            group = if (removed) 0 else existing.group), chapters(existing.bookUrl))
    }

    private fun requireTextBook(book: Book) {
        if (book.type and BookType.text == 0 || book.type and BookType.local != 0 ||
            book.origin == BookType.localTag || book.origin.startsWith(BookType.webDavTag)) {
            throw NativeShelfException(NativeShelfFailure.UNSUPPORTED_BOOK, "Only source-backed text books belong to this shelf")
        }
    }
}

/** These snapshots stay within KMP; the engine will provide its own public transport types. */
data class NativeShelfEntry(val book: Book, val chapters: List<BookChapter>)
data class NativeWorkIdentity(val bookUrl: String, val name: String, val author: String)

data class NativeShelfTarget(val sourceId: String, val bookUrl: String)

data class NativeShelfOrganization(val books: List<Book>, val groups: List<BookGroup>, val token: String)

enum class NativeShelfFailure { INVALID_INPUT, IDENTITY_CONFLICT, AMBIGUOUS_IDENTITY, UNSUPPORTED_BOOK, NOT_ON_SHELF, STALE_ORGANIZATION, GROUP_CAPACITY }

class NativeShelfException(val failure: NativeShelfFailure, message: String) : IllegalStateException(message)
