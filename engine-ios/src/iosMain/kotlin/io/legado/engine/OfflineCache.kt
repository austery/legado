package io.legado.engine

import io.legado.app.data.AppDatabaseProviders
import io.legado.app.data.AppDbProviders
import io.legado.app.data.dao.NativeBodyCoordinates
import io.legado.app.data.dao.NativeShelfEntry
import io.legado.app.data.entities.BookChapter
import io.legado.app.help.book.BookStorageProviders
import io.legado.app.help.book.BookHelpProviders
import io.legado.app.model.webBook.WebBook
import io.legado.app.model.webBook.WebBookResponsePolicy
import kotlinx.atomicfu.atomic
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.Mutex
import platform.Foundation.NSUUID

/** Read-ahead window after the displayed chapter; the upstream `preDownloadNum` default. */
private const val READ_AHEAD_CHAPTERS = 10

enum class OfflineAvailability { AVAILABLE, MISSING, UNAVAILABLE }
class OfflineChapter internal constructor(val chapterId: String, val availability: OfflineAvailability)
class OfflineStatus internal constructor(val chapters: List<OfflineChapter>, val optionalCount: Int) : EngineReply()
class CacheProgress internal constructor(val completed: Int, val target: Int,
    val failedChapterIds: List<String>, val running: Boolean, val cancelled: Boolean,
    val lastFailure: String) : EngineReply()
class CacheClearPrepared internal constructor(val token: String, val count: Int) : EngineReply()
class CacheCleared internal constructor(val deleted: Int, val failed: Int) : EngineReply()

private class YieldToReading : CancellationException("Foreground chapter takes priority")

/** One process-wide background batch and at most one in-flight chapter transfer. */
internal object OfflineWork {
    private class Batch(val job: Job, val manualBook: Pair<String, String>?)
    private val active = atomic<Batch?>(null)
    private val transfer = atomic<Job?>(null)
    val lane = Mutex()
    val deliveryScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    fun replace(job: Job, manualBook: Pair<String, String>?) {
        active.getAndSet(Batch(job, manualBook))?.job?.cancel()
    }

    fun cancel() { active.getAndSet(null)?.job?.cancel() }

    suspend fun retire(keepManualBook: Pair<String, String>? = null) {
        while (true) {
            val batch = active.value ?: return
            if (keepManualBook != null && batch.manualBook == keepManualBook) return
            if (active.compareAndSet(batch, null)) {
                batch.job.cancelAndJoin()
                return
            }
        }
    }

    fun trackTransfer(job: Job) { transfer.value = job }
    fun finishTransfer(job: Job) { transfer.compareAndSet(job, null) }

    // Called while holding EngineHost.gate. Transfers register under that gate and
    // do only network work, so joining one cannot wait for cache publication.
    suspend fun yieldTransfer() {
        val job = transfer.value ?: return
        job.cancel(YieldToReading())
        job.join()
    }
}

