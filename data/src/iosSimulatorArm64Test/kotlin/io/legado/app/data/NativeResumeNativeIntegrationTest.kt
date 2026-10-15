package io.legado.app.data

import io.legado.app.constant.BookType
import androidx.room3.Room
import androidx.sqlite.driver.NativeSQLiteDriver
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSUUID
import kotlin.test.*
import androidx.sqlite.execSQL
import io.legado.app.data.dao.NativeChapterProjection
import io.legado.app.data.dao.NativeBodyCoordinates
import io.legado.app.data.dao.NativeResumeException
import io.legado.app.data.dao.NativeResumeFailure
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeout

class NativeResumeNativeIntegrationTest {
    @Test
    fun saveNormalizesParagraphAndAtomicallyProjectsChapter() = runBlocking {
        val path = NSTemporaryDirectory() + "PROTOTYPE-resume-" + NSUUID().UUIDString + ".db"
        val database = Room.databaseBuilder<AppDatabase>(path).setDriver(NativeSQLiteDriver())
            .addMigrations(*DatabaseMigrations.migrations).build()
        try {
            database.nativeShelfDao.addToShelf(Book(bookUrl="book",origin="source",name="Title",author="Author"),
                listOf(BookChapter(bookUrl="book",url="chapter",title="Chapter",index=3)))
            val saved = database.nativeResumeDao.save("source","book","chapter",3,"first\r\nsecond 🌿",10,0, NativeChapterProjection.from(assertNotNull(database.bookDao.getBook("book"))))
            assertEquals(7, saved.paragraphUtf16Offset)
            assertEquals(1L, saved.revision)
            assertEquals(saved, database.nativeResumeDao.get("book"))
            val book = assertNotNull(database.bookDao.getBook("book"))
            assertEquals(3, book.durChapterIndex)
            assertEquals("Chapter", book.durChapterTitle)
            assertEquals(0, book.durChapterPos)
            assertEquals(saved.savedAt, book.durChapterTime)
        } finally { database.close() }
    }

    private fun path() = NSTemporaryDirectory() + "PROTOTYPE-resume-" + NSUUID().UUIDString + ".db"
    private fun open(path: String) = Room.databaseBuilder<AppDatabase>(path).setDriver(NativeSQLiteDriver())
        .addMigrations(*DatabaseMigrations.migrations).build()
    private suspend fun seed(db: AppDatabase) {
        db.nativeShelfDao.addToShelf(Book(bookUrl="book",origin="source",name="Title",author="Author",durChapterPos=99),
            listOf(BookChapter(bookUrl="book",url="chapter",title="Chapter",index=3)))
    }

    @Test
    fun sharedProgressCommittedAfterPrecheckCannotBeOverwritten() = runBlocking {
        val path = path(); val db = open(path); val shared = open(path)
        try {
            seed(db)
            val saved = db.nativeResumeDao.save("source","book","chapter",3,"body",0,0, NativeChapterProjection.from(assertNotNull(db.bookDao.getBook("book"))))
            for (field in 0..4) {
                val observed = assertNotNull(db.bookDao.getBook("book"))
                // Deterministically schedule a second Room writer after the engine precheck.
                // Test every projection field independently, plus the catalog-selection writer.
                if (field == 4) {
                    shared.bookDao.upDurChapter("book",observed.durChapterIndex + 1,42)
                } else {
                    shared.bookDao.updateProgress("book",
                        observed.durChapterIndex + if (field == 0) 1 else 0,
                        observed.durChapterPos + if (field == 1) 1 else 0,
                        observed.durChapterTime + if (field == 2) 1 else 0,
                        if (field == 3) "Shared chapter" else observed.durChapterTitle)
                }
                val sharedState = shared.bookDao.getBook("book")
                assertEquals(NativeResumeFailure.STALE_REVISION, assertFailsWith<NativeResumeException> {
                    db.nativeResumeDao.save("source","book","chapter",3,"body",0,saved.revision,
                        NativeChapterProjection.from(observed))
                }.failure)
                assertEquals(saved, db.nativeResumeDao.get("book"))
                assertEquals(sharedState, db.bookDao.getBook("book"))
                assertNotEquals(observed, sharedState)
            }
        } finally { shared.close(); db.close() }
    }

