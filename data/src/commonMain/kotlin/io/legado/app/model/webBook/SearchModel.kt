package io.legado.app.model.webBook

import io.legado.app.constant.AppConst
import io.legado.app.constant.AppConst.timeLimit
import io.legado.app.constant.AppLog
import io.legado.app.data.entities.BookListPage
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.SearchBook
import io.legado.app.exception.NoStackTraceException
import io.legado.app.help.book.releaseHtmlData
import io.legado.app.help.config.AppConfigProviders
import io.legado.app.help.coroutine.IoDispatcher
import io.legado.app.help.source.SearchBookFilter
import io.legado.app.model.analyzeRule.AnalyzeUrlCore
import io.legado.app.ui.book.search.SearchScope
import io.legado.app.utils.concurrent.newConcurrentMap
import io.legado.app.utils.concurrent.newConcurrentSet
import io.legado.app.utils.mapParallelSafe
import kotlinx.atomicfu.atomic
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.onCompletion
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.isActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import kotlin.math.min

/**
 * 按源分组的搜索结果 (搜索界面"按源分类"布局用): 一个书源一个组,
 * 组内为该源已搜到的全部书目, 组顺序 = 源完成顺序。
 */
data class SourceSearchGroup(
    val source: BookSource,
    val books: List<SearchBook>,
    val generation: Int = 0,
)

/** 单源单页结果: 带发出请求时的结果世代, 供丢弃重搜前发出的过期响应。 */
private data class SourcePageResult(
    val source: BookSource,
    val generation: Int,
    val sessionVersion: Long,
    val pageNumber: Int,
    val page: BookListPage,
)

/** The accepted outcome of one source page, before safe-flow error suppression. */
sealed interface SourcePageOutcome {
    data class Success(val hasNextPage: Boolean, val isEmpty: Boolean) : SourcePageOutcome
    data class Failure(val error: Throwable) : SourcePageOutcome
    data object Cancelled : SourcePageOutcome
}

/** searchLayout (AppConfig) 的"按源分类"布局标志位; 低 3 位列数 / bit4 视频位仅聚簇布局使用。 */
const val SEARCH_LAYOUT_SOURCE_GROUP = 0x20

/**
 * 搜索编排层。
 *
 * 下沉说明:
 * - `AppConfig.threadCount/precisionSearch` → `AppConfigProviders.get().threadCount/precisionSearch`;
 * - `Executors.newFixedThreadPool(N).asCoroutineDispatcher()` (JVM 专属) →
 *   `Dispatchers.IO.limitedParallelism(N)` (KMP commonMain 可用), 行为等价 (限制并发到 N);
 * - `Coroutine.async` (app 端 WebBook 调试用) 未使用, 无需替换;
 * - 其他依赖 (WebBook/SearchBookFilter/SearchScope/releaseHtmlData/mapParallelSafe 等) 均已下沉。
 */
