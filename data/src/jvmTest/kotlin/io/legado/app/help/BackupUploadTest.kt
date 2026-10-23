package io.legado.app.help

import io.legado.app.lib.webdav.Authorization
import kotlinx.coroutines.runBlocking
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertSame

class BackupUploadTest {
    @Test fun networkLossAfterPreflightFailsInsteadOfSkippingUpload() = runBlocking {
        var available = true
        check(available) // The caller's earlier preflight passed.
        available = false // Export/compression finished after connectivity disappeared.
        var uploads = 0
        assertFailsWith<Exception> {
            AppWebDavShared.uploadBackupArchive({ available }, { Authorization("test", "fixture") }) { uploads++ }
        }
        assertEquals(0, uploads)
    }

    @Test fun clearedAuthorizationFailsInsteadOfSkippingUpload() = runBlocking {
        var uploads = 0
        assertFailsWith<Exception> {
            AppWebDavShared.uploadBackupArchive({ true }, { null }) { uploads++ }
        }
        assertEquals(0, uploads)
    }

    @Test fun transportFailurePropagatesAndSuccessRequiresUpload() = runBlocking {
        val auth = Authorization("test", "fixture")
        val failure = IllegalStateException("Fixture transport failure")
        val actual = assertFailsWith<IllegalStateException> {
            AppWebDavShared.uploadBackupArchive({ true }, { auth }) { throw failure }
        }
        assertSame(failure, actual)
        var uploads = 0
        AppWebDavShared.uploadBackupArchive({ true }, { auth }) { received ->
            assertSame(auth, received)
            uploads++
        }
        assertEquals(1, uploads)
    }
}
