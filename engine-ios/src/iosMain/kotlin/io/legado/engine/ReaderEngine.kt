package io.legado.engine

import io.legado.app.data.AppDatabaseProviders
import io.legado.app.data.dao.NativeChapterProjection
import io.legado.app.data.dao.NativeBodyCoordinates
import io.legado.app.data.dao.NativeResumeException
import io.legado.app.data.dao.NativeResumeFailure
import platform.Foundation.NSUUID
import io.legado.app.data.dao.NativeShelfEntry
import io.legado.app.data.dao.NativeShelfException
import io.legado.app.data.dao.NativeShelfFailure
import io.legado.app.data.AppDbProviders
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.help.book.BookStorageProviders
import io.legado.app.help.book.BookHelpProviders
import io.legado.app.model.webBook.WebBook
import io.legado.app.model.webBook.WebBookResponsePolicy
import io.ktor.client.plugins.HttpRequestTimeoutException
import io.ktor.client.network.sockets.ConnectTimeoutException
import io.ktor.client.network.sockets.SocketTimeoutException
import io.legado.app.utils.KS_JSON
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/** Public results contain immutable values, never Room entities or Kotlin Result. */
abstract class EngineReply internal constructor()
class EngineReady internal constructor() : EngineReply()
enum class EngineErrorCode { INVALID_INPUT, NOT_FOUND, NETWORK, TIMEOUT, RULE, UNSUPPORTED, INTERACTION_REQUIRED, CANCELLED, INTERNAL, IDENTITY_CONFLICT, AMBIGUOUS_IDENTITY, STORAGE, STALE_UPDATE, CACHE_UNAVAILABLE }
class EngineFailure internal constructor(val code: EngineErrorCode, val message: String) : EngineReply()
class SourceSnapshot internal constructor(val id: String, val name: String, val enabled: Boolean)
class SourcesReply internal constructor(val sources: List<SourceSnapshot>) : EngineReply()
class BookSnapshot internal constructor(val sourceId: String, val id: String, val title: String,
    val author: String, val intro: String)
class ShelfBookSnapshot internal constructor(val book: BookSnapshot, val sourceName: String,
    val lastChapter: String)
class ShelfReply internal constructor(val books: List<ShelfBookSnapshot>) : EngineReply()
class ShelfEntryReply internal constructor(val entry: ShelfBookSnapshot,
    val chapters: List<ChapterSnapshot>) : EngineReply()
class ShelfRemoved internal constructor() : EngineReply()
class SearchReply internal constructor(val books: List<BookSnapshot>, val hasNextPage: Boolean) : EngineReply()
class BookReply internal constructor(val book: BookSnapshot) : EngineReply()
class ChapterSnapshot internal constructor(val sourceId: String, val bookId: String, val id: String,
    val index: Int, val title: String)
class TocReply internal constructor(val chapters: List<ChapterSnapshot>) : EngineReply()
class ContentReply internal constructor(val chapter: ChapterSnapshot, val text: String,
    val fromCache: Boolean, val reading: ReadingSnapshot? = null,
    val storageNotice: String = "") : EngineReply()
class EngineRequest internal constructor(private val job: Job) {
    fun cancel() { job.cancel() }
}

/** One host session. Call close when its owner leaves; initialization is process-wide. */
class ReaderEngine {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val books = mutableMapOf<Pair<String, String>, Book>()
    private val chapters = mutableMapOf<Pair<String, String>, List<BookChapter>>()
    private var initialized = false
    private val sessionId = NSUUID().UUIDString

    fun initialize(completion: (EngineReply) -> Unit): EngineRequest = request(completion, false) {
        try { EngineHost.initialize() }
        catch (error: Exception) { return@request EngineFailure(EngineErrorCode.INTERNAL, "Engine initialization failed: ${error.message}") }
        initialized = true
        EngineReady()
    }

    /** Read persisted, enabled text sources without importing or modifying their rules. */
    fun listSources(completion: (EngineReply) -> Unit): EngineRequest = request(completion) {
        SourcesReply(AppDbProviders.get().bookSourceDao.allTextEnabledPart().map {
            SourceSnapshot(it.bookSourceUrl, it.bookSourceName, it.enabled)
        })
    }

