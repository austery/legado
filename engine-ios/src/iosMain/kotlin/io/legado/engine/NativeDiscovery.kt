package io.legado.engine

import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookListPage
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.rule.ExploreKind
import io.legado.app.data.entities.rule.RowUi
import io.legado.app.help.source.clearExploreKindsCache
import io.legado.app.help.source.exploreKinds
import io.legado.app.model.webBook.BookListPager
import io.legado.app.model.webBook.ExploreOption
import io.legado.app.model.webBook.WebBook
import io.legado.app.model.webBook.WebBookResponsePolicy
import io.legado.app.model.webBook.parseExploreOptionsFromUrl
import io.legado.app.utils.concurrent.newConcurrentMap
import kotlinx.atomicfu.atomic
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

enum class DiscoveryPhase { LOADING_CATEGORIES, CATEGORIES, LOADING_BOOKS, IDLE, CANCELLED }
enum class DiscoveryCategoryKind { CATEGORY, HEADING, UNSUPPORTED }
class DiscoveryCategorySnapshot internal constructor(val id: String, val name: String,
    val kind: DiscoveryCategoryKind, val notice: String)
class DiscoveryChoiceSnapshot internal constructor(val label: String, val value: String, val selected: Boolean)
class DiscoveryOptionSnapshot internal constructor(val name: String, val multiSelect: Boolean,
    val choices: List<DiscoveryChoiceSnapshot>)
class DiscoveryUpdate internal constructor(val sessionId: String, val revision: Long,
    val sourceId: String, val sourceName: String, val phase: DiscoveryPhase,
    val categories: List<DiscoveryCategorySnapshot>, val categoryId: String?,
    val options: List<DiscoveryOptionSnapshot>, val books: List<BookSnapshot>,
    val hasNextPage: Boolean, val failure: EngineFailure?) : EngineReply()
class DiscoveryCommandAccepted internal constructor(val sessionId: String) : EngineReply()

/** Only validity metadata lives here; category values stay in upstream's cache. */
private object DiscoveryCategoryCache {
    private data class Stamp(val source: BookSource, val epoch: Long)
    private val epoch = atomic(0L)
    private class Entry { val gate = Mutex(); var stamp: Stamp? = null }
    private val registry = Mutex()
    private val entries = mutableMapOf<String, Entry>()
    fun invalidate() { epoch.incrementAndGet() }
    suspend fun load(source: BookSource, refresh: Boolean): List<ExploreKind> {
        val entry = registry.withLock { entries.getOrPut(source.bookSourceUrl) { Entry() } }
        return entry.gate.withLock {
            currentCoroutineContext().ensureActive()
            val stamp = Stamp(source.copy(), epoch.value)
            if (refresh || entry.stamp != stamp) source.clearExploreKindsCache()
            entry.stamp = stamp
            try {
                val kinds = source.copy().exploreKinds()
                currentCoroutineContext().ensureActive()
                if (epoch.value != stamp.epoch) throw CancellationException("Source configuration changed")
                EngineHost.interactionFailure()?.let { throw EngineHostRejection(it) }
                kinds.firstOrNull { it.title.startsWith("ERROR:") }?.let {
                    throw IllegalStateException(it.title.removePrefix("ERROR:"))
                }
                kinds
            } catch (error: Throwable) {
                // Upstream catches parser errors and may cache an ERROR row after cancellation.
                // Serialize cleanup before another category parser can use the same cache key.
                withContext(NonCancellable) { source.clearExploreKindsCache(); entry.stamp = null }
                throw error
            }
        }
    }
}

internal object DiscoverySessions {
    val sessions = newConcurrentMap<String, NativeDiscoverySession>()
    fun invalidateAll() {
        DiscoveryCategoryCache.invalidate()
        sessions.values.toList().forEach { it.invalidate() }
    }
}

