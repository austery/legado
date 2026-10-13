package io.legado.app.data.dao

import androidx.room3.Dao
import androidx.room3.Insert
import androidx.room3.OnConflictStrategy
import androidx.room3.Query
import androidx.room3.Transaction
import androidx.room3.Update
import io.legado.app.constant.BookType
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.NativeReadingResume
import io.legado.app.utils.systemCurrentTimeMillis
import okio.ByteString.Companion.encodeUtf8

/** Canonical unmodified body coordinates shared by persistence and the engine. */
object NativeBodyCoordinates {
    const val VERSION = "native-body-v1"
    fun sha256(body: String): String = body.encodeUtf8().sha256().hex()

    /** End offset maps to the last paragraph, or an empty final paragraph after a delimiter. */
    fun paragraphStart(body: String, offset: Int): Int {
        if (offset !in 0..body.length || (offset > 0 && offset < body.length &&
                body[offset - 1].isHighSurrogate() && body[offset].isLowSurrogate())) {
            throw NativeResumeException(NativeResumeFailure.INVALID_POSITION, "Invalid UTF-16 position")
        }
        var start = 0
        var cursor = 0
        while (cursor < offset) {
            val character = body[cursor]
            val end = when (character) {
                '\r' -> if (cursor + 1 < body.length && body[cursor + 1] == '\n') cursor + 2 else cursor + 1
                '\n', '\u2028', '\u2029' -> cursor + 1
                else -> { cursor++; continue }
            }
            if (end <= offset) start = end
            cursor = end
        }
        return start
    }
}

enum class NativeResumeFailure { INVALID_POSITION, IDENTITY_CONFLICT, NOT_ON_SHELF, CHAPTER_MISMATCH, STALE_REVISION, UNSUPPORTED_VERSION }
class NativeResumeException(val failure: NativeResumeFailure, message: String) : IllegalStateException(message)

@Dao
abstract class NativeResumeDao {
    /** Raw persisted snapshot; the engine must validate current identity and body before restoring. */
    @Query("SELECT * FROM native_reading_resume WHERE bookUrl = :bookUrl")
    abstract suspend fun get(bookUrl: String): NativeReadingResume?

    @Query("SELECT * FROM books WHERE bookUrl = :bookUrl")
    protected abstract suspend fun book(bookUrl: String): Book?

    @Query("SELECT * FROM chapters WHERE bookUrl = :bookUrl AND url = :chapterUrl")
    protected abstract suspend fun chapter(bookUrl: String, chapterUrl: String): BookChapter?

    @Insert(onConflict = OnConflictStrategy.ABORT)
    protected abstract suspend fun insertResume(resume: NativeReadingResume)

    @Update(onConflict = OnConflictStrategy.ABORT)
    protected abstract suspend fun updateResume(resume: NativeReadingResume)

    @Query("UPDATE books SET durChapterIndex = :chapterIndex, durChapterTitle = :title, durChapterTime = :savedAt, durChapterPos = 0 WHERE bookUrl = :bookUrl")
    protected abstract suspend fun projectChapter(bookUrl: String, chapterIndex: Int, title: String, savedAt: Long)

    /** The caller separately proves body persistence and owns reading tokens/event ordering. */
    @Transaction
    open suspend fun save(sourceId: String, bookUrl: String, chapterUrl: String, chapterIndex: Int,
        body: String, utf16Offset: Int, expectedRevision: Long): NativeReadingResume {
        val offset = NativeBodyCoordinates.paragraphStart(body, utf16Offset)
        val book = book(bookUrl) ?: fail(NativeResumeFailure.NOT_ON_SHELF, "Book is not stored")
        if (book.origin != sourceId) fail(NativeResumeFailure.IDENTITY_CONFLICT, "Book source changed")
        if (book.type and BookType.notShelf != 0 || book.type and BookType.text == 0 ||
            book.type and BookType.local != 0 || book.origin == BookType.localTag || book.origin.startsWith(BookType.webDavTag)) {
            fail(NativeResumeFailure.NOT_ON_SHELF, "Book is not on the native text shelf")
        }
        val chapter = chapter(bookUrl, chapterUrl)
            ?: fail(NativeResumeFailure.CHAPTER_MISMATCH, "Chapter is not in the saved catalog")
        if (chapter.index != chapterIndex || chapterIndex < 0) fail(NativeResumeFailure.CHAPTER_MISMATCH, "Chapter index changed")
        val previous = get(bookUrl)
        if (previous != null && previous.textVersion != NativeBodyCoordinates.VERSION) {
            fail(NativeResumeFailure.UNSUPPORTED_VERSION, "Resume version is not supported")
        }
        if (expectedRevision < 0 || expectedRevision == Long.MAX_VALUE ||
            (previous?.revision ?: 0L) != expectedRevision || (previous != null && previous.revision <= 0)) {
            fail(NativeResumeFailure.STALE_REVISION, "Resume revision changed or is invalid")
        }
        val saved = NativeReadingResume(bookUrl, sourceId, chapterUrl, chapterIndex,
            NativeBodyCoordinates.VERSION, NativeBodyCoordinates.sha256(body), body.length, offset,
            expectedRevision + 1, systemCurrentTimeMillis())
        if (previous == null) insertResume(saved) else updateResume(saved)
        projectChapter(bookUrl, chapterIndex, chapter.title, saved.savedAt)
        return saved
    }

    private fun fail(reason: NativeResumeFailure, message: String): Nothing = throw NativeResumeException(reason, message)
}
