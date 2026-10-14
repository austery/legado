package io.legado.engine

import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.SearchBook
import io.legado.app.model.webBook.SearchModel
import io.legado.app.model.webBook.SourcePageOutcome
import io.legado.app.model.webBook.SourceSearchGroup
import io.legado.app.model.webBook.WebBookResponsePolicy
import io.legado.app.ui.book.search.SearchScope
import kotlinx.atomicfu.atomic
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel

enum class SearchPhase { SEARCHING, IDLE, CANCELLED }
enum class SearchSourceStatus { PENDING, RUNNING, SUCCESS, EMPTY, FAILED, CANCELLED }
class SearchCandidateSnapshot internal constructor(val id: String, val book: BookSnapshot, val sourceName: String)
class SearchWorkSnapshot internal constructor(val id: String, val title: String, val author: String,
    val candidates: List<SearchCandidateSnapshot>, val sourceCount: Int)
class SearchSourceSnapshot internal constructor(val sourceId: String, val name: String,
    val page: Int, val hasNextPage: Boolean, val status: SearchSourceStatus, val failure: EngineFailure?, val generation: Int)
class SearchUpdate internal constructor(val sessionId: String, val revision: Long, val phase: SearchPhase,
    val works: List<SearchWorkSnapshot>, val sources: List<SearchSourceSnapshot>, val hasNextPage: Boolean) : EngineReply()
class SearchCommandAccepted internal constructor(val sessionId: String) : EngineReply()

private data class OwnedCandidate(val immutableBookSnapshot: BookSnapshot, val registrationBook: Book,
    val sourceName: String)
private data class CandidateGroup(val sourceId: String, val generation: Int, val candidates: List<OwnedCandidate>)
private class NativeSourceState(val id: String, val name: String) {
    var generation = 0
    var minimumGroupGeneration = 0
    var page = 0
    var hasNextPage = false
    var status = SearchSourceStatus.PENDING
    var failure: EngineFailure? = null
}
internal enum class SearchCommand { LOAD_MORE, RETRY, RESTART, CANCEL }
private sealed interface SearchEvent {
    data class Sources(val sources: List<BookSource>) : SearchEvent
    data class Started(val id: String, val generation: Int, val page: Int) : SearchEvent
    data class Finished(val id: String, val generation: Int, val page: Int, val outcome: SourcePageOutcome) : SearchEvent
    data class Groups(val groups: List<CandidateGroup>) : SearchEvent
    data object RoundFinished : SearchEvent
    data class Aborted(val error: Throwable?) : SearchEvent
    data class Command(val kind: SearchCommand, val sourceId: String, val reply: CompletableDeferred<EngineReply>) : SearchEvent
}

