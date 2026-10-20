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
import io.legado.app.utils.concurrent.newConcurrentMap
import kotlinx.atomicfu.atomic
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
class SourceSwitchPrepared internal constructor(val token: String, val chapter: ChapterSnapshot,
    val previousBook: BookSnapshot, val replacementBook: BookSnapshot) : EngineReply()
class SearchReply internal constructor(val books: List<BookSnapshot>, val hasNextPage: Boolean) : EngineReply()
class BookReply internal constructor(val book: BookSnapshot) : EngineReply()
class ChapterSnapshot internal constructor(val sourceId: String, val bookId: String, val id: String,
    val index: Int, val title: String, val isVolume: Boolean = false)
class TocReply internal constructor(val chapters: List<ChapterSnapshot>) : EngineReply()
class ContentReply internal constructor(val chapter: ChapterSnapshot, val text: String,
    val fromCache: Boolean, val reading: ReadingSnapshot? = null,
    val storageNotice: String = "") : EngineReply()
class EngineRequest internal constructor(private val job: Job, private val onCancel: (() -> Unit)? = null) {
    fun cancel() { onCancel?.invoke(); job.cancel() }
}

/** One host session. Call close when its owner leaves; initialization is process-wide. */
class ReaderEngine {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val books = mutableMapOf<Pair<String, String>, Book>()
    private val chapters = mutableMapOf<Pair<String, String>, List<BookChapter>>()
    private var initialized = false
    private val closed = atomic(false)
    private val activeSearch = atomic<NativeSearchSession?>(null)
    private val ownedSearches = newConcurrentMap<String, NativeSearchSession>()
    private val sessionId = NSUUID().UUIDString
    private val preparedSwitches = mutableMapOf<String, PreparedSourceSwitch>()
    private val committedSwitches = mutableMapOf<String, CommittedSourceSwitch>()
    private val offlineCache = OfflineCache(scope) { source, book ->
        ReadingSessions.tokens.values.filter { it.sourceId == source && it.bookId == book }
            .map { it.chapter.url }.toSet()
    }

    fun offlineStatus(sourceId: String, bookId: String, completion: (EngineReply) -> Unit): EngineRequest =
        request(completion, interruptCache = false) { offlineCache.status(sourceId, bookId) }

    fun cacheNextChapters(sourceId: String, bookId: String, afterChapterId: String?,
        prefetch: Boolean, completion: (EngineReply) -> Unit): EngineRequest =
        offlineCache.start(sourceId, bookId, afterChapterId, if (prefetch) 2 else 20, completion)

    fun cancelCaching() { offlineCache.cancel() }

    fun prepareCacheClear(sourceId: String, bookId: String, completion: (EngineReply) -> Unit): EngineRequest =
        request(completion) { offlineCache.prepareClear(sourceId, bookId) }

    fun clearOptionalCache(token: String, completion: (EngineReply) -> Unit): EngineRequest =
        request(completion) { offlineCache.clear(token) }

    fun prepareSourceSwitch(oldSourceId: String, oldBookId: String, sourceId: String,
        bookId: String, chapterId: String, completion: (EngineReply) -> Unit): EngineRequest = request(completion) {
        preparedSwitches.clear()
        committedSwitches.clear()
        val dao = AppDatabaseProviders.get().appDb.nativeShelfDao
        val original = dao.openBook(oldSourceId, oldBookId).book.copy()
        val revision = dao.resume(oldBookId)?.revision ?: 0L
        val candidate = book(sourceId, bookId).copy()
        if (candidate.name.trim().isEmpty() || candidate.author.trim().isEmpty() ||
            candidate.name.trim() != original.name.trim() || candidate.author.trim() != original.author.trim() ||
            bookId == oldBookId) throw InvalidInput("Select another listing with the same known title and author")
        // Cache directories include the title; use the preserved work identity before writing.
        candidate.name = original.name
        candidate.author = original.author
        val catalog = chapters[sourceId to bookId]?.map { it.copy() } ?: throw InvalidInput("Load the replacement catalog")
        val chapter = catalog.singleOrNull { it.url == chapterId && !it.isVolume }
            ?: throw InvalidInput("Choose a readable replacement chapter")
        val targetSource = source(sourceId)
        val body = EngineHost.withSourceRequest(sourceId) {
            WebBook.getContentAwait(targetSource, candidate, chapter,
                nextChapterUrl = catalog.getOrNull(catalog.indexOf(chapter) + 1)?.url, needSave = false)
        }
        currentCoroutineContext().ensureActive()
        if (body.isEmpty()) throw CacheUnavailable("Replacement chapter is empty")
        EngineHost.interactionFailure()?.let { return@request it }
        val token = NSUUID().UUIDString
        // Keep preparation in memory. A conflicting listing must never overwrite another book's cache.
        preparedSwitches[token] = PreparedSourceSwitch(original, revision,
            NativeChapterProjection.from(original), candidate, catalog, chapter, body, targetSource)
        SourceSwitchPrepared(token, snapshot(sourceId, chapter), snapshot(original), snapshot(candidate))
    }

