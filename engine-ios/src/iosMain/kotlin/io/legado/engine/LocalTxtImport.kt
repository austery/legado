package io.legado.engine

import io.legado.app.constant.BookType
import io.legado.app.data.AppDatabaseProviders
import io.legado.app.data.dao.NativeLocalTxt
import io.legado.app.data.dao.NativeShelfException
import io.legado.app.data.dao.NativeShelfEntry
import io.legado.app.data.entities.Book
import io.legado.app.model.fileBook.TextFile
import io.legado.app.utils.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import okio.Buffer
import okio.FileSystem
import okio.HashingSink
import okio.IOException
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
        local { fs.createDirectories(root) }
        val staging = root / ("." + NSUUID().UUIDString + ".staging")
        var created: okio.Path? = null
        var createdIdentity: String? = null
        try {
            var count = 0L
            val hashing = HashingSink.sha256(local { fs.sink(staging) })
            // Reads of the picked file are classified first; the rest, including the final
            // flush when the staging sink closes, is owned storage.
            local {
                hashing.buffer().use { output ->
                    selected { fs.source(path.toPath()) }.buffer().use { input ->
                        val buffer = Buffer()
                        while (true) {
                            currentCoroutineContext().ensureActive()
                            val read = selected { input.read(buffer, 8192) }
                            if (read == -1L) break
                            count += read
                            require(count <= MAX_BYTES) { "TXT files must be at most 10 MiB" }
                            output.write(buffer, read)
                        }
                    }
                }
            }
            require(count > 0) { "The TXT file is empty" }
            val bytes = local { fs.read(staging) { readByteArray() } }
            val text = runCatching { bytes.decodeToString(throwOnInvalidSequence = true) }.getOrNull()
                ?.removePrefix("\uFEFF") ?: throw IllegalArgumentException("The TXT file must use UTF-8 encoding")
            require(text.isNotBlank() && '\u0000' !in text) { "The TXT file has no readable text" }
            val digest = hashing.hash.hex()
            val target = root / digest / "book.txt"
            local { fs.createDirectories(target.parent!!) }
            if (local { fs.exists(target) }) {
                // Never overwrite an owned copy that no longer matches its digest.
                if (!matches(target, digest, count)) throw CacheUnavailable("The existing TXT copy has changed; import was not applied")
            } else {
                local { fs.atomicMove(staging, target) }
                created = target
                createdIdentity = NativeLocalTxt.identity(digest)
            }
            val reference = NativeLocalTxt.identity(digest)
            val existing = database { AppDatabaseProviders.get().appDb.bookDao.getBook(reference) }
            if (existing != null) {
                require(NativeLocalTxt.owns(existing)) { "Local identity conflict" }
                return database { AppDatabaseProviders.get().appDb.nativeShelfDao.admitLocalTxt(existing, emptyList()) }
            }
            val candidate = Book(bookUrl = reference, origin = reference, originName = filename,
                name = filename.substringBeforeLast('.'), type = BookType.text or BookType.local,
                charset = "UTF-8", latestChapterTime = File(target.toString()).lastModified())
            TextFile.clear()
            // Upstream parsing reads the owned copy and the TOC rule table; its failures here are local storage.
            val catalog = database { TextFile.getChapterList(candidate) }
            require(catalog.isNotEmpty()) { "The TXT file has no chapters" }
            candidate.totalChapterNum = catalog.size
            candidate.latestChapterTitle = catalog.last().title
            currentCoroutineContext().ensureActive()
            return withContext(NonCancellable) {
                database { AppDatabaseProviders.get().appDb.nativeShelfDao.admitLocalTxt(candidate, catalog) }
            }
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

    /** A missing, unreadable or changed owned copy is unavailable local content, never a network failure. */
    fun verify(book: Book) {
        require(NativeLocalTxt.owns(book)) { "Unrecognized local TXT identity" }
        val path = NativeLocalTxt.path(book).toPath()
        if (!matches(path, path.parent!!.name, null)) throw CacheUnavailable("The saved TXT file is missing or has changed")
    }

    private fun matches(path: okio.Path, digest: String, expectedSize: Long?): Boolean = try {
        val fs = FileSystem.SYSTEM
        val size = fs.metadata(path).size
        size != null && size in 1..MAX_BYTES && (expectedSize == null || size == expectedSize) &&
            fs.read(path) { readByteString().sha256().hex() } == digest
    } catch (_: IOException) { false }

    /** Owned staging/copy I/O. */
    private inline fun <T> local(action: () -> T): T = try { action() }
        catch (error: IOException) { throw ShelfStorageFailure(error.message ?: "Local TXT storage failed", error) }

    /** The picked file: unreadable input is the user's choice to retry, not a network failure. */
    private inline fun <T> selected(action: () -> T): T = try { action() }
        catch (error: IOException) { throw IllegalArgumentException("The selected file cannot be read", error) }

    /** Shelf database and local parsing; typed failures and input checks keep their own classification. */
    private inline fun <T> database(action: () -> T): T = try { action() }
        catch (error: CancellationException) { throw error }
        catch (error: NativeShelfException) { throw error }
        catch (error: IllegalArgumentException) { throw error }
        catch (error: CacheUnavailable) { throw error }
        // An upstream TOC rule timing out on the file's content is a rule failure, not storage.
        catch (error: io.legado.app.exception.RegexTimeoutException) { throw error }
        catch (error: Exception) { throw ShelfStorageFailure(error.message ?: "Shelf storage failed", error) }
}