    /** Decode everything first. Duplicate IDs use the last object; existing IDs are replaced. */
    fun importSources(json: String, completion: (EngineReply) -> Unit): EngineRequest = request(completion) {
        val element = try { KS_JSON.parseToJsonElement(json) }
            catch (error: SerializationException) { throw InvalidInput("Malformed source JSON") }
        val sources = try { when (element) {
            is JsonArray -> KS_JSON.decodeFromJsonElement(ListSerializer(BookSource.serializer()), element)
            is JsonObject -> listOf(KS_JSON.decodeFromJsonElement(BookSource.serializer(), element))
            else -> throw InvalidInput("Expected a source object or array")
        } } catch (error: SerializationException) { throw InvalidInput("Invalid source schema") }
        if (sources.isEmpty()) throw InvalidInput("No sources supplied")
        if (!sources.all { it.bookSourceUrl.isNotBlank() && it.bookSourceName.isNotBlank() })
            throw InvalidInput("Each source requires a nonempty identity and name")
        val unique = sources.associateBy { it.bookSourceUrl }.values.toList()
        AppDbProviders.get().bookSourceDao.insert(*unique.toTypedArray())
        // Invalidate session entities whose source rules were replaced.
        val ids = unique.map { it.bookSourceUrl }.toSet()
        books.keys.removeAll { it.first in ids }
        chapters.keys.removeAll { it.first in ids }
        SourcesReply(unique.map { SourceSnapshot(it.bookSourceUrl, it.bookSourceName, it.enabled) })
    }

    fun listShelf(completion: (EngineReply) -> Unit): EngineRequest = request(completion) {
        ShelfReply(shelfOperation { AppDatabaseProviders.get().appDb.nativeShelfDao.listBooks() }.map { shelfSnapshot(it) })
    }

    /** Only a loaded catalog may be added; the returned identity can be an existing source. */
    fun addToShelf(sourceId: String, bookId: String, completion: (EngineReply) -> Unit): EngineRequest = request(completion) {
        val candidate = book(sourceId, bookId)
        val catalog = chapters[sourceId to bookId] ?: throw InvalidInput("Load the table of contents before adding")
        val entry = shelfOperation { AppDatabaseProviders.get().appDb.nativeShelfDao.addToShelf(candidate, catalog) }
        acceptShelfEntry(entry)
    }

    /** Opens only persisted metadata and catalog. It performs no source fetch. */
    fun openShelfBook(sourceId: String, bookId: String, completion: (EngineReply) -> Unit): EngineRequest = request(completion) {
        acceptShelfEntry(shelfOperation { AppDatabaseProviders.get().appDb.nativeShelfDao.openBook(sourceId, bookId) })
    }

    fun removeFromShelf(sourceId: String, bookId: String, completion: (EngineReply) -> Unit): EngineRequest = request(completion) {
        shelfOperation { AppDatabaseProviders.get().appDb.nativeShelfDao.removeFromShelf(sourceId, bookId) }
        ReadingSessions.invalidate(sourceId, bookId)
        ShelfRemoved()
    }

    private suspend fun acceptShelfEntry(entry: NativeShelfEntry): ShelfEntryReply {
        val key = entry.book.origin to entry.book.bookUrl
        books[key] = entry.book
        chapters[key] = entry.chapters
        return ShelfEntryReply(shelfSnapshot(entry.book), entry.chapters.map { snapshot(entry.book.origin, it) })
    }

    private suspend fun shelfSnapshot(book: Book) = ShelfBookSnapshot(snapshot(book),
        AppDbProviders.get().bookSourceDao.getBookSource(book.origin)?.bookSourceName ?: book.origin,
        book.durChapterTitle.orEmpty())

    private suspend fun <T> shelfOperation(action: suspend () -> T): T = try { action() }
        catch (error: CancellationException) { throw error }
        catch (error: NativeShelfException) { throw error }
        catch (error: Exception) { throw ShelfStorageFailure(error.message ?: "Shelf storage failed") }