class SearchModel(
    private val scope: CoroutineScope,
    private val callBack: CallBack,
    private val sourceResolver: suspend () -> List<BookSource> = { callBack.getSearchScope().getBookSources() },
    private val pageExecutor: suspend (BookSource, Int, suspend () -> BookListPage) -> BookListPage =
        { _, _, action -> action() },
) {
    val threadCount = AppConfigProviders.get().threadCount
    private val pagePermits = Semaphore(min(threadCount, AppConst.MAX_THREAD).coerceAtLeast(1))
    private val sessionVersion = atomic(0L)
    private val sourceLocks = newConcurrentMap<String, Mutex>()
    private val failedSources = newConcurrentSet<String>()
    private val ownedJobs = newConcurrentSet<Job>()
    private val searchGroupGenerations = HashMap<String, Int>()
    private var searchPool: kotlinx.coroutines.CoroutineDispatcher? = null
    private var mSearchId = 0L
    private var searchKey: String = ""
    private var bookSources = emptyList<BookSource>()
    private var searchBooks = arrayListOf<SearchBook>()

    /**
     * 按源分组的原始结果 (key=sourceUrl): 聚合列表 [searchBooks] 之外并行维护,
     * 同一批 SearchBook 对象引用, 无复制开销。
     */
    private val searchGroupBooks = LinkedHashMap<String, MutableList<SearchBook>>()
    private val searchGroupSources = HashMap<String, BookSource>()

    /**
     * 源出现顺序 (只增不删, 重搜不清): 分组快照按此序输出, 重搜回填后区块不跳位。
     * 仅 [resultMutex] 内访问。
     */
    private val sourceOrder = ArrayList<String>()

    private var searchJob: Job? = null
    private var workingState = MutableStateFlow(true)

    /** 单源重搜任务 (key=sourceUrl): 只取消同源旧任务, 不牵连其他源正在进行的重搜 */
    private val restartJobs = newConcurrentMap<String, Job>()

    /** 每源结果世代 (重搜 +1): 请求记下发出时的世代, 世代已变的响应 (重搜前发出的旧页) 丢弃 */
    private val resultGenerations = newConcurrentMap<String, Int>()
    private val resultMutex = Mutex()

    /** 每源下一页页码 (重搜后该源回到第 2 页; 新搜索清空) */
    private val nextPages = newConcurrentMap<String, Int>()

    /** 本轮精准开关 (startSearch 时快照, 单源重搜沿用同一值) */
    private var precision = false

    /** 本轮“任一源还有下一页” (主链与单源重搜共同维护) */
    private val sourceHasMore = newConcurrentMap<String, Boolean>()
    private val hasMore: Boolean get() = sourceHasMore.values.any { it }

    /** 已声明没有下一页的源 url，翻页时直接跳过，避免多发空请求 (主链与单源重搜并发访问) */
    private val exhaustedSources = newConcurrentSet<String>()

    /** 本轮是否只有一个源 (聚簇布局顶部选项行据此决定是否展示)。 */
    val isSingleSource: Boolean get() = bookSources.size == 1

    private fun initSearchPool(): kotlinx.coroutines.CoroutineDispatcher {
        // 用 limitedParallelism 替代原 Executors.newFixedThreadPool(N).asCoroutineDispatcher()
        // 行为等价: 限制并发到 N, 复用 Dispatchers.IO 线程池, 无需手动 close
        return IoDispatcher.limitedParallelism(min(threadCount, AppConst.MAX_THREAD).coerceAtLeast(1))
    }

    suspend fun search(searchId: Long, key: String) {
        if (searchId != mSearchId) {
            if (key.isEmpty()) return
            closeAndJoin()
            searchKey = key
            searchBooks.clear()
            searchGroupBooks.clear()
            searchGroupSources.clear()
            searchGroupGenerations.clear()
            sourceOrder.clear()
            resultGenerations.clear()
            exhaustedSources.clear()
            failedSources.clear()
            sourceHasMore.clear()
            nextPages.clear()
            sourceLocks.clear()
            workingState.value = true
            val version = sessionVersion.value
            val resolvedSources = sourceResolver().distinctBy { it.bookSourceUrl }
            currentCoroutineContext().ensureActive()
            if (version != sessionVersion.value) return
            bookSources = resolvedSources
            bookSources.forEach { sourceLocks[it.bookSourceUrl] = Mutex() }
            callBack.onSearchSourcesResolved(bookSources)
            if (bookSources.isEmpty()) {
                callBack.onSearchCancel(NoStackTraceException("启用书源为空"))
                return
            }
            mSearchId = searchId
            searchPool = initSearchPool()
        } else {
            searchJob?.join()
        }
        startSearch()
    }

    /** Native pagination does not silently retry a failed source. */
    suspend fun loadMore() {
        searchJob?.join()
        startSearch(skipFailed = true)
    }

    private fun startSearch(skipFailed: Boolean = false) {
        if (mSearchId == 0L || searchJob?.isActive == true) return
        precision = AppConfigProviders.get().precisionSearch
        val pool = searchPool ?: return
        val version = sessionVersion.value
        // Snapshot every generation before flow backpressure can delay a source.
        val scheduledSources = bookSources.map { it to generationOf(it.bookSourceUrl) }
        val job = scope.launch(pool, start = CoroutineStart.LAZY) {
            flow {
                scheduledSources.forEach { (source, generation) ->
                    workingState.first { it }
                    val url = source.bookSourceUrl
                    if (url !in exhaustedSources && (!skipFailed || url !in failedSources)) {
                        emit(source to generation)
                    }
                }
            }.onStart {
                if (version == sessionVersion.value) callBack.onSearchStart()
            }.mapParallelSafe(min(threadCount, AppConst.MAX_THREAD).coerceAtLeast(1), bookSources.size) { (source, generation) ->
                executeSourcePage(source, generation, version)
            }.onCompletion {
                if (it == null && version == sessionVersion.value) {
                    resultMutex.withLock {
                        if (version == sessionVersion.value) callBack.onSearchFinish(searchBooks.isEmpty(), hasMore)
                    }
                }
            }.catch {
                if (version == sessionVersion.value && currentCoroutineContext().isActive) {
                    AppLog.put("书源搜索出错\n${it.message}", it)
                    callBack.onSearchCancel(it)
                }
            }.collect()
        }
        searchJob = track(job)
        job.start()
    }

    private fun track(job: Job): Job {
        ownedJobs.add(job)
        job.invokeOnCompletion { ownedJobs.remove(job) }
        return job
    }

    private fun isCurrent(sourceUrl: String, generation: Int, version: Long): Boolean =
        version == sessionVersion.value && mSearchId != 0L && generation == generationOf(sourceUrl)

    /** A source owns its page until acceptance; other sources still run concurrently. */
    private suspend fun executeSourcePage(source: BookSource, generation: Int, version: Long) {
        val sourceUrl = source.bookSourceUrl
        val lease = sourceLocks[sourceUrl] ?: return
        lease.withLock {
            if (!isCurrent(sourceUrl, generation, version)) return
            pagePermits.withPermit {
                workingState.first { it }
                if (!isCurrent(sourceUrl, generation, version)) return
                val pageNumber = nextPages[sourceUrl] ?: 1
                callBack.onSourcePageStarted(sourceUrl, generation, pageNumber)
                try {
                    val page = withTimeout(timeLimit) {
                        pageExecutor(source, pageNumber) {
                            WebBook.getBookListAwait(
                                source, searchKey, pageNumber,
                                filter = { name, author ->
                                    !precision || name.contains(searchKey) || author.contains(searchKey)
                                },
                                onUrlResolved = { analyzeUrl: AnalyzeUrlCore ->
                                    val options = parseExploreOptionsFromUrl(analyzeUrl.ruleUrl)
                                    if (options.isNotEmpty() && isCurrent(sourceUrl, generation, version)) {
                                        callBack.onSearchOptionsResolved(sourceUrl, options)
                                    }
                                },
                                selectedOptions = sourceSelectedOptions(sourceUrl),
                                pluginFilters = callBack.getPluginFilters(source),
                            )
                        }
                    }
                    handlePageResult(SourcePageResult(source, generation, version, pageNumber, page))
                } catch (error: Throwable) {
                    if (isCurrent(sourceUrl, generation, version)) {
                        val outcome = if (currentCoroutineContext().isActive) {
                            failedSources.add(sourceUrl)
                            sourceHasMore[sourceUrl] = false
                            SourcePageOutcome.Failure(error)
                        } else SourcePageOutcome.Cancelled
                        callBack.onSourcePageFinished(sourceUrl, generation, pageNumber, outcome)
                    }
                    currentCoroutineContext().ensureActive()
                    throw error
                }
            }
        }
    }

    /** 每源请求前实时取该源已选值 (按源隔离, 供 AnalyzeUrlCore 替换 `<name(...)>` 段)。 */
    private fun sourceSelectedOptions(sourceUrl: String): Map<String, String> =
        callBack.getSearchOptions(sourceUrl).associate { it.name to it.resolvedValue }

    /** 该源当前结果世代 (未重搜过 = 0)。 */
    private fun generationOf(sourceUrl: String): Int = resultGenerations[sourceUrl] ?: 0

    /**
     * 单页结果统一处理 (主链与单源重搜共用): 丢弃过期世代 → 过滤/release/exhausted/hasMore/
     * 入组/重建聚合/回调。单源重搜协程与主链并发到达, 共享结构访问经 [resultMutex] 互斥。
     */
    private suspend fun handlePageResult(result: SourcePageResult) {
        val source = result.source
        val url = source.bookSourceUrl
        if (!isCurrent(url, result.generation, result.sessionVersion)) return
        val (items, filteredCount) = SearchBookFilter.apply(result.page.books)
        if (filteredCount > 0 && isCurrent(url, result.generation, result.sessionVersion)) {
            callBack.onFiltered(filteredCount)
        }
        for (book in items) book.releaseHtmlData()
        resultMutex.withLock {
            if (!isCurrent(url, result.generation, result.sessionVersion)) return
            currentCoroutineContext().ensureActive()
            nextPages[url] = result.pageNumber + 1
            failedSources.remove(url)
            sourceHasMore[url] = result.page.hasNextPage
            if (result.page.hasNextPage) exhaustedSources.remove(url) else exhaustedSources.add(url)
            mergeGroup(source, items)
            if (searchGroupBooks.containsKey(url)) searchGroupGenerations[url] = result.generation
            rebuildAggregate(precision)
            callBack.onSearchSuccess(searchBooks)
            callBack.onSearchGroupsChanged(groupSnapshot())
            callBack.onSourcePageFinished(url, result.generation, result.pageNumber,
                SourcePageOutcome.Success(result.page.hasNextPage, items.isEmpty()))
        }
    }

    /**
     * 单源重搜: 丢弃该源旧结果与在飞旧请求, 只重发该源第 1 页 (沿用当前关键词与该源最新筛选会话),
     * 其余源的结果与在飞请求不受影响 (任务按源隔离)。
     *
     * 不要求主链仍在搜索: 用户停止搜索后结果仍展示、区块内筛选/参数入口仍可用, 此时改动该源
     * 也要能生效 (主链停止时不再发 onSearchFinish, 免得重弹空结果弹窗)。
     */
    fun restartSource(sourceUrl: String) {
        startSource(sourceUrl, reset = true)
    }

    /** Retry the failed page while retaining every accepted earlier page. */
    fun retrySource(sourceUrl: String) {
        startSource(sourceUrl, reset = false)
    }

    private fun startSource(sourceUrl: String, reset: Boolean) {
        if (searchKey.isEmpty() || mSearchId == 0L) return
        val source = bookSources.firstOrNull { it.bookSourceUrl == sourceUrl } ?: return
        val version = sessionVersion.value
        val generation = generationOf(sourceUrl) + 1
        resultGenerations[sourceUrl] = generation
        restartJobs[sourceUrl]?.cancel()
        val restartJob = scope.launch(searchPool ?: initSearchPool(), start = CoroutineStart.LAZY) {
            try {
                workingState.first { it }
                resultMutex.withLock {
                    if (!isCurrent(sourceUrl, generation, version)) return@launch
                    if (reset) {
                        searchGroupBooks.remove(sourceUrl)
                        searchGroupGenerations.remove(sourceUrl)
                        nextPages[sourceUrl] = 1
                    }
                    exhaustedSources.remove(sourceUrl)
                    failedSources.remove(sourceUrl)
                    sourceHasMore[sourceUrl] = false
                    rebuildAggregate(precision)
                    callBack.onSearchSuccess(searchBooks)
                    callBack.onSearchGroupsChanged(groupSnapshot())
                }
                executeSourcePage(source, generation, version)
                if (isCurrent(sourceUrl, generation, version) && searchJob?.isActive != true) {
                    resultMutex.withLock {
                        if (isCurrent(sourceUrl, generation, version)) {
                            callBack.onSearchFinish(searchBooks.isEmpty(), hasMore)
                        }
                    }
                }
            } catch (error: Throwable) {
                if (isCurrent(sourceUrl, generation, version) && currentCoroutineContext().isActive) {
                    AppLog.put("书源搜索出错\n${error.message}", error)
                    callBack.onSearchCancel(error)
                }
            } finally {
                if (restartJobs[sourceUrl] === currentCoroutineContext()[Job]) restartJobs.remove(sourceUrl)
            }
        }
        restartJobs[sourceUrl] = track(restartJob)
        restartJob.start()
    }

    /**
     * 从按源分组数据全量重建聚合列表 (聚合是分组的纯派生视图, 单源变更后重建即自动一致):
     * 分级/聚合/排序语义与原增量版逐字一致 —— (name,author) 同书聚合 origins、
     * equal 组按 origins 数降序、contains 组次之、other 组仅非精准时追加;
     * 组序=源完成序、组内按到达序, 遍历序即原增量维护下的全局到达序, 输出顺序不变。
     */
    private fun rebuildAggregate(precision: Boolean) {
        val equalData = arrayListOf<SearchBook>()
        val containsData = arrayListOf<SearchBook>()
        val otherData = arrayListOf<SearchBook>()
        val equalIndex = HashMap<Pair<String, String>, SearchBook>()
        val containsIndex = HashMap<Pair<String, String>, SearchBook>()
        val otherIndex = HashMap<Pair<String, String>, SearchBook>()
        fun addOrMerge(
            books: MutableList<SearchBook>,
            index: MutableMap<Pair<String, String>, SearchBook>,
            book: SearchBook,
        ) {
            val key = book.name to book.author
            val existing = index[key]
            if (existing == null) {
                books.add(book)
                index[key] = book
            } else {
                existing.addOrigin(book.origin)
            }
        }
        for (books in searchGroupBooks.values) {
            for (book in books) {
                if ((book.name == searchKey) || (book.author == searchKey)) {
                    addOrMerge(equalData, equalIndex, book)
                } else if (book.name.contains(searchKey) || book.author.contains(searchKey)) {
                    addOrMerge(containsData, containsIndex, book)
                } else if (!precision) {
                    // 精准模式下 other 书与原增量版一致: 不合并 origins, 整组丢弃
                    addOrMerge(otherData, otherIndex, book)
                }
            }
        }
        equalData.sortByDescending { it.origins.size }
        equalData.addAll(containsData.sortedByDescending { it.origins.size })
        if (!precision) {
            equalData.addAll(otherData)
        }
        searchBooks = equalData
    }

    /**
     * 新源首次出现按完成顺序入组, 翻页追加到已有组尾; 零结果源不入组 (与聚簇列表只显有书的语义一致)。
     *
     * 按 bookUrl 去重: 劣质源翻页会重复返回上一页的书, 不去重分组横向行会出现重复封面卡。
     */
    private fun mergeGroup(source: BookSource, items: List<SearchBook>) {
        if (items.isEmpty()) return
        val url = source.bookSourceUrl
        if (url !in searchGroupSources) sourceOrder.add(url)
        val group = searchGroupBooks.getOrPut(url) { arrayListOf() }
        val seen = group.mapTo(HashSet()) { it.bookUrl }
        items.forEach {
            if (seen.add(it.bookUrl)) group.add(it)
        }
        searchGroupSources[url] = source
    }

    /**
     * 组顺序 = 源首次出现顺序 ([sourceOrder] 只增不减); 发射快照, UI 不持有内部可变结构。
     * 重搜期间该书分组为空 (不入快照), 回填后按原位置回来。
     */
    private fun groupSnapshot(): List<SourceSearchGroup> =
        sourceOrder.mapNotNull { url ->
            val books = searchGroupBooks[url] ?: return@mapNotNull null
            if (books.isEmpty()) return@mapNotNull null
            SourceSearchGroup(
                searchGroupSources.getValue(url),
                books.toList(),
                generation = searchGroupGenerations.getValue(url),
            )
        }

    fun pause() {
        workingState.value = false
    }

    fun resume() {
        workingState.value = true
    }

    fun cancelSearch() {
        close()
        callBack.onSearchCancel()
    }

    fun close() {
        sessionVersion.incrementAndGet()
        mSearchId = 0L
        ownedJobs.toList().forEach { it.cancel() }
        searchPool = null
    }

    /** Await retirement outside resultMutex, including replaced source restart work. */
    suspend fun closeAndJoin() {
        val jobs = ownedJobs.toList()
        close()
        jobs.forEach { it.join() }
        searchJob = null
        restartJobs.clear()
    }

    interface CallBack {
        fun getSearchScope(): SearchScope
        fun onSourcePageStarted(sourceId: String, generation: Int, page: Int) {}
        fun onSourcePageFinished(sourceId: String, generation: Int, page: Int, outcome: SourcePageOutcome) {}
        fun onSearchStart()
        fun onSearchSuccess(searchBooks: List<SearchBook>)

        /** 按源分组结果更新 (每源每页完成后全量发射; 默认空实现: Web API 等仅关心聚合列表的实现方不受影响) */
        fun onSearchGroupsChanged(groups: List<SourceSearchGroup>) {}
        fun onSearchFinish(isEmpty: Boolean, hasMore: Boolean)
        fun onSearchCancel(exception: Throwable? = null)

        /** 某源搜索 URL 声明的可选项解析完成 (每源每页都会回调, 同结构重复回调由实现方去重) */
        fun onSearchOptionsResolved(sourceUrl: String, options: List<ExploreOption>) {}

        /** 取某源已声明选项的当前选择态 (默认空: 不支持选项注入的实现方) */
        fun getSearchOptions(sourceUrl: String): List<ExploreOption> = emptyList()

        /**
         * 取该源页面会话筛选实例 (默认 null: 无筛选 UI 的调用方, 委派按源默认筛选取数)。
         * 实现方持有实例并在会话内复用, 使筛选 UI 与取数共用同一份; 不经全局缓存。
         */
        suspend fun getPluginFilters(source: BookSource): PluginFilterSession? = null

        /** 本轮搜索源列表就绪 (在 [search] 里与 [bookSources] 同时赋值)。 */
        fun onSearchSourcesResolved(sources: List<BookSource>) {}

        fun onFiltered(count: Int) {}
    }

}
