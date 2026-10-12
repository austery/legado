package io.legado.engine

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
enum class EngineErrorCode { INVALID_INPUT, NOT_FOUND, NETWORK, TIMEOUT, RULE, UNSUPPORTED, INTERACTION_REQUIRED, CANCELLED, INTERNAL }
class EngineFailure internal constructor(val code: EngineErrorCode, val message: String) : EngineReply()
class SourceSnapshot internal constructor(val id: String, val name: String, val enabled: Boolean)
class SourcesReply internal constructor(val sources: List<SourceSnapshot>) : EngineReply()
class BookSnapshot internal constructor(val sourceId: String, val id: String, val title: String,
    val author: String, val intro: String)
class SearchReply internal constructor(val books: List<BookSnapshot>, val hasNextPage: Boolean) : EngineReply()
class BookReply internal constructor(val book: BookSnapshot) : EngineReply()
class ChapterSnapshot internal constructor(val sourceId: String, val bookId: String, val id: String,
    val index: Int, val title: String)
class TocReply internal constructor(val chapters: List<ChapterSnapshot>) : EngineReply()
class ContentReply internal constructor(val chapter: ChapterSnapshot, val text: String,
    val fromCache: Boolean) : EngineReply()
class EngineRequest internal constructor(private val job: Job) {
    fun cancel() { job.cancel() }
}

/** One host session. Call close when its owner leaves; initialization is process-wide. */
class ReaderEngine {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val books = mutableMapOf<Pair<String, String>, Book>()
    private val chapters = mutableMapOf<Pair<String, String>, List<BookChapter>>()
    private var initialized = false

    fun initialize(completion: (EngineReply) -> Unit): EngineRequest = request(completion, false) {
        try { EngineHost.initialize() }
        catch (error: Exception) { return@request EngineFailure(EngineErrorCode.INTERNAL, "Engine initialization failed: ${error.message}") }
        initialized = true
        EngineReady()
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

    /** Cache-only never fetches. Network mode reuses upstream pagination and text storage. */
    fun loadChapter(sourceId: String, bookId: String, chapterId: String, cacheOnly: Boolean,
        completion: (EngineReply) -> Unit): EngineRequest = request(completion) {
        val source = source(sourceId)
        val book = book(sourceId, bookId)
        val toc = chapters[sourceId to bookId] ?: throw MissingEntity("Load the table of contents first")
        val position = toc.indexOfFirst { it.url == chapterId }
        if (position < 0) throw MissingEntity("Chapter is not in this session's table of contents")
        val chapter = toc[position]
        val cached = BookStorageProviders.get().getContent(book, chapter)
        if (cached != null) {
            ContentReply(snapshot(sourceId, chapter), cached, true)
        } else {
            if (cacheOnly) throw MissingEntity("Chapter is not cached")
            val content = WebBook.getContentAwait(source, book, chapter,
                nextChapterUrl = toc.getOrNull(position + 1)?.url, needSave = false)
            currentCoroutineContext().ensureActive()
            val interaction = EngineHost.interactionFailure()
            if (interaction != null) {
                interaction
            } else {
                BookHelpProviders.get().saveContent(source, book, chapter, content)
                ContentReply(snapshot(sourceId, chapter), content, false)
            }
        }
    }

    fun close() { scope.cancel() }

    private suspend fun source(id: String): BookSource {
        val source = AppDbProviders.get().bookSourceDao.getBookSource(id) ?: throw MissingEntity("Source not found")
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
            val reply = try {
                withContext(Dispatchers.Default + WebBookResponsePolicy { response ->
                    if (!response.isSuccessful()) throw HttpFailure(response.code())
                }) {
                    EngineHost.gate.withLock {
                        EngineHost.beginOperation()
                        try {
                            if (requiresReady && !initialized) throw InvalidInput("Initialize this engine session first")
                            val result = action()
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
            } catch (e: CancellationException) {
                EngineFailure(EngineErrorCode.CANCELLED, "Request cancelled")
            } catch (e: Exception) {
                failure(e)
            }
            withContext(NonCancellable + Dispatchers.Main) {
                completion(if (operationJob.isCancelled)
                    EngineFailure(EngineErrorCode.CANCELLED, "Request cancelled") else reply)
            }
        }
        return EngineRequest(job)
    }

    private fun failure(error: Exception): EngineFailure {
        val code = when (error) {
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
