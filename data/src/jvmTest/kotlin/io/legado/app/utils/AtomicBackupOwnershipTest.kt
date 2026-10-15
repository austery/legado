package io.legado.app.utils

import java.nio.file.Files
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class AtomicBackupOwnershipTest {
    @Test fun replacementAndFailurePreserveUnrelatedBackupSibling() {
        val directory = Files.createTempDirectory("legado-backup-ownership-").toFile()
        try {
            val destination = directory.resolve("backup.zip").apply { writeText("old") }
            val sibling = directory.resolve("backup.zip.bak").apply { writeText("user backup") }
            val incoming = directory.resolve("incoming").apply { writeText("new") }
            FileUtilsBase.replaceFileAtomically(incoming, destination)
            assertEquals("new", destination.readText())
            assertEquals("user backup", sibling.readText())
            assertFailsWith<java.io.IOException> {
                FileUtilsBase.replaceFileAtomically(directory.resolve("missing"), destination)
            }
            assertEquals("new", destination.readText())
            assertEquals("user backup", sibling.readText())
        } finally { directory.deleteRecursively() }
    }
}