    @Test
    fun rejectedWritesAndProjectionFailurePreserveLastCommit() = runBlocking {
        val path = path(); val db = open(path)
        try {
            seed(db)
            val original = db.nativeResumeDao.save("source","book","chapter",3,"one\ntwo",5,0, NativeChapterProjection.from(assertNotNull(db.bookDao.getBook("book"))))
            val projected = db.bookDao.getBook("book")
            suspend fun reject(reason: NativeResumeFailure, source: String="source", chapter: String="chapter", index: Int=3, offset: Int=0, revision: Long=1) {
                assertEquals(reason, assertFailsWith<NativeResumeException> {
                    db.nativeResumeDao.save(source,"book",chapter,index,"one\ntwo",offset,revision, NativeChapterProjection.from(assertNotNull(db.bookDao.getBook("book"))))
                }.failure)
                assertEquals(original, db.nativeResumeDao.get("book"))
                assertEquals(projected, db.bookDao.getBook("book"))
            }
            reject(NativeResumeFailure.STALE_REVISION, revision=0)
            reject(NativeResumeFailure.STALE_REVISION, revision=-1)
            reject(NativeResumeFailure.IDENTITY_CONFLICT, source="other")
            reject(NativeResumeFailure.CHAPTER_MISMATCH, chapter="other")
            reject(NativeResumeFailure.CHAPTER_MISMATCH, index=4)
            reject(NativeResumeFailure.INVALID_POSITION, offset=99)
            NativeSQLiteDriver().open(path).use { it.execSQL("CREATE TRIGGER fail_projection BEFORE UPDATE OF durChapterIndex ON books BEGIN SELECT RAISE(ABORT, 'synthetic projection failure'); END") }
            assertFailsWith<Exception> { db.nativeResumeDao.save("source","book","chapter",3,"changed",0,1, NativeChapterProjection.from(assertNotNull(db.bookDao.getBook("book")))) }
            assertEquals(original, db.nativeResumeDao.get("book"))
            assertEquals(projected, db.bookDao.getBook("book"))
        } finally { db.close() }
    }

    @Test
    fun softRemovalRetainsButDeletionAndLegacyReplacementInvalidate() = runBlocking {
        val path = path(); var db = open(path)
        try {
            seed(db)
            val saved = db.nativeResumeDao.save("source","book","chapter",3,"body",2,0, NativeChapterProjection.from(assertNotNull(db.bookDao.getBook("book"))))
            db.nativeShelfDao.removeFromShelf("source","book")
            assertEquals(saved, db.nativeResumeDao.get("book"))
            assertEquals(NativeResumeFailure.NOT_ON_SHELF, assertFailsWith<NativeResumeException> {
                db.nativeResumeDao.save("source","book","chapter",3,"body",0,1, NativeChapterProjection.from(assertNotNull(db.bookDao.getBook("book"))))
            }.failure)
            val removed = assertNotNull(db.bookDao.getBook("book"))
            db.nativeShelfDao.addToShelf(removed, emptyList())
            assertEquals(saved, db.nativeResumeDao.get("book"))
            db.close(); db = open(path)
            assertEquals(saved, db.nativeResumeDao.get("book"))
            // Catalog replacement does not erase resume; restoration must detect mismatches.
            NativeSQLiteDriver().open(path).use { it.execSQL("PRAGMA foreign_keys=ON"); it.execSQL("DELETE FROM chapters WHERE bookUrl='book'") }
            assertEquals(saved, db.nativeResumeDao.get("book"))
            assertEquals(NativeResumeFailure.CHAPTER_MISMATCH, assertFailsWith<NativeResumeException> {
                db.nativeResumeDao.save("source","book","chapter",3,"body",0,1, NativeChapterProjection.from(assertNotNull(db.bookDao.getBook("book"))))
            }.failure)
            val book = assertNotNull(db.bookDao.getBook("book"))
            db.bookDao.insert(book)
            assertNull(db.nativeResumeDao.get("book"), "Same URL legacy REPLACE invalidates resume")
            db.bookChapterDao.insert(BookChapter(bookUrl="book",url="chapter",title="Chapter",index=3))
            db.nativeResumeDao.save("source","book","chapter",3,"body",0,0, NativeChapterProjection.from(assertNotNull(db.bookDao.getBook("book"))))
            db.bookDao.insert(book.copy(bookUrl="replacement"))
            assertNull(db.nativeResumeDao.get("book"), "Known-identity legacy replacement invalidates old resume")
            db.bookChapterDao.insert(BookChapter(bookUrl="replacement",url="chapter",title="Chapter",index=3))
            db.nativeResumeDao.save("source","replacement","chapter",3,"body",0,0, NativeChapterProjection.from(assertNotNull(db.bookDao.getBook("replacement"))))
            db.bookDao.delete(assertNotNull(db.bookDao.getBook("replacement")))
            assertNull(db.nativeResumeDao.get("replacement"))
        } finally { db.close() }
    }