internal enum class DiscoveryCommand { SELECT, OPTION, MORE, REFRESH, RETRY, CANCEL }
private enum class DiscoveryLifetime { ACTIVE, RETIRED, NOTIFY_CANCELLED }
private sealed interface DiscoveryEvent {
    data object Begin : DiscoveryEvent
    data class Categories(val generation: Long, val source: BookSource, val kinds: List<ExploreKind>) : DiscoveryEvent
    data class ResolvedOptions(val generation: Long, val options: List<ExploreOption>) : DiscoveryEvent
    data class Page(val generation: Long, val result: BookListPage) : DiscoveryEvent
    data class Failed(val generation: Long, val error: Throwable) : DiscoveryEvent
    data class Command(val kind: DiscoveryCommand, val categoryId: String, val option: String,
        val values: List<String>, val reply: CompletableDeferred<EngineReply>) : DiscoveryEvent
}

/** One source browser. Presentation state and the upstream pager belong to one event consumer. */
internal class NativeDiscoverySession(val id: String, private val sourceId: String,
    parentScope: CoroutineScope, private val resolveSource: suspend () -> BookSource,
    private val registerBooks: suspend (List<Book>) -> Unit,
    private val failure: (Throwable) -> EngineFailure, private val completion: (EngineReply) -> Unit) {
    private val owner = SupervisorJob(parentScope.coroutineContext.job)
    private val scope = CoroutineScope(parentScope.coroutineContext + owner)
    private val lifetime = atomic(DiscoveryLifetime.ACTIVE)
    private val events = Channel<DiscoveryEvent>(Channel.UNLIMITED)
    private val workers = mutableListOf<Job>()
    private var worker: Job? = null
    private var generation = 0L
    private var revision = 0L
    private var source: BookSource? = null
    private var categories = emptyList<ExploreKind>()
    private var categoryId: String? = null
    private var options = emptyList<ExploreOption>()
    private val books = linkedMapOf<String, BookSnapshot>()
    private val pager = BookListPager()
    private var phase = DiscoveryPhase.LOADING_CATEGORIES
    private var error: EngineFailure? = null

    fun start(): EngineRequest {
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                for (event in events) {
                    if (lifetime.value != DiscoveryLifetime.ACTIVE) break
                    consume(event)
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Throwable) {
                withContext(NonCancellable) { deliver(failure(error)) }
            } finally {
                val notify = lifetime.value == DiscoveryLifetime.NOTIFY_CANCELLED
                lifetime.compareAndSet(DiscoveryLifetime.ACTIVE, DiscoveryLifetime.RETIRED)
                owner.cancel()
                withContext(NonCancellable) {
                    if (notify) {
                        phase = DiscoveryPhase.CANCELLED
                        error = null
                        publish(cancelled = true)
                    }
                    workers.forEach { it.cancelAndJoin() }
                }
                events.close()
                while (true) {
                    val pending = events.tryReceive().getOrNull() ?: break
                    if (pending is DiscoveryEvent.Command) pending.reply.complete(inactive())
                }
            }
        }
        enqueue(DiscoveryEvent.Begin)
        return EngineRequest(owner, ::retire)
    }

    fun retire() { lifetime.value = DiscoveryLifetime.RETIRED; owner.cancel() }
    fun invalidate() {
        if (lifetime.compareAndSet(DiscoveryLifetime.ACTIVE, DiscoveryLifetime.NOTIFY_CANCELLED)) owner.cancel()
    }
    fun onRetired(action: () -> Unit) { owner.invokeOnCompletion { action() } }
    suspend fun command(kind: DiscoveryCommand, categoryId: String = "", option: String = "",
        values: List<String> = emptyList()): EngineReply {
        if (lifetime.value != DiscoveryLifetime.ACTIVE) return inactive()
        val reply = CompletableDeferred<EngineReply>(currentCoroutineContext().job)
        if (events.trySend(DiscoveryEvent.Command(kind, categoryId, option, values.toList(), reply)).isFailure) return inactive()
        val retired = owner.invokeOnCompletion { reply.complete(inactive()) }
        return try { reply.await() } finally { retired.dispose() }
    }
    private fun inactive() = EngineFailure(EngineErrorCode.CANCELLED, "Discovery session is no longer active")
    private fun enqueue(event: DiscoveryEvent) { if (lifetime.value == DiscoveryLifetime.ACTIVE) events.trySend(event) }

    private suspend fun consume(event: DiscoveryEvent) {
        when (event) {
            DiscoveryEvent.Begin -> loadCategories(refresh = false)
            is DiscoveryEvent.Categories -> if (event.generation == generation) {
                source = event.source
                categories = event.kinds.toList()
                phase = DiscoveryPhase.CATEGORIES
                error = null
                publish()
            }
            is DiscoveryEvent.ResolvedOptions -> if (event.generation == generation) {
                val previousSize = options.size
                event.options.forEach { discovered ->
                    if (options.none { it.name == discovered.name }) options = options + discovered
                }
                if (options.size != previousSize) publish()
            }
            is DiscoveryEvent.Page -> if (event.generation == generation) {
                val incoming = event.result.books.map { it.toBook().apply { origin = sourceId; originName = source?.bookSourceName.orEmpty() } }
                registerBooks(incoming)
                val previousSize = books.size
                incoming.forEach { book -> books.getOrPut(book.bookUrl) {
                    BookSnapshot(sourceId, book.bookUrl, book.name, book.author, book.intro.orEmpty()) } }
                pager.advance(event.result, previousSize, books.size)
                phase = DiscoveryPhase.IDLE
                error = null
                publish()
            }
            is DiscoveryEvent.Failed -> if (event.generation == generation) {
                error = failure(event.error)
                phase = if (categoryId == null) DiscoveryPhase.CATEGORIES else DiscoveryPhase.IDLE
                publish()
            }
            is DiscoveryEvent.Command -> {
                try {
                    when (event.kind) {
                        DiscoveryCommand.SELECT -> {
                            val index = categories.indices.singleOrNull { categoryKey(it) == event.categoryId }
                                ?: throw IllegalArgumentException("Choose a category in this discovery session")
                            if (categoryKind(categories[index]) != DiscoveryCategoryKind.CATEGORY)
                                throw UnsupportedOperationException("This category requires unsupported native controls")
                            categoryId = event.categoryId
                            options = parseExploreOptionsFromUrl(categories[index].url.orEmpty())
                            loadPage(reset = true)
                        }
                        DiscoveryCommand.OPTION -> {
                            val option = options.singleOrNull { it.name == event.option }
                                ?: throw IllegalArgumentException("Option is outside this category")
                            require(event.values.all { value -> option.options.any { it.second == value } }) { "Unknown option value" }
                            require(option.multiSelect || event.values.size <= 1) { "Choose one option value" }
                            if (event.values.isEmpty()) option.resetToDefault()
                            else if (option.multiSelect) { option.selectedValues.clear(); option.selectedValues.addAll(event.values) }
                            else option.selectedValue = event.values.single()
                            loadPage(reset = true)
                        }
                        DiscoveryCommand.MORE -> {
                            require(phase == DiscoveryPhase.IDLE && error == null && pager.hasNextPage && categoryId != null) { "No next discovery page is available" }
                            loadPage(reset = false)
                        }
                        DiscoveryCommand.REFRESH -> if (categoryId == null) loadCategories(refresh = true) else loadPage(reset = true)
                        DiscoveryCommand.RETRY -> {
                            require(error != null) { "No discovery failure to retry" }
                            if (categoryId == null) loadCategories(refresh = true) else loadPage(reset = false)
                        }
                        DiscoveryCommand.CANCEL -> invalidate()
                    }
                    event.reply.complete(DiscoveryCommandAccepted(id))
                } catch (cancelled: CancellationException) { event.reply.cancel(cancelled); throw cancelled }
                catch (error: Throwable) { event.reply.complete(failure(error)) }
            }
        }
    }

    private fun launchWorker(action: suspend () -> DiscoveryEvent) {
        worker?.cancel()
        val token = ++generation
        error = null
        workers.removeAll { it.isCompleted }
        worker = scope.launch {
            try { enqueue(action()) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Throwable) { enqueue(DiscoveryEvent.Failed(token, error)) }
        }.also { workers.add(it) }
    }
    private suspend fun loadCategories(refresh: Boolean) {
        phase = DiscoveryPhase.LOADING_CATEGORIES
        categoryId = null
        categories = emptyList(); options = emptyList(); books.clear(); pager.reset()
        val token = generation + 1
        launchWorker {
            val snapshot = resolveSource().copy()
            val kinds = runtime { DiscoveryCategoryCache.load(snapshot, refresh) }
            DiscoveryEvent.Categories(token, snapshot, kinds)
        }
        publish()
    }
    private suspend fun loadPage(reset: Boolean) {
        val snapshot = source?.copy() ?: throw IllegalArgumentException("Load discovery categories first")
        val index = categories.indices.singleOrNull { categoryKey(it) == categoryId }
            ?: throw IllegalArgumentException("Choose a discovery category")
        val url = categories[index].url.orEmpty()
        if (reset) { pager.reset(); books.clear() }
        val page = pager.page
        val next = pager.nextPageUrl
        val selected = options.associate { it.name to it.resolvedValue }
        val token = generation + 1
        phase = DiscoveryPhase.LOADING_BOOKS
        launchWorker {
            val result = runtime {
                val result = WebBook.getBookListAwait(snapshot, url, page, isSearch = false,
                    nextPageUrl = next, selectedOptions = selected,
                    onUrlResolved = {
                        val discovered = parseExploreOptionsFromUrl(it.ruleUrl)
                        if (discovered.isNotEmpty()) enqueue(DiscoveryEvent.ResolvedOptions(token, discovered))
                    })
                EngineHost.interactionFailure()?.let { throw EngineHostRejection(it) }
                result
            }
            DiscoveryEvent.Page(token, result)
        }
        publish()
    }
    private suspend fun <T> runtime(action: suspend () -> T): T = EngineHost.withSourceRequest(sourceId) {
        withContext(WebBookResponsePolicy { response -> if (!response.isSuccessful()) throw SearchHttpFailure(response.code()) }) {
            EngineHost.withOperation { action() }
        }
    }
    private fun categoryKey(index: Int) = "$id:category:$index"
    private fun categoryKind(kind: ExploreKind): DiscoveryCategoryKind = when {
        kind.type == RowUi.Type.title -> DiscoveryCategoryKind.HEADING
        kind.type != null && kind.type != RowUi.Type.text -> DiscoveryCategoryKind.UNSUPPORTED
        kind.url.isNullOrBlank() -> DiscoveryCategoryKind.HEADING
        kind.url!!.startsWith("plugin:", ignoreCase = true) -> DiscoveryCategoryKind.UNSUPPORTED
        else -> DiscoveryCategoryKind.CATEGORY
    }
    private suspend fun publish(cancelled: Boolean = false) {
        val kinds = categories.mapIndexed { index, kind ->
            val type = categoryKind(kind)
            DiscoveryCategorySnapshot(categoryKey(index), kind.title, type,
                if (type == DiscoveryCategoryKind.UNSUPPORTED) "This category needs controls that are not available in this native reader yet." else "")
        }
        val optionSnapshots = options.map { option -> DiscoveryOptionSnapshot(option.name, option.multiSelect,
            option.options.map { (label, value) -> DiscoveryChoiceSnapshot(label, value,
                if (option.multiSelect) value in option.selectedValues else value == option.selectedValue) }) }
        deliver(DiscoveryUpdate(id, ++revision, sourceId, source?.bookSourceName.orEmpty(), phase,
            kinds, categoryId, optionSnapshots, books.values.toList(),
            phase == DiscoveryPhase.IDLE && error == null && categoryId != null && pager.hasNextPage, error), cancelled)
    }
    private suspend fun deliver(reply: EngineReply, cancelled: Boolean = false) {
        withContext(Dispatchers.Main) {
            val deliver = if (cancelled) lifetime.compareAndSet(DiscoveryLifetime.NOTIFY_CANCELLED, DiscoveryLifetime.RETIRED)
                else lifetime.value == DiscoveryLifetime.ACTIVE
            if (deliver) completion(reply)
        }
    }
}