    fun cancelSourceSwitch(completion: (EngineReply) -> Unit): EngineRequest = request(completion) {
        preparedSwitches.clear()
        committedSwitches.clear()
        EngineReady()
    }

    /** Only this engine's successfully committed token can recover a lost acknowledgment. */
    fun recoverSourceSwitch(token: String, completion: (EngineReply) -> Unit): EngineRequest = request(completion) {
        val committed = committedSwitches[token] ?: throw StaleReading("This source switch did not commit")
        val dao = AppDatabaseProviders.get().appDb.nativeShelfDao
        val entry = shelfOperation { dao.openBook(committed.entry.book.origin, committed.entry.book.bookUrl) }
        val resume = dao.resume(entry.book.bookUrl)
        if (entry != committed.entry || resume == null || resume.revision != committed.revision ||
            resume.textSha256 != committed.bodyHash || dao.listBooks().any { it.bookUrl == committed.oldBookId }) {
            throw StaleReading("Shelf changed after the switch; reopen it from the library")
        }
        acceptShelfEntry(entry)
    }

    fun commitSourceSwitch(token: String, completion: (EngineReply) -> Unit): EngineRequest = request(completion) {
        val prepared = preparedSwitches.remove(token) ?: throw StaleReading("Prepare the source switch again")
        if (source(prepared.candidate.origin) != prepared.source) throw StaleReading("Source rules changed; prepare again")
        currentCoroutineContext().ensureActive()
        // Complete the transaction and invalidate old tokens even if foreground delivery is cancelled.
        withContext(NonCancellable) {
            val entry = shelfOperation {
                AppDatabaseProviders.get().appDb.nativeShelfDao.switchSource(
                    prepared.original.origin, prepared.original.bookUrl, prepared.revision, prepared.projection,
                    prepared.candidate, prepared.catalog, prepared.chapter.url, prepared.body, prepared.source) {
                    val storage = BookStorageProviders.get()
                    storage.saveText(prepared.candidate, prepared.chapter, prepared.body)
                    if (storage.getContent(prepared.candidate, prepared.chapter) != prepared.body) {
                        throw CacheUnavailable("Published replacement body could not be verified")
                    }
                }
            }
            committedSwitches[token] = CommittedSourceSwitch(
                NativeShelfEntry(entry.book.copy(), entry.chapters.map { it.copy() }),
                prepared.original.bookUrl, prepared.revision + 1, NativeBodyCoordinates.sha256(prepared.body))
            ReadingSessions.invalidate(prepared.original.origin, prepared.original.bookUrl)
            books.remove(prepared.original.origin to prepared.original.bookUrl)
            chapters.remove(prepared.original.origin to prepared.original.bookUrl)
            acceptShelfEntry(entry)
        }
    }

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
        activeSearch.getAndSet(null)?.retire()
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
        catch (error: NativeResumeException) { throw error }
        catch (error: Exception) { throw ShelfStorageFailure(error.message ?: "Shelf storage failed") }

    /** Empty sourceIds means every enabled text source; explicit IDs never widen scope. */
    fun startSearch(query: String, sourceIds: List<String>, completion: (EngineReply) -> Unit): EngineRequest {
        activeSearch.getAndSet(null)?.retire()
        if (closed.value) return request(completion, false) {
            EngineFailure(EngineErrorCode.CANCELLED, "Engine session is closed")
        }
        if (query.isBlank()) return request(completion, false) { throw InvalidInput("Search requires a nonblank query") }
        if (!initialized) return request(completion, false) { throw InvalidInput("Initialize this engine session first") }
        val selectedIds = sourceIds.toList()
        val search = NativeSearchSession(NSUUID().UUIDString, query, scope,
            resolveSources = {
                EngineHost.gate.withLock {
                    if (!initialized) throw InvalidInput("Initialize this engine session first")
                    val dao = AppDbProviders.get().bookSourceDao
                    val resolved = if (selectedIds.isEmpty()) {
                        dao.allTextEnabledPart().map { source(it.bookSourceUrl) }
                    } else selectedIds.distinct().map { source(it) }
                    if (resolved.isEmpty()) throw MissingEntity("No enabled text sources are available")
                    resolved
                }
            },
            registerBooks = { incoming ->
                EngineHost.gate.withLock {
                    incoming.forEach { candidate -> books.getOrPut(candidate.origin to candidate.bookUrl) { candidate } }
                }
            },
            failure = { error -> failure(error as? Exception ?: Exception(error.message, error)) },
            completion = completion)
        ownedSearches[search.id] = search
        search.onRetired { ownedSearches.remove(search.id) }
        activeSearch.getAndSet(search)?.retire()
        if (closed.value) search.retire()
        return search.start()
    }

