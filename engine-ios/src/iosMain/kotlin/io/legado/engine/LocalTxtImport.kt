package io.legado.engine

import io.legado.app.constant.BookType
import io.legado.app.data.AppDatabaseProviders
import io.legado.app.data.dao.NativeLocalTxt
import io.legado.app.data.dao.NativeShelfEntry
import io.legado.app.data.entities.Book
import io.legado.app.model.fileBook.TextFile
import io.legado.app.utils.File
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import okio.Buffer
import okio.FileSystem
import okio.HashingSink
import okio.Path.Companion.toPath
import okio.buffer
import okio.use
import platform.Foundation.NSUUID

/** Called under the engine operation gate. Never refreshes an admitted local book. */
internal object LocalTxtImport {
    const val MAX_BYTES = 10L * 1024 * 1024

    suspend fun import(path: String, filename: String): NativeShelfEntry {
        require(filename.endsWith(".txt", ignoreCase = true)) { "Choose one UTF-8 TXT file" }
        require(filename.isNotBlank() && '/' !in filename && '\\' !in filename) { "Invalid file name" }
        val fs = FileSystem.SYSTEM
        val root = NativeLocalTxt.root().toPath()
        fs.createDirectories(root)
        val staging = root / ("." + NSUUID().UUIDString + ".staging")
        var created: okio.Path? = null
        var createdIdentity: String? = null
        try {
            var count = 0L
            val hashing = HashingSink.sha256(fs.sink(staging))
            hashing.buffer().use { output ->
                fs.source(path.toPath()).buffer().use { input ->
                    val buffer = Buffer()
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val read = input.read(buffer, 8192)
                        if (read == -1L) break
                        count += read
                        require(count <= MAX_BYTES) { "TXT files must be at most 10 MiB" }
                        output.write(buffer, read)
                    }
                }
            }
            require(count > 0) { "The TXT file is empty" }
            val bytes = fs.read(staging) { readByteArray() }
            val text = runCatching { bytes.decodeToString(throwOnInvalidSequence = true) }.getOrNull()
                ?.removePrefix("\uFEFF") ?: throw IllegalArgumentException("The TXT file must use UTF-8 encoding")
            require(text.isNotBlank() && '\u0000' !in text) { "The TXT file has no readable text" }
            val digest = hashing.hash.hex()
            val target = root / digest / "book.txt"
            fs.createDirectories(target.parent!!)
            if (fs.exists(target)) {
                require(fs.metadata(target).size == count && fs.read(target) { readByteString().sha256().hex() } == digest) {
                    "The existing TXT copy has changed; import was not applied"
                }
            } else {
                fs.atomicMove(staging, target)
                created = target
                createdIdentity = NativeLocalTxt.identity(digest)
            }
            val reference = NativeLocalTxt.identity(digest)
            val db = AppDatabaseProviders.get().appDb
            val existing = db.bookDao.getBook(reference)
            if (existing != null) {
                require(NativeLocalTxt.owns(existing)) { "Local identity conflict" }
                return db.nativeShelfDao.admitLocalTxt(existing, emptyList())
            }
            val candidate = Book(bookUrl = reference, origin = reference, originName = filename,
                name = filename.substringBeforeLast('.'), type = BookType.text or BookType.local,
                charset = "UTF-8", latestChapterTime = File(target.toString()).lastModified())
            TextFile.clear()
            val catalog = TextFile.getChapterList(candidate)
            require(catalog.isNotEmpty()) { "The TXT file has no chapters" }
            candidate.totalChapterNum = catalog.size
            candidate.latestChapterTitle = catalog.last().title
            currentCoroutineContext().ensureActive()
            return withContext(NonCancellable) { db.nativeShelfDao.admitLocalTxt(candidate, catalog) }
        } finally {
            withContext(NonCancellable) {
                // A failed database lookup leaves admission uncertain. Preserve the copy.
                try {
                    created?.let { path ->
                        val absent = runCatching {
                            AppDatabaseProviders.get().appDb.bookDao.getBook(requireNotNull(createdIdentity)) == null
                        }.getOrDefault(false)
                        if (absent) runCatching {
                            fs.delete(path, mustExist = false)
                            val parent = requireNotNull(path.parent)
                            if (fs.list(parent).isEmpty()) fs.delete(parent)
                        }
                    }
                } finally {
                    try { runCatching { fs.delete(staging, mustExist = false) } }
                    finally { TextFile.clear() }
                }
            }
        }
    }

    fun verify(book: Book) {
        require(NativeLocalTxt.owns(book)) { "Unrecognized local TXT identity" }
        val path = NativeLocalTxt.path(book).toPath()
        val fs = FileSystem.SYSTEM
        val size = fs.metadata(path).size ?: error("TXT size unavailable")
        require(size in 1..MAX_BYTES && fs.read(path) { readByteString().sha256().hex() } == path.parent!!.name) {
            "The saved TXT file has changed"
        }
    }
}