    @Test
    fun unsupportedVersionAndRevisionOverflowAreNeverOverwritten() = runBlocking {
        val path = path(); val db = open(path)
        try {
            seed(db); db.nativeResumeDao.save("source","book","chapter",3,"body",0,0, NativeChapterProjection.from(assertNotNull(db.bookDao.getBook("book"))))
            for ((sql, reason, revision) in listOf(
                Triple("UPDATE native_reading_resume SET textVersion='future-v2'", NativeResumeFailure.UNSUPPORTED_VERSION,1L),
                Triple("UPDATE native_reading_resume SET textVersion='native-body-v1',revision=9223372036854775807",NativeResumeFailure.STALE_REVISION,Long.MAX_VALUE),
                Triple("UPDATE native_reading_resume SET revision=0",NativeResumeFailure.STALE_REVISION,0L))) {
                NativeSQLiteDriver().open(path).use { it.execSQL(sql) }
                val before = db.nativeResumeDao.get("book"); val book = db.bookDao.getBook("book")
                assertEquals(reason, assertFailsWith<NativeResumeException> {
                    db.nativeResumeDao.save("source","book","chapter",3,"new",0,revision, NativeChapterProjection.from(assertNotNull(db.bookDao.getBook("book"))))
                }.failure)
                assertEquals(before, db.nativeResumeDao.get("book")); assertEquals(book, db.bookDao.getBook("book"))
            }
        } finally { db.close() }
    }

    @Test
    fun independentConnectionsCompareAndSwapOneWinnerPerRevision() = runBlocking {
        val path = path(); val databases = List(4) { open(path) }
        try {
            seed(databases.first())
            databases.forEach { it.bookDao.allBookCount() }
            for (revision in 0L..1L) {
                val start = CompletableDeferred<Unit>()
                val results = withTimeout(15000) { coroutineScope {
                    val workers = databases.mapIndexed { index, db -> async(Dispatchers.Default) {
                        start.await()
                        try { db.nativeResumeDao.save("source","book","chapter",3,"body-$index",2,revision, NativeChapterProjection.from(assertNotNull(db.bookDao.getBook("book")))) }
                        catch (error: NativeResumeException) { assertEquals(NativeResumeFailure.STALE_REVISION,error.failure); null }
                    } }
                    start.complete(Unit); workers.awaitAll()
                } }
                val winner = results.filterNotNull().single()
                assertEquals(revision+1,winner.revision)
                databases.forEach { db -> assertEquals(winner,db.nativeResumeDao.get("book")); assertEquals(winner.savedAt,db.bookDao.getBook("book")?.durChapterTime) }
            }
        } finally { databases.forEach { it.close() } }
    }

