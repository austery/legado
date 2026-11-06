package io.legado.engine

import io.legado.app.data.dao.NativeBodyCoordinates
import io.legado.app.data.dao.NativeShelfEntry
import io.legado.app.help.book.BookStorageProviders
import io.legado.app.ui.book.searchContent.LiteralTextSearch
import kotlinx.atomicfu.atomic
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.withLock

class CachedChapterHit internal constructor(
    val sourceId: String, val bookId: String, val chapterId: String, val chapterIndex: Int,
    val chapterTitle: String, val query: String, val utf16Offset: Int, val utf16Length: Int,
    val textVersion: String, val textSha256: String, val textUtf16Length: Int,
    val excerpt: String, internal val owner: String, internal val generation: Long
)
class CachedChapterResults internal constructor(val hits: List<CachedChapterHit>,
    val examinedChapters: Int, val cachedChapters: Int, val totalChapters: Int,
    val truncated: Boolean) : EngineReply()

/** No network or persistence. Cache ownership uses the same authority as offline controls. */
internal class CachedChapterSearch(private val owner: String,
    private val entry: suspend (String, String) -> NativeShelfEntry) {
    private val generation = atomic(0L)

    suspend fun search(source: String, book: String, query: String): CachedChapterResults {
        require(query.isNotBlank()) { "Enter search text" }
        val stamp = generation.incrementAndGet()
        val snapshot = EngineHost.gate.withLock { entry(source, book) }
        val chapters = snapshot.chapters.filterNot { it.isVolume }
        val hits = mutableListOf<CachedChapterHit>()
        var examined = 0
        var cached = 0
        for (chapter in chapters) {
            currentCoroutineContext().ensureActive()
            val body = EngineHost.gate.withLock {
                BookStorageProviders.get().getContent(snapshot.book, chapter)
            }
            examined++
            if (body.isNullOrEmpty()) continue
            cached++
            val positions = LiteralTextSearch.positions(body, query, 201 - hits.size)
            if (positions.isNotEmpty()) {
                val hash = NativeBodyCoordinates.sha256(body)
                for (offset in positions) {
                    hits += CachedChapterHit(source, book, chapter.url, chapter.index, chapter.title,
                        query, offset, query.length, NativeBodyCoordinates.VERSION, hash, body.length,
                        excerpt(body, offset, query.length), owner, stamp)
                }
            }
            if (hits.size > 200) break
        }
        EngineHost.gate.withLock {
            val current = entry(source, book)
            check(current.chapters.map { it.url to it.index } == snapshot.chapters.map { it.url to it.index }) {
                "Catalog changed. Search again."
            }
            check(generation.value == stamp) { "Search was replaced" }
        }
        return CachedChapterResults(hits.take(200), examined, cached, chapters.size, hits.size > 200)
    }

    suspend fun verify(hit: CachedChapterHit): NativeShelfEntry {
        require(hit.owner == owner && hit.generation == generation.value) { "Search expired. Search again." }
        val current = entry(hit.sourceId, hit.bookId)
        val chapter = current.chapters.singleOrNull {
            !it.isVolume && it.url == hit.chapterId && it.index == hit.chapterIndex
        } ?: error("Chapter changed. Search again.")
        val body = BookStorageProviders.get().getContent(current.book, chapter)
        check(body != null && matches(hit, body)) { "Cached text changed or is missing. Search again." }
        return current
    }

    fun matches(hit: CachedChapterHit, body: String): Boolean =
        hit.textVersion == NativeBodyCoordinates.VERSION && body.length == hit.textUtf16Length &&
            NativeBodyCoordinates.sha256(body) == hit.textSha256 && hit.utf16Offset >= 0 &&
            hit.utf16Length > 0 && hit.utf16Offset <= body.length - hit.utf16Length &&
            body.substring(hit.utf16Offset, hit.utf16Offset + hit.utf16Length) == hit.query

    private fun excerpt(body: String, offset: Int, length: Int): String {
        var start = (offset - 20).coerceAtLeast(0)
        var end = (offset + length + 20).coerceAtMost(body.length)
        if (start > 0 && body[start].isLowSurrogate() && body[start - 1].isHighSurrogate()) start--
        if (end < body.length && end > 0 && body[end - 1].isHighSurrogate() && body[end].isLowSurrogate()) end++
        return body.substring(start, end)
    }
}
