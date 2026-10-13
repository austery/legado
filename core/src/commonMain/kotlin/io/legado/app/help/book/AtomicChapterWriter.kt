package io.legado.app.help.book

import io.legado.app.utils.randomUUIDString
import okio.ByteString.Companion.encodeUtf8
import okio.FileSystem
import okio.IOException
import okio.Path
import okio.buffer
import okio.use

/** Checked replacement at the existing cache path; does not coordinate database commits. */
internal class AtomicChapterWriter(private val fileSystem: FileSystem = FileSystem.SYSTEM) {
    fun write(destination: Path, body: String) {
        val parent = destination.parent ?: throw IOException("Chapter destination has no parent")
        fileSystem.createDirectories(parent)
        val staging = parent / (destination.name + ".staging-" + randomUUIDString())
        val expected = body.encodeUtf8()
        var ownsStaging = false
        try {
            val sink = fileSystem.sink(staging, mustCreate = true)
            ownsStaging = true
            sink.buffer().use { it.write(expected) }
            if (fileSystem.read(staging) { readByteString() } != expected) {
                throw IOException("Staged chapter bytes do not match the body")
            }
            // No delete/copy fallback: unsupported or failed replacement must remain a failure.
            fileSystem.atomicMove(staging, destination)
            ownsStaging = false
            if (fileSystem.read(destination) { readByteString() } != expected) {
                throw IOException("Replaced chapter bytes could not be verified")
            }
        } finally {
            if (ownsStaging) runCatching { fileSystem.delete(staging, mustExist = false) }
        }
    }
}