    fun search(sourceId: String, query: String, page: Int, completion: (EngineReply) -> Unit): EngineRequest = request(completion) {
        if (page <= 0 || query.isBlank()) throw InvalidInput("Search requires a query and positive page")
        val source = source(sourceId)
        val result = WebBook.getBookListAwait(source, query, page)
        currentCoroutineContext().ensureActive()
        val snapshots = result.books.map {
            val book = it.toBook()
            // Search snapshots must not replace detail state paired with a loaded TOC.
            books.getOrPut(sourceId to book.bookUrl) { book }
            snapshot(book)
        }
        SearchReply(snapshots, result.hasNextPage)
    }

    fun loadBook(sourceId: String, bookId: String, completion: (EngineReply) -> Unit): EngineRequest = request(completion) {
        val source = source(sourceId)
        val book = book(sourceId, bookId)
        WebBook.getBookInfoAwait(source, book)
        BookReply(snapshot(book))
    }

    fun loadToc(sourceId: String, bookId: String, completion: (EngineReply) -> Unit): EngineRequest = request(completion) {
        val source = source(sourceId)
        val book = book(sourceId, bookId)
        val result = WebBook.getChapterListAwait(source, book).getOrThrow()
        currentCoroutineContext().ensureActive()
        chapters[sourceId to bookId] = result
        TocReply(result.map { snapshot(sourceId, it) })
    }

    fun openReading(sourceId: String, bookId: String, cacheOnly: Boolean,
        completion: (EngineReply) -> Unit): EngineRequest = request(completion) {
        val entry = shelfOperation { AppDatabaseProviders.get().appDb.nativeShelfDao.openBook(sourceId, bookId) }
        acceptShelfEntry(entry)
        val saved = AppDatabaseProviders.get().appDb.nativeResumeDao.get(bookId)
        val chapter = if (saved != null) {
            if (saved.sourceId != sourceId) throw InvalidInput("Saved source differs from the book")
            entry.chapters.singleOrNull { it.url == saved.chapterUrl && it.index == saved.chapterIndex }
                ?: throw MissingEntity("Saved chapter is no longer in the catalog; choose a chapter explicitly")
        } else if (entry.book.durChapterIndex != 0 || entry.book.durChapterPos != 0 || !entry.book.durChapterTitle.isNullOrEmpty()) {
            entry.chapters.singleOrNull { it.index == entry.book.durChapterIndex && !it.isVolume &&
                (entry.book.durChapterTitle.isNullOrEmpty() || it.title == entry.book.durChapterTitle) }
                ?: throw MissingEntity("Legacy chapter cannot be verified; choose a chapter explicitly")
        } else entry.chapters.firstOrNull { !it.isVolume } ?: throw MissingEntity("No readable chapter is stored")
        chapterContent(sourceId, bookId, chapter.url, cacheOnly, true)
    }

    fun loadChapter(sourceId: String, bookId: String, chapterId: String, cacheOnly: Boolean,
        completion: (EngineReply) -> Unit): EngineRequest = request(completion) {
        chapterContent(sourceId, bookId, chapterId, cacheOnly, false)
    }

