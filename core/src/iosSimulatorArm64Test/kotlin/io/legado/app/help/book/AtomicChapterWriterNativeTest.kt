package io.legado.app.help.book

import io.legado.app.utils.randomUUIDString
import okio.FileSystem
import okio.Path
import okio.ByteString.Companion.encodeUtf8
import kotlin.test.Test
import okio.Buffer
import okio.ForwardingFileSystem
import okio.IOException
import okio.Sink
import okio.Source
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlin.test.assertEquals

class AtomicChapterWriterNativeTest {
    @Test
    fun replacesExistingChapterWithExactUtf8AndNoStagingFiles() {
        val directory = FileSystem.SYSTEM_TEMPORARY_DIRECTORY / ("PROTOTYPE-chapter-" + randomUUIDString())
        FileSystem.SYSTEM.createDirectories(directory)
        val destination = directory / "chapter.nb"
        FileSystem.SYSTEM.write(destination) { writeUtf8("old body") }
        val body = "中文\r\n🌿 e\u0301 👩‍💻\n"
        AtomicChapterWriter().write(destination, body)
        assertEquals(body.encodeUtf8(), FileSystem.SYSTEM.read(destination) { readByteString() })
        assertEquals(listOf(destination), FileSystem.SYSTEM.list(directory))
    }

    private enum class Fault { WRITE, CLOSE, VERIFY_STAGE, MOVE, VERIFY_FINAL, CLEANUP }
    private class FaultFileSystem(val destination: Path, val fault: Fault) : ForwardingFileSystem(FileSystem.SYSTEM) {
        override fun sink(file: Path, mustCreate: Boolean): Sink {
            val delegate = super.sink(file, mustCreate)
            return object : Sink by delegate {
                override fun write(source: Buffer, byteCount: Long) {
                    if (fault == Fault.WRITE || fault == Fault.CLEANUP) {
                        delegate.write(source, minOf(3,byteCount))
                        throw IOException("synthetic partial write")
                    }
                    delegate.write(source,byteCount)
                }
                override fun close() {
                    delegate.close()
                    if (fault == Fault.CLOSE) throw IOException("synthetic close failure")
                }
            }
        }
        override fun source(file: Path): Source {
            if ((fault == Fault.VERIFY_STAGE && file != destination) ||
                (fault == Fault.VERIFY_FINAL && file == destination)) return Buffer().writeUtf8("corrupt readback")
            return super.source(file)
        }
        override fun atomicMove(source: Path, target: Path) {
            assertEquals("old body",FileSystem.SYSTEM.read(destination) { readUtf8() })
            if (fault == Fault.MOVE) throw IOException("synthetic move failure")
            super.atomicMove(source,target)
        }
        override fun delete(path: Path, mustExist: Boolean) {
            if (fault == Fault.CLEANUP) throw IOException("synthetic cleanup failure")
            super.delete(path,mustExist)
        }
    }

    @Test
    fun preReplacementFailuresPreserveExistingBytesAndOnlyCleanOwnedStaging() {
        for (fault in listOf(Fault.WRITE,Fault.CLOSE,Fault.VERIFY_STAGE,Fault.MOVE)) {
            val directory = FileSystem.SYSTEM_TEMPORARY_DIRECTORY / ("PROTOTYPE-chapter-" + randomUUIDString())
            FileSystem.SYSTEM.createDirectories(directory)
            val destination = directory / "chapter.nb"
            val unrelated = directory / "other-operation.staging"
            FileSystem.SYSTEM.write(destination) { writeUtf8("old body") }
            FileSystem.SYSTEM.write(unrelated) { writeUtf8("unrelated") }
            assertFailsWith<IOException> { AtomicChapterWriter(FaultFileSystem(destination,fault)).write(destination,"replacement") }
            assertEquals("old body",FileSystem.SYSTEM.read(destination) { readUtf8() })
            assertEquals("unrelated",FileSystem.SYSTEM.read(unrelated) { readUtf8() })
            assertEquals(setOf(destination,unrelated),FileSystem.SYSTEM.list(directory).toSet())
        }
    }

    @Test
    fun postReplacementVerificationFailureReportsFailureWithoutPretendingOldBytesSurvive() {
        val directory = FileSystem.SYSTEM_TEMPORARY_DIRECTORY / ("PROTOTYPE-chapter-" + randomUUIDString())
        FileSystem.SYSTEM.createDirectories(directory)
        val destination = directory / "chapter.nb"
        FileSystem.SYSTEM.write(destination) { writeUtf8("old body") }
        assertFailsWith<IOException> { AtomicChapterWriter(FaultFileSystem(destination,Fault.VERIFY_FINAL)).write(destination,"complete replacement") }
        assertEquals("complete replacement",FileSystem.SYSTEM.read(destination) { readUtf8() })
        assertEquals(listOf(destination),FileSystem.SYSTEM.list(directory))
    }

    @Test
    fun failedCleanupDoesNotMaskWriteFailureOrDeleteOtherFiles() {
        val directory = FileSystem.SYSTEM_TEMPORARY_DIRECTORY / ("PROTOTYPE-chapter-" + randomUUIDString())
        FileSystem.SYSTEM.createDirectories(directory)
        val destination = directory / "chapter.nb"
        FileSystem.SYSTEM.write(destination) { writeUtf8("old body") }
        val failure = assertFailsWith<IOException> { AtomicChapterWriter(FaultFileSystem(destination,Fault.CLEANUP)).write(destination,"replacement") }
        assertEquals("synthetic partial write",failure.message)
        assertEquals("old body",FileSystem.SYSTEM.read(destination) { readUtf8() })
        assertEquals(2,FileSystem.SYSTEM.list(directory).size)
    }

    @Test
    fun simultaneousWritersPublishWholeBodiesWithoutSharedStaging() = runBlocking {
        val directory = FileSystem.SYSTEM_TEMPORARY_DIRECTORY / ("PROTOTYPE-chapter-" + randomUUIDString())
        FileSystem.SYSTEM.createDirectories(directory)
        val destination = directory / "chapter.nb"
        val bodies = (0..7).map { "body-$it 中文🌿".repeat(1000) }
        bodies.map { body -> async(Dispatchers.Default) {
            try { AtomicChapterWriter().write(destination,body) }
            catch (error: IOException) {
                // Another complete replacement may win before this writer's final verification.
                assertEquals("Replaced chapter bytes could not be verified",error.message)
            }
        } }.awaitAll()
        assertTrue(FileSystem.SYSTEM.read(destination) { readUtf8() } in bodies)
        assertEquals(listOf(destination),FileSystem.SYSTEM.list(directory))
    }
}