/** An owned query lifetime; all presentation state is confined to its event consumer. */
internal class NativeSearchSession(
    val id: String,
    private val query: String,
    parentScope: CoroutineScope,
    private val resolveSources: suspend () -> List<BookSource>,
    private val registerBooks: suspend (List<Book>) -> Unit,
    private val failure: (Throwable) -> EngineFailure,
    private val completion: (EngineReply) -> Unit,
) {
    private val active = atomic(true)
    private val owner = SupervisorJob(parentScope.coroutineContext.job)
    private val scope = CoroutineScope(parentScope.coroutineContext + owner)
    private val events = Channel<SearchEvent>(Channel.UNLIMITED)
    private val states = linkedMapOf<String, NativeSourceState>()
    private val candidates = linkedMapOf<String, List<OwnedCandidate>>()
    private var startupJob: Job? = null
    private var revision = 0L
    private var phase = SearchPhase.SEARCHING
    private val callback = object : SearchModel.CallBack {
        override fun getSearchScope() = SearchScope("")
        override fun onSearchStart() = Unit
        override fun onSearchSuccess(searchBooks: List<SearchBook>) = Unit
        override fun onSearchSourcesResolved(sources: List<BookSource>) { enqueue(SearchEvent.Sources(sources)) }
        override fun onSourcePageStarted(sourceId: String, generation: Int, page: Int) {
            enqueue(SearchEvent.Started(sourceId, generation, page))
        }
        override fun onSourcePageFinished(sourceId: String, generation: Int, page: Int, outcome: SourcePageOutcome) {
            enqueue(SearchEvent.Finished(sourceId, generation, page, outcome))
        }
        override fun onSearchGroupsChanged(groups: List<SourceSearchGroup>) {
            // Freeze values synchronously while SearchModel owns its result lock.
            enqueue(SearchEvent.Groups(groups.map { group -> CandidateGroup(group.source.bookSourceUrl, group.generation,
                group.books.map { book -> OwnedCandidate(
                    BookSnapshot(group.source.bookSourceUrl, book.bookUrl, book.name, book.author, book.intro.orEmpty()),
                    book.toBook().apply { origin = group.source.bookSourceUrl; originName = group.source.bookSourceName },
                    group.source.bookSourceName)
                }) }))
        }
        override fun onSearchFinish(isEmpty: Boolean, hasMore: Boolean) { enqueue(SearchEvent.RoundFinished) }
        override fun onSearchCancel(exception: Throwable?) { enqueue(SearchEvent.Aborted(exception)) }
    }
    private val model = SearchModel(scope, callback, resolveSources, { source, _, action ->
        EngineHost.withSourceRequest(source.bookSourceUrl) {
            withContext(WebBookResponsePolicy { response ->
                if (!response.isSuccessful()) throw SearchHttpFailure(response.code())
            }) {
                EngineHost.withOperation {
                    val page = action()
                    EngineHost.interactionFailure()?.let { throw EngineHostRejection(it) }
                    page
                }
            }
        }
    })

    fun start(): EngineRequest {
        scope.launch {
            try {
                for (event in events) {
                    if (!active.value) break
                    consume(event)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                withContext(NonCancellable) {
                    owner.cancel()
                    startupJob?.cancelAndJoin()
                    model.closeAndJoin()
                    deliver(failure(error))
                }
            } finally {
                active.value = false
                owner.cancel()
                withContext(NonCancellable) { startupJob?.cancelAndJoin(); model.closeAndJoin() }
                events.close()
                while (true) {
                    val pending = events.tryReceive().getOrNull() ?: break
                    if (pending is SearchEvent.Command)
                        pending.reply.complete(EngineFailure(EngineErrorCode.CANCELLED, "Search session is no longer active"))
                }
            }
        }
        startupJob = scope.launch {
            try { model.search(1L, query) }
            catch (error: CancellationException) { throw error }
            catch (error: Throwable) { enqueue(SearchEvent.Aborted(error)) }
        }
        return EngineRequest(owner, ::retire)
    }

    fun retire() {
        active.value = false
        owner.cancel()
    }

    fun onRetired(action: () -> Unit) { owner.invokeOnCompletion { action() } }

    suspend fun command(kind: SearchCommand, sourceId: String): EngineReply {
        if (!active.value) {
            if (kind == SearchCommand.CANCEL) owner.join()
            return EngineFailure(EngineErrorCode.CANCELLED, "Search session is no longer active")
        }
        val reply = CompletableDeferred<EngineReply>(currentCoroutineContext().job)
        if (events.trySend(SearchEvent.Command(kind, sourceId, reply)).isFailure)
            return EngineFailure(EngineErrorCode.CANCELLED, "Search session is no longer active")
        val retirement = owner.invokeOnCompletion {
            reply.complete(EngineFailure(EngineErrorCode.CANCELLED, "Search session is no longer active"))
        }
        return try { reply.await() } finally { retirement.dispose() }
    }

    private fun enqueue(event: SearchEvent) { if (active.value) events.trySend(event) }

    private suspend fun consume(event: SearchEvent) {
        when (event) {
            is SearchEvent.Sources -> {
                event.sources.forEach { states[it.bookSourceUrl] = NativeSourceState(it.bookSourceUrl, it.bookSourceName) }
                publish()
            }
            is SearchEvent.Started -> {
                val state = states[event.id] ?: return
                if (state.generation != event.generation) return
                state.page = event.page
                state.status = SearchSourceStatus.RUNNING
                state.failure = null
                phase = SearchPhase.SEARCHING
                publish()
            }
            is SearchEvent.Finished -> {
                val state = states[event.id] ?: return
                if (state.generation != event.generation) return
                state.page = event.page
                when (val outcome = event.outcome) {
                    is SourcePageOutcome.Success -> {
                        state.hasNextPage = outcome.hasNextPage
                        state.status = if (outcome.isEmpty && candidates[state.id].isNullOrEmpty()) SearchSourceStatus.EMPTY else SearchSourceStatus.SUCCESS
                        state.failure = null
                    }
                    is SourcePageOutcome.Failure -> {
                        state.status = SearchSourceStatus.FAILED
                        state.hasNextPage = false
                        state.failure = failure(outcome.error)
                    }
                    SourcePageOutcome.Cancelled -> state.status = SearchSourceStatus.CANCELLED
                }
                phase = if (states.values.any { it.status == SearchSourceStatus.RUNNING || it.status == SearchSourceStatus.PENDING })
                    SearchPhase.SEARCHING else SearchPhase.IDLE
                publish()
            }
            is SearchEvent.Groups -> {
                val accepted = event.groups.filter { group ->
                    val state = states[group.sourceId]
                    state != null && group.generation in state.minimumGroupGeneration..state.generation
                }
                registerBooks(accepted.flatMap { it.candidates }.map { it.registrationBook })
                candidates.clear()
                accepted.forEach { candidates[it.sourceId] = it.candidates }
                publish()
            }
            SearchEvent.RoundFinished -> {
                phase = if (states.values.any { it.status == SearchSourceStatus.RUNNING || it.status == SearchSourceStatus.PENDING })
                    SearchPhase.SEARCHING else SearchPhase.IDLE
                publish()
            }
            is SearchEvent.Aborted -> {
                phase = SearchPhase.IDLE
                if (states.isEmpty()) {
                    startupJob?.cancelAndJoin()
                    model.closeAndJoin()
                    deliver(event.error?.let(failure) ?: EngineFailure(EngineErrorCode.CANCELLED, "Search stopped"))
                    retire()
                } else publish()
            }
            is SearchEvent.Command -> consumeCommand(event)
        }
    }

    private suspend fun consumeCommand(event: SearchEvent.Command) {
        try {
            when (event.kind) {
                SearchCommand.CANCEL -> {
                    startupJob?.cancelAndJoin()
                    model.closeAndJoin()
                    states.values.filter { it.status == SearchSourceStatus.PENDING || it.status == SearchSourceStatus.RUNNING }
                        .forEach { it.status = SearchSourceStatus.CANCELLED }
                    states.values.forEach { it.hasNextPage = false }
                    phase = SearchPhase.CANCELLED
                    publish()
                    active.value = false
                }
                SearchCommand.LOAD_MORE -> {
                    if (phase == SearchPhase.SEARCHING) {
                        event.reply.complete(EngineFailure(EngineErrorCode.INVALID_INPUT, "Search is already running")); return
                    }
                    val eligible = states.values.filter { it.hasNextPage &&
                        (it.status == SearchSourceStatus.SUCCESS || it.status == SearchSourceStatus.EMPTY) }
                    if (eligible.isEmpty()) {
                        event.reply.complete(EngineFailure(EngineErrorCode.INVALID_INPUT, "No source has another page")); return
                    }
                    eligible.forEach { it.status = SearchSourceStatus.PENDING }
                    model.loadMore()
                    publish()
                }
                SearchCommand.RETRY, SearchCommand.RESTART -> {
                    val state = states[event.sourceId]
                    if (state == null) {
                        event.reply.complete(EngineFailure(EngineErrorCode.NOT_FOUND, "Source is outside this search scope")); return
                    }
                    if (event.kind == SearchCommand.RETRY && state.status != SearchSourceStatus.FAILED) {
                        event.reply.complete(EngineFailure(EngineErrorCode.INVALID_INPUT, "Only a failed source can be retried")); return
                    }
                    state.generation++
                    state.status = SearchSourceStatus.PENDING
                    state.failure = null
                    if (event.kind == SearchCommand.RESTART) {
                        state.minimumGroupGeneration = state.generation
                        candidates.remove(state.id)
                        state.page = 0
                        state.hasNextPage = false
                        model.restartSource(state.id)
                    } else model.retrySource(state.id)
                    phase = SearchPhase.SEARCHING
                    publish()
                }
            }
            event.reply.complete(SearchCommandAccepted(id))
            if (event.kind == SearchCommand.CANCEL) { events.close(); owner.cancel() }
        } catch (error: CancellationException) { event.reply.cancel(error); throw error }
        catch (error: Throwable) { event.reply.complete(failure(error)) }
    }

    private suspend fun publish() {
        if (phase != SearchPhase.CANCELLED) {
            phase = if (states.values.any { it.status == SearchSourceStatus.PENDING || it.status == SearchSourceStatus.RUNNING })
                SearchPhase.SEARCHING else SearchPhase.IDLE
        }
        val grouped = linkedMapOf<String, MutableList<SearchCandidateSnapshot>>()
        candidates.values.flatten().forEach { candidate ->
            val book = candidate.immutableBookSnapshot
            val candidateId = identity("candidate", book.sourceId, book.id)
            val groupId = if (book.title.isNotBlank() && book.author.isNotBlank())
                identity("work", book.title, book.author) else candidateId
            val group = grouped.getOrPut(groupId) { arrayListOf() }
            if (group.none { it.id == candidateId }) group.add(SearchCandidateSnapshot(candidateId, book, candidate.sourceName))
        }
        val works = grouped.map { (key, values) -> SearchWorkSnapshot(key, values.first().book.title,
            values.first().book.author, values.toList(), values.map { it.book.sourceId }.distinct().size) }
        val sourceSnapshots = states.values.map { SearchSourceSnapshot(it.id, it.name, it.page, it.hasNextPage, it.status, it.failure, it.generation) }
        deliver(SearchUpdate(id, ++revision, phase, works, sourceSnapshots,
            phase != SearchPhase.CANCELLED && sourceSnapshots.any { it.hasNextPage && it.status != SearchSourceStatus.FAILED }))
    }

    private suspend fun deliver(reply: EngineReply) {
        withContext(Dispatchers.Main) { if (active.value) completion(reply) }
    }
}

private fun identity(kind: String, vararg values: String): String = kind + values.joinToString("") { ":${it.length}:$it" }
internal class SearchHttpFailure(status: Int) : Exception("HTTP $status")