    private suspend fun chapterContent(sourceId: String, bookId: String, chapterId: String,
        cacheOnly: Boolean, restore: Boolean): EngineReply {
        val book = book(sourceId, bookId)
        val toc = chapters[sourceId to bookId] ?: throw MissingEntity("Load the table of contents first")
        val position = toc.indexOfFirst { it.url == chapterId }
        if (position < 0) throw MissingEntity("Chapter is not in the catalog")
        val chapter = toc[position]
        val saved = AppDatabaseProviders.get().appDb.nativeResumeDao.get(bookId)
        val cached = BookStorageProviders.get().getContent(book, chapter)?.takeIf { it.isNotEmpty() }
        val expected = saved?.takeIf { it.chapterUrl == chapterId }
        val usable = cached?.takeIf { expected == null ||
            (NativeBodyCoordinates.sha256(it) == expected.textSha256 && it.length == expected.textUtf16Length) }
        var storageNotice = ""
        val content = usable ?: run {
            if (cacheOnly) throw CacheUnavailable("Chapter cache is missing or differs from saved progress")
            val source = try { source(sourceId) } catch (error: Exception) {
                throw CacheUnavailable("Verified cache unavailable; source cannot fetch: ${error.message}")
            }
            val downloaded = WebBook.getContentAwait(source, book, chapter,
                nextChapterUrl = toc.getOrNull(position + 1)?.url, needSave = false)
            currentCoroutineContext().ensureActive()
            EngineHost.interactionFailure()?.let { return it }
            if (downloaded.isEmpty()) throw CacheUnavailable("Chapter returned an empty body")
            try {
                BookHelpProviders.get().saveContent(source, book, chapter, downloaded)
                if (BookStorageProviders.get().getContent(book, chapter) != downloaded) {
                    throw okio.IOException("Saved chapter body could not be verified")
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: okio.IOException) {
                storageNotice = "Text is available for this session, but offline reading and progress were not saved: ${error.message}"
            }
            downloaded
        }
        val shelf = try { AppDatabaseProviders.get().appDb.nativeShelfDao.openBook(sourceId, bookId) }
            catch (error: NativeShelfException) { if (error.failure == NativeShelfFailure.NOT_ON_SHELF) null else throw error }
        val reading = shelf?.let {
            var offset = 0
            var notice = ""
            var canSave = storageNotice.isEmpty()
            if (saved != null && saved.textVersion != NativeBodyCoordinates.VERSION) {
                notice = "Unsupported reading position version; showing chapter start without overwriting it"
                canSave = false
            } else if (saved != null && (saved.revision <= 0 || saved.sourceId != sourceId)) {
                notice = "Saved identity or revision is invalid; progress will not be overwritten"
                canSave = false
            } else if (restore && saved != null) {
                if (it.book.durChapterIndex != saved.chapterIndex || it.book.durChapterTitle != chapter.title) {
                    notice = "Shared chapter state changed; showing chapter start"
                } else if (saved.textSha256 != NativeBodyCoordinates.sha256(content) || saved.textUtf16Length != content.length) {
                    notice = "Chapter text changed; showing chapter start"
                } else {
                    try {
                        offset = NativeBodyCoordinates.paragraphStart(content, saved.paragraphUtf16Offset)
                        if (offset != saved.paragraphUtf16Offset) throw InvalidInput("Invalid paragraph boundary")
                    } catch (error: Exception) {
                        notice = "Saved position is invalid; showing chapter start"
                        offset = 0
                    }
                }
            }
            val token = NSUUID().UUIDString
            ReadingSessions.tokens[token] = ReadingSession(sessionId, sourceId, bookId, chapter,
                content, saved?.revision ?: 0, canSave, NativeChapterProjection.from(it.book), storageNotice)
            ReadingSnapshot(token, saved?.revision ?: 0, offset, notice, canSave)
        }
        return ContentReply(snapshot(sourceId, chapter), content, usable != null, reading, storageNotice)
    }

    /** Accepted saves are independent of cancellable foreground network requests. */
    fun saveReadingPosition(token: String, eventSequence: Long, utf16Offset: Int,
        completion: (EngineReply) -> Unit) = persistReading(token, eventSequence, utf16Offset, false, completion)

    fun finishReading(token: String, eventSequence: Long, utf16Offset: Int,
        completion: (EngineReply) -> Unit) = persistReading(token, eventSequence, utf16Offset, true, completion)

    fun abandonReading(token: String, completion: (EngineReply) -> Unit) {
        persistence(completion) {
            val reading = ReadingSessions.tokens[token]
            if (reading != null && reading.owner != sessionId) throw StaleReading("Token belongs to another session")
            ReadingSessions.tokens.remove(token)
            ReadingFinished()
        }
    }

    private fun persistReading(token: String, eventSequence: Long, utf16Offset: Int, finish: Boolean,
        completion: (EngineReply) -> Unit) {
        persistence(completion) {
            val reading = ReadingSessions.tokens[token] ?: throw StaleReading("Reading token expired")
            if (reading.owner != sessionId || eventSequence <= reading.lastEvent || eventSequence <= 0)
                throw StaleReading("Reading event is stale")
            reading.lastEvent = eventSequence
            if (reading.storageNotice.isNotEmpty()) throw CacheUnavailable(reading.storageNotice)
            if (!reading.canSave) throw UnsupportedOperationException("Saved format cannot be overwritten")
            val entry = AppDatabaseProviders.get().appDb.nativeShelfDao.openBook(reading.sourceId, reading.bookId)
            if (NativeChapterProjection.from(entry.book) != reading.projection)
                throw StaleReading("Shared reading chapter state changed")
            val chapter = entry.chapters.singleOrNull { it.url == reading.chapter.url && it.index == reading.chapter.index }
                ?: throw StaleReading("Chapter identity changed")
            if (BookStorageProviders.get().getContent(entry.book, chapter) != reading.body)
                throw CacheUnavailable("Displayed text is not safely available in the chapter cache")
            val saved = AppDatabaseProviders.get().appDb.nativeResumeDao.save(reading.sourceId, reading.bookId,
                chapter.url, chapter.index, reading.body, utf16Offset, reading.revision, reading.projection)
            reading.projection = NativeChapterProjection(chapter.index, chapter.title, saved.savedAt, 0)
            reading.revision = saved.revision
            reading.lastEvent = eventSequence
            if (finish) ReadingSessions.tokens.remove(token)
            ReadingSaved(saved.revision, saved.paragraphUtf16Offset, eventSequence)
        }
    }

    private fun persistence(completion: (EngineReply) -> Unit, action: suspend () -> EngineReply) {
        ReadingSessions.scope.launch(start = CoroutineStart.UNDISPATCHED) {
            val result = try { EngineHost.gate.withLock { action() } } catch (error: Exception) {
                when (error) {
                    is NativeResumeException, is NativeShelfException, is CacheUnavailable,
                    is StaleReading, is UnsupportedOperationException -> failure(error)
                    else -> EngineFailure(EngineErrorCode.STORAGE, error.message ?: "Reading persistence failed")
                }
            }
            withContext(Dispatchers.Main) { completion(result) }
        }
    }

    fun close() {
        scope.cancel()
        ReadingSessions.scope.launch(start = CoroutineStart.UNDISPATCHED) {
            EngineHost.gate.withLock { ReadingSessions.tokens.entries.removeAll { it.value.owner == sessionId } }
        }
    }

    private suspend fun source(id: String): BookSource {
        val source = AppDbProviders.get().bookSourceDao.getBookSource(id) ?: throw MissingEntity("Source not found")
        if (!source.enabled) throw UnsupportedOperationException("Source is disabled; only cached chapters are available")
        if (source.bookSourceType != 0) throw UnsupportedOperationException("Only text book sources are supported")
        return source
    }
    private fun book(sourceId: String, bookId: String): Book =
        books[sourceId to bookId] ?: throw MissingEntity("Search for this book in the current session first")
    private fun snapshot(book: Book) = BookSnapshot(book.origin, book.bookUrl, book.name, book.author, book.intro.orEmpty())
    private fun snapshot(sourceId: String, chapter: BookChapter) =
        ChapterSnapshot(sourceId, chapter.bookUrl, chapter.url, chapter.index, chapter.title)

    @OptIn(ExperimentalCoroutinesApi::class)
    private fun request(completion: (EngineReply) -> Unit, requiresReady: Boolean = true,
        action: suspend () -> EngineReply): EngineRequest {
        val job = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            val operationJob = currentCoroutineContext().job
            var createdReadingToken: String? = null
            val reply = try {
                withContext(Dispatchers.Default + WebBookResponsePolicy { response ->
                    if (!response.isSuccessful()) throw HttpFailure(response.code())
                }) {
                    EngineHost.gate.withLock {
                        EngineHost.withOperation {
                            try {
                                if (requiresReady && !initialized) throw InvalidInput("Initialize this engine session first")
                                val result = action()
                                createdReadingToken = (result as? ContentReply)?.reading?.token
                                currentCoroutineContext().ensureActive()
                                EngineHost.interactionFailure() ?: result
                            } catch (e: CancellationException) {
                                throw e
                            } catch (e: Exception) {
                                currentCoroutineContext().ensureActive()
                                EngineHost.interactionFailure() ?: failure(e)
                            }
                        }
                    }
                }
            } catch (e: CancellationException) {
                EngineFailure(EngineErrorCode.CANCELLED, "Request cancelled")
            } catch (e: Exception) {
                failure(e)
            }
            withContext(NonCancellable + Dispatchers.Main) {
                val delivered = if (operationJob.isCancelled)
                    EngineFailure(EngineErrorCode.CANCELLED, "Request cancelled") else reply
                // Retain only tokens transferred to the caller, including cancellation during dispatch.
                if (createdReadingToken != null && (delivered as? ContentReply)?.reading?.token != createdReadingToken) {
                    EngineHost.gate.withLock { ReadingSessions.tokens.remove(createdReadingToken) }
                }
                completion(delivered)
            }
        }
        return EngineRequest(job)
    }

