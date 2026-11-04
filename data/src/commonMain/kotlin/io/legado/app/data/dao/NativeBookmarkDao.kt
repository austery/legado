package io.legado.app.data.dao

import androidx.room3.Dao
import androidx.room3.Insert
import androidx.room3.OnConflictStrategy
import androidx.room3.Query
import androidx.room3.Transaction
import io.legado.app.constant.BookType
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.NativeBookmark
import io.legado.app.utils.systemCurrentTimeMillis

@Dao
abstract class NativeBookmarkDao {
    @Query("SELECT * FROM native_bookmarks WHERE ownerBookUrl = :bookUrl ORDER BY createdAt, id")
    protected abstract suspend fun stored(bookUrl: String): List<NativeBookmark>

    @Query("SELECT * FROM books WHERE bookUrl = :bookUrl")
    protected abstract suspend fun book(bookUrl: String): Book?

    @Query("SELECT * FROM chapters WHERE bookUrl = :bookUrl AND url = :chapterUrl")
    protected abstract suspend fun chapter(bookUrl: String, chapterUrl: String): BookChapter?

    @Insert(onConflict = OnConflictStrategy.ABORT)
    protected abstract suspend fun insert(bookmark: NativeBookmark)

    @Query("DELETE FROM native_bookmarks WHERE ownerBookUrl = :bookUrl AND id = :id")
    protected abstract suspend fun deleteStored(bookUrl: String, id: String)

    private suspend fun owner(sourceId: String, bookUrl: String): Book {
        val record = book(bookUrl) ?: throw NativeShelfException(NativeShelfFailure.NOT_ON_SHELF, "Book is not stored")
        if (record.origin != sourceId) throw NativeShelfException(NativeShelfFailure.IDENTITY_CONFLICT, "Book source changed")
        if (record.type and BookType.notShelf != 0 || record.type and BookType.text == 0 ||
            record.type and BookType.local != 0 || record.origin == BookType.localTag || record.origin.startsWith(BookType.webDavTag)) {
            throw NativeShelfException(NativeShelfFailure.NOT_ON_SHELF, "Add this text book to the shelf before using bookmarks")
        }
        return record
    }

    @Transaction
    open suspend fun list(sourceId: String, bookUrl: String): List<NativeBookmark> {
        owner(sourceId, bookUrl)
        return stored(bookUrl)
    }

    @Transaction
    open suspend fun remove(sourceId: String, bookUrl: String, id: String) {
        owner(sourceId, bookUrl)
        require(id.isNotBlank()) { "Choose a bookmark" }
        deleteStored(bookUrl, id)
    }

    /** The engine proves cache durability and token ownership before invoking this transaction. */
    @Transaction
    open suspend fun save(id: String, sourceId: String, bookUrl: String, chapterUrl: String,
        chapterIndex: Int, body: String, offset: Int, expectedProjection: NativeChapterProjection): NativeBookmark {
        require(id.isNotBlank() && body.isNotEmpty()) { "Bookmark identity and readable text are required" }
        val record = owner(sourceId, bookUrl)
        if (NativeChapterProjection.from(record) != expectedProjection) {
            throw NativeResumeException(NativeResumeFailure.STALE_REVISION, "Reading chapter changed")
        }
        val savedChapter = chapter(bookUrl, chapterUrl)
            ?: throw NativeResumeException(NativeResumeFailure.CHAPTER_MISMATCH, "Chapter is no longer stored")
        if (savedChapter.index != chapterIndex || savedChapter.isVolume) {
            throw NativeResumeException(NativeResumeFailure.CHAPTER_MISMATCH, "Chapter identity changed")
        }
        val paragraph = NativeBodyCoordinates.paragraphStart(body, offset)
        val hash = NativeBodyCoordinates.sha256(body)
        stored(bookUrl).firstOrNull { it.sourceId == sourceId && it.sourceBookUrl == bookUrl &&
            it.chapterUrl == chapterUrl && it.textVersion == NativeBodyCoordinates.VERSION &&
            it.textSha256 == hash && it.paragraphUtf16Offset == paragraph }?.let { return it }
        var end = (paragraph + 160).coerceAtMost(body.length)
        if (end < body.length && end > paragraph && body[end - 1].isHighSurrogate() && body[end].isLowSurrogate()) end--
        val excerpt = body.substring(paragraph, end).lineSequence().firstOrNull().orEmpty()
        val bookmark = NativeBookmark(id, bookUrl, sourceId, bookUrl, chapterUrl, chapterIndex,
            savedChapter.title, NativeBodyCoordinates.VERSION, hash, body.length, paragraph, excerpt,
            systemCurrentTimeMillis())
        insert(bookmark)
        return bookmark
    }
}