/** Storage and catalog operations hold EngineHost.gate; network work never holds it. */
internal class OfflineCache(private val scope: CoroutineScope,
    private val repairLocalCatalog: suspend (NativeShelfEntry) -> NativeShelfEntry,
    private val protectedChapters: (String, String) -> Set<String>) {
    private data class ClearPlan(val source: String, val book: String, val chapterIds: Set<String>)
    private val clearPlans = mutableMapOf<String, ClearPlan>()
    private val ownedJob = atomic<Job?>(null)
    fun cancel() { ownedJob.getAndSet(null)?.cancel() }
    private val dao get() = AppDatabaseProviders.get().appDb.nativeShelfDao
    private val storage get() = BookStorageProviders.get()

    internal suspend fun entry(source: String, book: String): NativeShelfEntry {
        val entry = dao.openBook(source, book)
        val folder = storage.getFolderName(entry.book)
        if (folder.isEmpty() || '/' in folder || '\\' in folder || folder == "." || folder == "..") {
            throw ShelfStorageFailure("Unsafe cache folder")
        }
        if (dao.cacheOwners().any { it.bookUrl != book && storage.getFolderName(it) == folder }) {
            throw ShelfStorageFailure("Cache folder ownership is ambiguous")
        }
        if (entry.chapters.map { it.getFileName() }.distinct().size != entry.chapters.size) {
            throw ShelfStorageFailure("Chapter cache ownership is ambiguous")
        }
        return repairLocalCatalog(entry)
    }

    private suspend fun availability(entry: NativeShelfEntry, chapter: BookChapter): OfflineAvailability {
        val body = storage.getContent(entry.book, chapter)
        val resume = dao.resume(entry.book.bookUrl)?.takeIf { it.chapterUrl == chapter.url }
        if (body.isNullOrBlank()) return if (storage.hasContent(entry.book, chapter))
            OfflineAvailability.UNAVAILABLE else OfflineAvailability.MISSING
        if (resume != null && (resume.sourceId != entry.book.origin ||
                resume.textVersion != NativeBodyCoordinates.VERSION ||
                resume.textSha256 != NativeBodyCoordinates.sha256(body) || resume.textUtf16Length != body.length)) {
            return OfflineAvailability.UNAVAILABLE
        }
        return OfflineAvailability.AVAILABLE
    }

    private suspend fun protected(entry: NativeShelfEntry): Set<String> {
        val saved = dao.resume(entry.book.bookUrl)?.chapterUrl ?:
            entry.chapters.firstOrNull { it.index == entry.book.durChapterIndex }?.url
        return protectedChapters(entry.book.origin, entry.book.bookUrl) + listOfNotNull(saved)
    }

    private suspend fun optional(entry: NativeShelfEntry): List<BookChapter> {
        val protected = protected(entry)
        return entry.chapters.filter { !it.isVolume && it.url !in protected && storage.hasContent(entry.book, it) }
    }

    suspend fun status(source: String, book: String): OfflineStatus {
        val entry = entry(source, book)
        return OfflineStatus(entry.chapters.filterNot { it.isVolume }.map {
            OfflineChapter(it.url, availability(entry, it))
        }, optional(entry).size)
    }

    suspend fun prepareClear(source: String, book: String): CacheClearPrepared {
        val entry = entry(source, book)
        val token = NSUUID().UUIDString
        clearPlans.clear()
        val ids = optional(entry).map { it.url }.toSet()
        clearPlans[token] = ClearPlan(source, book, ids)
        return CacheClearPrepared(token, ids.size)
    }

    suspend fun clear(token: String): CacheCleared {
        val plan = clearPlans.remove(token) ?: error("Prepare cache clearing again")
        val entry = entry(plan.source, plan.book)
        val eligible = optional(entry)
        check(eligible.map { it.url }.toSet() == plan.chapterIds) { "Cache or reading state changed; confirm the new count" }
        var deleted = 0
        var failed = 0
        for (chapter in eligible) {
            try {
                storage.delContent(entry.book, chapter)
                if (storage.hasContent(entry.book, chapter)) failed++ else deleted++
            } catch (error: Exception) { failed++ }
        }
        return CacheCleared(deleted, failed)
    }

    fun start(sourceId: String, bookId: String, afterChapterId: String?, prefetch: Boolean,
        completion: (EngineReply) -> Unit): EngineRequest {
        val terminal = atomic(false)
        val latest = atomic<CacheProgress?>(null)
        val job = scope.launch(start = CoroutineStart.LAZY) {
            var completed = 0
            var target = 0
            var lastFailure = ""
            val failures = mutableListOf<String>()
            suspend fun report(running: Boolean, cancelled: Boolean = false) {
                val reply = CacheProgress(completed, target, failures.toList(), running, cancelled, lastFailure)
                latest.value = reply
                if (!running && !terminal.compareAndSet(false, true)) return
                withContext(NonCancellable + Dispatchers.Main) { completion(reply) }
            }
            try {
                OfflineWork.lane.withLock {
                    val initial = EngineHost.gate.withLock { entry(sourceId, bookId) }
                    val selected = EngineHost.gate.withLock {
                        val anchor = afterChapterId ?: dao.resume(bookId)?.chapterUrl ?:
                            initial.chapters.firstOrNull { it.index == initial.book.durChapterIndex }?.url
                        val start = initial.chapters.indexOfFirst { it.url == anchor }
                        check(start >= 0) { "Open a chapter before caching" }
                        initial.chapters.drop(start + 1).filterNot { it.isVolume }
                            .take(if (prefetch) READ_AHEAD_CHAPTERS else 20)
                    }
                    target = selected.size
                    report(true)
                    for (chapter in selected) {
                        currentCoroutineContext().ensureActive()
                        try {
                            // A foreground miss yields one network transfer. Keep the selected
                            // range and recheck storage before retrying the same chapter.
                            while (!cacheChapter(initial, chapter, sourceId, bookId, prefetch)) {
                                currentCoroutineContext().ensureActive()
                            }
                            completed++
                        } catch (cancelled: CancellationException) { throw cancelled }
                        catch (error: Exception) {
                            failures.add(chapter.url)
                            lastFailure = error.message ?: "Chapter could not be cached"
                        }
                        report(true)
                    }
                    report(false)
                }
            } catch (cancelled: CancellationException) { report(false, true) }
            catch (error: Exception) {
                if (terminal.compareAndSet(false, true)) withContext(NonCancellable + Dispatchers.Main) {
                    completion(EngineFailure(EngineErrorCode.STORAGE, error.message ?: "Cache operation failed"))
                }
            }
        }
        // A lazy job cancelled before its first dispatch never enters the try/catch above.
        job.invokeOnCompletion {
            if (terminal.compareAndSet(false, true)) {
                val previous = latest.value
                OfflineWork.deliveryScope.launch {
                    completion(CacheProgress(previous?.completed ?: 0, previous?.target ?: 0,
                        previous?.failedChapterIds.orEmpty(), false, true, previous?.lastFailure.orEmpty()))
                }
            }
        }
        OfflineWork.replace(job, if (prefetch) null else sourceId to bookId)
        ownedJob.getAndSet(job)?.cancel()
        job.start()
        return EngineRequest(job)
    }

    private suspend fun cacheChapter(initial: NativeShelfEntry, chapter: BookChapter,
        sourceId: String, bookId: String, prefetch: Boolean): Boolean = supervisorScope {
        val (source, transfer) = EngineHost.gate.withLock {
            val current = entry(sourceId, bookId)
            check(sameCatalog(initial, current)) { "Stored catalog changed" }
            if (availability(current, chapter) == OfflineAvailability.AVAILABLE) return@supervisorScope true
            check(chapter.url !in protected(current)) { "Protected chapter cannot be replaced by caching" }
            val source = AppDbProviders.get().bookSourceDao.getBookSource(sourceId)?.also {
                check(it.enabled && it.bookSourceType == 0) { "Source is unavailable" }
            } ?: error("Source is missing")
            val transfer = async(start = CoroutineStart.LAZY) {
                withContext(WebBookResponsePolicy { response ->
                    check(response.isSuccessful()) { "HTTP ${response.code()}" }
                }) {
                    EngineHost.withOperation {
                        EngineHost.withSourceRequest(sourceId, background = true, reserveForeground = prefetch) {
                            WebBook.getContentAwait(source, initial.book.copy(), chapter.copy(),
                                nextChapterUrl = initial.chapters.getOrNull(initial.chapters.indexOf(chapter) + 1)?.url,
                                needSave = false)
                        }.also { EngineHost.interactionFailure()?.let { failure -> error(failure.message) } }
                    }
                }
            }
            OfflineWork.trackTransfer(transfer)
            source to transfer
        }
        val body = try {
            transfer.await()
        } catch (interrupted: YieldToReading) {
            currentCoroutineContext().ensureActive()
            return@supervisorScope false
        } finally {
            OfflineWork.finishTransfer(transfer)
        }
        currentCoroutineContext().ensureActive()
        check(body.isNotBlank()) { "Empty chapter response" }
        EngineHost.gate.withLock {
            val current = entry(sourceId, bookId)
            check(sameCatalog(initial, current) &&
                AppDbProviders.get().bookSourceDao.getBookSource(sourceId) == source) { "Source or catalog changed" }
            // The reader may have saved this body while publication waited for the gate.
            if (availability(current, chapter) != OfflineAvailability.AVAILABLE) {
                check(chapter.url !in protected(current)) { "Chapter became protected" }
                currentCoroutineContext().ensureActive()
                BookHelpProviders.get().saveContent(source, current.book, chapter, body)
                check(storage.getContent(current.book, chapter) == body) { "Cache write could not be verified" }
            }
        }
        true
    }

    private fun sameCatalog(first: NativeShelfEntry, second: NativeShelfEntry): Boolean =
        storage.getFolderName(first.book) == storage.getFolderName(second.book) &&
            first.chapters == second.chapters
}