    private fun failure(error: Exception): EngineFailure {
        generateSequence<Throwable>(error) { it.cause }.take(16)
            .filterIsInstance<EngineHostRejection>().firstOrNull()?.let { return it.failure }
        val code = when (error) {
            is CacheUnavailable -> EngineErrorCode.CACHE_UNAVAILABLE
            is StaleReading -> EngineErrorCode.STALE_UPDATE
            is NativeResumeException -> when (error.failure) {
                NativeResumeFailure.INVALID_POSITION -> EngineErrorCode.INVALID_INPUT
                NativeResumeFailure.IDENTITY_CONFLICT -> EngineErrorCode.IDENTITY_CONFLICT
                NativeResumeFailure.NOT_ON_SHELF, NativeResumeFailure.CHAPTER_MISMATCH -> EngineErrorCode.NOT_FOUND
                NativeResumeFailure.STALE_REVISION -> EngineErrorCode.STALE_UPDATE
                NativeResumeFailure.UNSUPPORTED_VERSION -> EngineErrorCode.UNSUPPORTED
            }
            is ShelfStorageFailure -> EngineErrorCode.STORAGE
            is NativeShelfException -> when (error.failure) {
                NativeShelfFailure.INVALID_INPUT -> EngineErrorCode.INVALID_INPUT
                NativeShelfFailure.IDENTITY_CONFLICT -> EngineErrorCode.IDENTITY_CONFLICT
                NativeShelfFailure.AMBIGUOUS_IDENTITY -> EngineErrorCode.AMBIGUOUS_IDENTITY
                NativeShelfFailure.UNSUPPORTED_BOOK -> EngineErrorCode.UNSUPPORTED
                NativeShelfFailure.NOT_ON_SHELF -> EngineErrorCode.NOT_FOUND
            }
            is MissingEntity -> EngineErrorCode.NOT_FOUND
            is InvalidInput -> EngineErrorCode.INVALID_INPUT
            is HttpFailure -> EngineErrorCode.NETWORK
            is UnsupportedOperationException -> EngineErrorCode.UNSUPPORTED
            is kotlinx.io.IOException, is okio.IOException ->
                if (generateSequence<Throwable>(error) { it.cause }.take(16).any {
                    it is HttpRequestTimeoutException || it is ConnectTimeoutException || it is SocketTimeoutException
                }) EngineErrorCode.TIMEOUT else EngineErrorCode.NETWORK
            else -> EngineErrorCode.RULE
        }
        return EngineFailure(code, error.message ?: "Runtime operation failed")
    }
}