    @Test
    fun schema88Through90UpgradePreservesDataAndResume() = runBlocking {
        for (version in listOf(88,89,90)) {
            val path = path(); val driver = NativeSQLiteDriver()
            val fixture = when (version) { 88 -> SCHEMA_88_FIXTURE; 89 -> SCHEMA_89_FIXTURE; else -> SCHEMA_90_FIXTURE }
            driver.open(path).use { connection ->
                fixture.split(";\n").filter { it.isNotBlank() }.forEach { connection.execSQL(it) }
                connection.execSQL("INSERT INTO books(bookUrl,origin,name,author,type,durChapterPos) VALUES('old','source','Original','Author',${BookType.text},37)")
                connection.execSQL("INSERT INTO chapters(url,title,isVolume,bookUrl,`index`,isVip,isPay) VALUES('chapter','Saved',0,'old',4,0,0)")
                connection.execSQL("INSERT INTO cookies(url,cookie) VALUES('source','test=value')")
                connection.execSQL("INSERT INTO book_sources(bookSourceUrl,bookSourceName,bookSourceType,lastUpdateTime,respondTime,weight) VALUES('source','Saved source',0,0,0,0)")
                if (version == 90) {
                    connection.execSQL("INSERT INTO native_reading_resume VALUES('old','source','chapter',4,'native-body-v1','preserved-hash',4,0,7,1234)")
                }
                connection.execSQL("PRAGMA user_version=$version")
            }
            var db = open(path)
            try {
                assertEquals(37, db.bookDao.getBook("old")?.durChapterPos)
                assertEquals("Saved",db.bookChapterDao.getChapter("old",4)?.title)
                if (version == 90) {
                    val retained = assertNotNull(db.nativeResumeDao.get("old"))
                    assertEquals(7L, retained.revision)
                    assertEquals("preserved-hash", retained.textSha256)
                    assertEquals(1234L, retained.savedAt)
                } else assertNull(db.nativeResumeDao.get("old"))
                val saved = db.nativeResumeDao.save("source","old","chapter",4,"body",0,if (version == 90) 7 else 0, NativeChapterProjection.from(assertNotNull(db.bookDao.getBook("old"))))
                db.close(); db = open(path)
                assertEquals(saved,db.nativeResumeDao.get("old"))
                driver.open(path).use { connection ->
                    connection.prepare("PRAGMA user_version").use { assertTrue(it.step()); assertEquals(91,it.getInt(0)) }
                    connection.prepare("SELECT cookie FROM cookies WHERE url='source'").use { assertTrue(it.step()); assertEquals("test=value",it.getText(0)) }
                    connection.prepare("SELECT bookSourceName FROM book_sources WHERE bookSourceUrl='source'").use { assertTrue(it.step()); assertEquals("Saved source",it.getText(0)) }
                    connection.prepare("SELECT bookSourceIcon FROM book_sources WHERE bookSourceUrl='source'").use { assertTrue(it.step()); assertTrue(it.isNull(0)) }
                    connection.prepare("PRAGMA integrity_check").use { assertTrue(it.step()); assertEquals("ok",it.getText(0)) }
                    connection.prepare("PRAGMA foreign_key_check").use { assertFalse(it.step()) }
                }
            } finally { db.close() }
        }
    }

    @Test
    fun unicodeParagraphCoordinatesAndOriginalUtf8Fingerprint() {
        val text = "a\r\nb\nc\rd\u2028e\u2029"
        val expected = listOf(0,0,0,3,3,5,5,7,7,9,9,11)
        expected.forEachIndexed { offset,start -> assertEquals(start,NativeBodyCoordinates.paragraphStart(text,offset)) }
        val unicode = "甲🌿e\u0301👩‍💻"
        assertEquals(10,unicode.length)
        for (offset in listOf(2,6,9,-1,11)) assertFailsWith<NativeResumeException> { NativeBodyCoordinates.paragraphStart(unicode,offset) }
        for (offset in listOf(0,1,3,4,5,7,8,10)) assertEquals(0,NativeBodyCoordinates.paragraphStart(unicode,offset))
        assertEquals(0,NativeBodyCoordinates.paragraphStart("",0))
        assertEquals(2,NativeBodyCoordinates.paragraphStart("a\n\n",2))
        assertEquals(3,NativeBodyCoordinates.paragraphStart("a\n\n",3))
        assertEquals(0,NativeBodyCoordinates.paragraphStart("x".repeat(10000),9999))
        assertEquals("f6261ab5162896550a94207645faa8e79ae51878ecd2e558e0ca28ab485e03e7",NativeBodyCoordinates.sha256(unicode))
        assertNotEquals(NativeBodyCoordinates.sha256("e\u0301"),NativeBodyCoordinates.sha256("é"))
        assertNotEquals(NativeBodyCoordinates.sha256("a\r\nb"),NativeBodyCoordinates.sha256("a\nb"))
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",NativeBodyCoordinates.sha256("abc"))
    }
}
