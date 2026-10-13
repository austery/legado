package io.legado.app.data.dao

import androidx.room3.Dao
import androidx.room3.Insert
import androidx.room3.OnConflictStrategy
import androidx.room3.Query
import androidx.room3.Transaction
import io.legado.app.constant.BookType
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter

/** Native shelf policy; deliberately separate from the legacy replacement writer. */
@Dao
abstract class NativeShelfDao {
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

    @Query("UPDATE books SET type = type & ${BookType.notShelf.inv()} WHERE bookUrl = :bookUrl")
    protected abstract suspend fun restoreShelfFlag(bookUrl: String)

    @Query("SELECT * FROM books WHERE type & ${BookType.text} != 0 AND type & ${BookType.local} = 0 AND type & ${BookType.notShelf} = 0 AND origin != '${BookType.localTag}' AND origin NOT LIKE '${BookType.webDavTag}%' ORDER BY durChapterTime DESC, bookUrl ASC")
    abstract suspend fun listBooks(): List<Book>

    @Query("UPDATE books SET type = type | ${BookType.notShelf} WHERE bookUrl = :bookUrl")
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
        val added = candidate.copy(type = candidate.type and BookType.notShelf.inv())
        insertBook(added)
        insertChapters(catalog)
        return NativeShelfEntry(added, chapters(added.bookUrl))
    }

    private suspend fun reuse(existing: Book): NativeShelfEntry {
        requireTextBook(existing)
        if (existing.type and BookType.notShelf != 0) restoreShelfFlag(existing.bookUrl)
        return NativeShelfEntry(existing.copy(type = existing.type and BookType.notShelf.inv()), chapters(existing.bookUrl))
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

enum class NativeShelfFailure { INVALID_INPUT, IDENTITY_CONFLICT, AMBIGUOUS_IDENTITY, UNSUPPORTED_BOOK, NOT_ON_SHELF }

class NativeShelfException(val failure: NativeShelfFailure, message: String) : IllegalStateException(message)