private class MissingEntity(message: String) : Exception(message)
private class InvalidInput(message: String) : Exception(message)
private class HttpFailure(status: Int) : Exception("HTTP $status")

private class ShelfStorageFailure(message: String) : Exception(message)

class ReadingSnapshot internal constructor(val token: String, val revision: Long,
    val paragraphUtf16Offset: Int, val restoreNotice: String, val canSave: Boolean)
class ReadingSaved internal constructor(val revision: Long, val paragraphUtf16Offset: Int,
    val eventSequence: Long) : EngineReply()
class ReadingFinished internal constructor() : EngineReply()
private class CacheUnavailable(message: String) : Exception(message)
private class StaleReading(message: String) : Exception(message)
private class ReadingSession(val owner: String, val sourceId: String, val bookId: String,
    val chapter: BookChapter, val body: String, var revision: Long, val canSave: Boolean,
    var projection: NativeChapterProjection, val storageNotice: String,
    var lastEvent: Long = 0)

/** All accesses hold EngineHost.gate, including cross-engine shelf removal. */
private object ReadingSessions {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    val tokens = mutableMapOf<String, ReadingSession>()
    fun invalidate(sourceId: String, bookId: String) {
        tokens.entries.removeAll { it.value.sourceId == sourceId && it.value.bookId == bookId }
    }
}