    fun loadMoreSearch(searchSessionId: String, completion: (EngineReply) -> Unit): EngineRequest =
        searchCommand(searchSessionId, SearchCommand.LOAD_MORE, "", completion)

    fun retrySearchSource(searchSessionId: String, sourceId: String, completion: (EngineReply) -> Unit): EngineRequest =
        searchCommand(searchSessionId, SearchCommand.RETRY, sourceId, completion)

    fun restartSearchSource(searchSessionId: String, sourceId: String, completion: (EngineReply) -> Unit): EngineRequest =
        searchCommand(searchSessionId, SearchCommand.RESTART, sourceId, completion)

    fun cancelSearch(searchSessionId: String, completion: (EngineReply) -> Unit): EngineRequest =
        searchCommand(searchSessionId, SearchCommand.CANCEL, "", completion)

    private fun searchCommand(searchSessionId: String, command: SearchCommand, sourceId: String,
        completion: (EngineReply) -> Unit): EngineRequest {
        val job = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            val operationJob = currentCoroutineContext().job
            val reply = try {
                val search = if (command == SearchCommand.CANCEL) ownedSearches[searchSessionId] else activeSearch.value
                if (search == null || search.id != searchSessionId)
                    EngineFailure(EngineErrorCode.CANCELLED, "Search session is no longer active")
                else search.command(command, sourceId)
            } catch (error: CancellationException) {
                EngineFailure(EngineErrorCode.CANCELLED, "Search command cancelled")
            } catch (error: Exception) { failure(error) }
            withContext(NonCancellable + Dispatchers.Main) {
                completion(if (operationJob.isCancelled) EngineFailure(EngineErrorCode.CANCELLED, "Search command cancelled") else reply)
            }
        }
        return EngineRequest(job)
    }

    fun search(sourceId: String, query: String, page: Int, completion: (EngineReply) -> Unit): EngineRequest = request(completion) {
        if (page <= 0 || query.isBlank()) throw InvalidInput("Search requires a query and positive page")
        val source = source(sourceId)
        val result = EngineHost.withSourceRequest(sourceId) { WebBook.getBookListAwait(source, query, page) }
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
        EngineHost.withSourceRequest(sourceId) { WebBook.getBookInfoAwait(source, book) }
        BookReply(snapshot(book))
    }

    fun loadToc(sourceId: String, bookId: String, completion: (EngineReply) -> Unit): EngineRequest = request(completion) {
        val source = source(sourceId)
        val book = book(sourceId, bookId)
        val result = EngineHost.withSourceRequest(sourceId) { WebBook.getChapterListAwait(source, book).getOrThrow() }
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
            val downloaded = EngineHost.withSourceRequest(sourceId) {
                WebBook.getContentAwait(source, book, chapter,
                    nextChapterUrl = toc.getOrNull(position + 1)?.url, needSave = false)
            }
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
        closed.value = true
        offlineCache.cancel()
        activeSearch.getAndSet(null)?.retire()
        scope.cancel()
        ReadingSessions.scope.launch(start = CoroutineStart.UNDISPATCHED) {
            EngineHost.gate.withLock {
                ReadingSessions.tokens.entries.removeAll { it.value.owner == sessionId }
                preparedSwitches.clear()
                committedSwitches.clear()
            }
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
        ChapterSnapshot(sourceId, chapter.bookUrl, chapter.url, chapter.index, chapter.title, chapter.isVolume)

    @OptIn(ExperimentalCoroutinesApi::class)
    private fun request(completion: (EngineReply) -> Unit, requiresReady: Boolean = true, interruptCache: Boolean = true,
        action: suspend () -> EngineReply): EngineRequest {
        val job = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            val operationJob = currentCoroutineContext().job
            var createdReadingToken: String? = null
            val reply = try {
                if (interruptCache) OfflineWork.retire()
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
            is HttpFailure, is SearchHttpFailure -> EngineErrorCode.NETWORK
            is TimeoutCancellationException -> EngineErrorCode.TIMEOUT
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
private data class CommittedSourceSwitch(val entry: NativeShelfEntry, val oldBookId: String,
    val revision: Long, val bodyHash: String)
private data class PreparedSourceSwitch(val original: Book, val revision: Long,
    val projection: NativeChapterProjection, val candidate: Book, val catalog: List<BookChapter>,
    val chapter: BookChapter, val body: String, val source: BookSource)

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
