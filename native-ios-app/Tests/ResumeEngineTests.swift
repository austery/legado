import XCTest
import ReaderEngine
import CryptoKit
import SQLite3

@MainActor
final class ResumeEngineTests: XCTestCase {
    private func call(_ start: (@escaping (EngineReply) -> Void) -> EngineRequest) async -> EngineReply {
        await withCheckedContinuation { continuation in
            _ = start { continuation.resume(returning: $0) }
        }
    }

    private func write(_ start: (@escaping (EngineReply) -> Void) -> Void) async -> EngineReply {
        await withCheckedContinuation { continuation in start { continuation.resume(returning: $0) } }
    }

    private func cachedSearch(_ engine: ReaderEngine, _ source: String, _ book: String, _ query: String) async throws -> CachedChapterResults {
        let reply = await call { engine.searchCachedChapters(sourceId: source, bookId: book, query: query, completion: $0) }
        return try XCTUnwrap(reply as? CachedChapterResults, "\(reply)")
    }

    private func searchStoredRows(_ book: String) throws -> [[String?]] {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("legado.db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        var rows: [[String?]] = []
        for (table, key) in [("books", "bookUrl"), ("native_reading_resume", "bookUrl"), ("native_bookmarks", "ownerBookUrl")] {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT * FROM \(table) WHERE \(key) = ? ORDER BY rowid", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            book.withCString { value in
                XCTAssertEqual(sqlite3_bind_text(statement, 1, value, -1, nil), SQLITE_OK)
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    rows.append([table] + (0..<sqlite3_column_count(statement)).map { column -> String? in
                        guard let text = sqlite3_column_text(statement, column) else { return nil }
                        return String(cString: text)
                    })
                    status = sqlite3_step(statement)
                }
                XCTAssertEqual(status, SQLITE_DONE)
            }
        }
        return rows
    }

    private func searchSourceRequests(_ base: String) async throws -> [String] {
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/control/requests")))
        return try JSONDecoder().decode([String].self, from: data)
    }

    func testCachedSearchOriginalCoordinatesCoverageNoNetworkOrPersistenceAndVerifiedOpen() async throws {
        let engine = ReaderEngine(); defer { engine.close() }
        let (base, _, book, content) = try await fixture(engine)
        let body = "😀first\n😀" + String(repeating: "a", count: 19) + "needle 中文😀中文"
        try body.write(to: cacheURL(book: book, chapter: content.chapter), atomically: true, encoding: .utf8)
        let before = try searchStoredRows(book.id)
        let network = try await searchSourceRequests(base)
        let results = try await cachedSearch(engine, base, book.id, "needle")
        XCTAssertEqual(results.hits.count, 1)
        XCTAssertEqual(results.cachedChapters, 1)
        XCTAssertGreaterThan(results.totalChapters, results.cachedChapters)
        XCTAssertEqual(results.examinedChapters, results.totalChapters)
        XCTAssertFalse(results.truncated)
        let hit = try XCTUnwrap(results.hits.first)
        XCTAssertEqual(Int(hit.utf16Offset), (body as NSString).range(of: "needle").location)
        XCTAssertEqual(hit.textUtf16Length, Int32(body.utf16.count))
        XCTAssertFalse(hit.excerpt.contains("�"))
        XCTAssertTrue(hit.excerpt.hasPrefix("😀"))
        XCTAssertEqual(try searchStoredRows(book.id), before)
        let opened = await call { engine.openCachedSearchHit(hit: hit, completion: $0) }
        let reply = try XCTUnwrap(opened as? ContentReply)
        XCTAssertEqual(reply.text, body)
        XCTAssertTrue(reply.fromCache)
        XCTAssertEqual(reply.reading?.paragraphUtf16Offset, 8)
        XCTAssertEqual(try searchStoredRows(book.id), before)
        let afterNetwork = try await searchSourceRequests(base)
        XCTAssertEqual(afterNetwork, network)
        let token = try XCTUnwrap(reply.reading?.token)
        let saved = await write { engine.saveReadingPosition(token: token, eventSequence: 1, utf16Offset: hit.utf16Offset, completion: $0) }
        XCTAssertEqual((saved as? ReadingSaved)?.paragraphUtf16Offset, 8)
    }

    func testCachedSearchRejectsChangedMissingAndReplacedHitsWithoutFetching() async throws {
        let engine = ReaderEngine(); defer { engine.close() }
        let (base, _, book, content) = try await fixture(engine)
        let path = cacheURL(book: book, chapter: content.chapter)
        let before = try searchStoredRows(book.id)
        let network = try await searchSourceRequests(base)
        let initial = try await cachedSearch(engine, base, book.id, "C1-MIDDLE")
        let hit = try XCTUnwrap(initial.hits.first)
        try "Changed cached body".write(to: path, atomically: true, encoding: .utf8)
        let changed = await call { engine.openCachedSearchHit(hit: hit, completion: $0) }
        XCTAssertTrue(changed is EngineFailure)
        try FileManager.default.removeItem(at: path)
        let missing = await call { engine.openCachedSearchHit(hit: hit, completion: $0) }
        XCTAssertTrue(missing is EngineFailure)
        let empty = try await cachedSearch(engine, base, book.id, "C1-MIDDLE")
        XCTAssertEqual(empty.cachedChapters, 0); XCTAssertTrue(empty.hits.isEmpty)
        try content.text.write(to: path, atomically: true, encoding: .utf8)
        let replaced = await call { engine.openCachedSearchHit(hit: hit, completion: $0) }
        XCTAssertTrue(replaced is EngineFailure)
        XCTAssertEqual(try searchStoredRows(book.id), before)
        let afterNetwork = try await searchSourceRequests(base)
        XCTAssertEqual(afterNetwork, network)
    }

    func testCachedSearchCapUnicodeLiteralEmptyAndCancellation() async throws {
        let engine = ReaderEngine(); defer { engine.close() }
        let (base, _, book, content) = try await fixture(engine)
        let path = cacheURL(book: book, chapter: content.chapter)
        try String(repeating: "😀 needle a.* 中文 ", count: 201).write(to: path, atomically: true, encoding: .utf8)
        let before = try searchStoredRows(book.id)
        let capped = try await cachedSearch(engine, base, book.id, "needle")
        XCTAssertEqual(capped.hits.count, 200); XCTAssertTrue(capped.truncated)
        XCTAssertEqual(capped.hits.first?.utf16Offset, 3)
        let literal = try await cachedSearch(engine, base, book.id, "a.*")
        XCTAssertEqual(literal.hits.count, 200)
        let unicode = try await cachedSearch(engine, base, book.id, "中文")
        XCTAssertEqual(unicode.hits.first?.utf16Offset, 14)
        let blank = await call { engine.searchCachedChapters(sourceId: base, bookId: book.id, query: " ", completion: $0) }
        XCTAssertEqual((blank as? EngineFailure)?.code, .invalidInput)
        let cancelled: EngineReply = await withCheckedContinuation { continuation in
            let request = engine.searchCachedChapters(sourceId: base, bookId: book.id, query: "needle") { continuation.resume(returning: $0) }
            request.cancel()
        }
        XCTAssertEqual((cancelled as? EngineFailure)?.code, .cancelled)
        XCTAssertEqual(try searchStoredRows(book.id), before)
    }

    private func fixture(_ engine: ReaderEngine) async throws -> (String, String, BookSnapshot, ContentReply) {
        let ready = await call { engine.initialize(completion: $0) }
        XCTAssertTrue(ready is EngineReady)
        let base = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/sources.json")))
        let suffix = UUID().uuidString
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "class.name@text", with: "class.name@text##$## " + suffix)
            .replacingOccurrences(of: "tag.h1@text", with: "tag.h1@text##$## " + suffix)
            .replacingOccurrences(of: "id.content@text", with: "id.content@text##C1-MIDDLE##\\nC1-MIDDLE")
        let imported = await call { engine.importSources(json: json, completion: $0) }
        XCTAssertTrue(imported is SourcesReply)
        let search = await call { engine.search(sourceId: base, query: "Path", page: 1, completion: $0) }
        let book = try XCTUnwrap((search as? SearchReply)?.books.first)
        let detail = await call { engine.loadBook(sourceId: base, bookId: book.id, completion: $0) }
        XCTAssertTrue(detail is BookReply)
        let toc = await call { engine.loadToc(sourceId: base, bookId: book.id, completion: $0) }
        let chapter = try XCTUnwrap((toc as? TocReply)?.chapters.first)
        let added = await call { engine.addToShelf(sourceId: base, bookId: book.id, completion: $0) }
        XCTAssertTrue(added is ShelfEntryReply)
        let loaded = await call { engine.loadChapter(sourceId: base, bookId: book.id, chapterId: chapter.id, cacheOnly: false, completion: $0) }
        return (base, json, book, try XCTUnwrap(loaded as? ContentReply))
    }

    func testBookmarksPreserveProgressDeduplicateAndReopenWithDisabledSource() async throws {
        let engine = ReaderEngine()
        defer { engine.close() }
        let (base, json, book, content) = try await fixture(engine)
        let reading = try XCTUnwrap(content.reading)
        let offset = (content.text as NSString).range(of: "C1-MIDDLE").location
        XCTAssertGreaterThan(offset, 0)
        let paragraph = (content.text as NSString).paragraphRange(for: NSRange(location: offset, length: 0)).location
        let first = await write { engine.saveBookmark(token: reading.token, utf16Offset: Int32(offset), completion: $0) }
        let bookmark = try XCTUnwrap((first as? BookmarkSaved)?.bookmark)
        let duplicate = await write { engine.saveBookmark(token: reading.token, utf16Offset: Int32(offset + 2), completion: $0) }
        XCTAssertEqual((duplicate as? BookmarkSaved)?.bookmark.id, bookmark.id)
        let list = await call { engine.listBookmarks(sourceId: base, bookId: book.id, completion: $0) }
        XCTAssertEqual((list as? BookmarksReply)?.bookmarks.map(\.id), [bookmark.id])
        let progress = await call { engine.openReading(sourceId: base, bookId: book.id, cacheOnly: true, completion: $0) }
        XCTAssertEqual((progress as? ContentReply)?.reading?.revision, reading.revision)
        XCTAssertEqual((progress as? ContentReply)?.reading?.paragraphUtf16Offset, reading.paragraphUtf16Offset)
        let disabled = await call { engine.importSources(json: json.replacingOccurrences(of: "\"enabled\": true", with: "\"enabled\": false"), completion: $0) }
        XCTAssertTrue(disabled is SourcesReply)
        let opened = await call { engine.openBookmark(sourceId: base, bookId: book.id, bookmarkId: bookmark.id, completion: $0) }
        let restored = try XCTUnwrap(opened as? ContentReply)
        XCTAssertTrue(restored.fromCache)
        XCTAssertEqual(restored.text, content.text)
        XCTAssertEqual(restored.reading?.paragraphUtf16Offset, Int32(paragraph))
        XCTAssertEqual(restored.reading?.revision, reading.revision)
        let restoredToken = try XCTUnwrap(restored.reading?.token)
        let saved = await write { engine.saveReadingPosition(token: restoredToken, eventSequence: 1, utf16Offset: Int32(offset), completion: $0) }
        XCTAssertTrue(saved is ReadingSaved)
        let removed = await call { engine.deleteBookmark(sourceId: base, bookId: book.id, bookmarkId: bookmark.id, completion: $0) }
        XCTAssertEqual((removed as? BookmarksReply)?.bookmarks.count, 0)
        let removedAgain = await call { engine.deleteBookmark(sourceId: base, bookId: book.id, bookmarkId: bookmark.id, completion: $0) }
        XCTAssertEqual((removedAgain as? BookmarksReply)?.bookmarks.count, 0)
        let missing = await call { engine.openBookmark(sourceId: base, bookId: book.id, bookmarkId: bookmark.id, completion: $0) }
        XCTAssertTrue(missing is EngineFailure)
    }

    func testBookmarkRejectsChangedCacheAndExpiredTokenWithoutChangingProgress() async throws {
        let engine = ReaderEngine()
        defer { engine.close() }
        let (base, json, book, content) = try await fixture(engine)
        let reading = try XCTUnwrap(content.reading)
        let first = await write { engine.saveBookmark(token: reading.token, utf16Offset: 0, completion: $0) }
        let bookmark = try XCTUnwrap((first as? BookmarkSaved)?.bookmark)
        let path = cacheURL(book: book, chapter: content.chapter)
        try "Changed chapter".write(to: path, atomically: true, encoding: .utf8)
        let changed = await write { engine.saveBookmark(token: reading.token, utf16Offset: 0, completion: $0) }
        XCTAssertTrue(changed is EngineFailure)
        let disabled = await call { engine.importSources(json: json.replacingOccurrences(of: "\"enabled\": true", with: "\"enabled\": false"), completion: $0) }
        XCTAssertTrue(disabled is SourcesReply)
        let unavailable = await call { engine.openBookmark(sourceId: base, bookId: book.id, bookmarkId: bookmark.id, completion: $0) }
        XCTAssertTrue(unavailable is EngineFailure)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "Changed chapter")
        try content.text.write(to: path, atomically: true, encoding: .utf8)
        let reopened = await call { engine.openReading(sourceId: base, bookId: book.id, cacheOnly: true, completion: $0) }
        XCTAssertEqual((reopened as? ContentReply)?.reading?.revision, reading.revision)
        let finish = await write { engine.finishReading(token: reading.token, eventSequence: 1, utf16Offset: 0, completion: $0) }
        XCTAssertTrue(finish is ReadingSaved)
        let stale = await write { engine.saveBookmark(token: reading.token, utf16Offset: 0, completion: $0) }
        XCTAssertEqual((stale as? EngineFailure)?.code, .staleUpdate)
    }

    func testResumeRejectsOldEventsAndFinishedTokensAndRestoresWithDisabledSource() async throws {
        let engine = ReaderEngine()
        defer { engine.close() }
        let (base, json, book, content) = try await fixture(engine)
        let reading = try XCTUnwrap(content.reading)
        let body = content.text as NSString
        let middle = body.range(of: "C1-MIDDLE").location
        XCTAssertNotEqual(middle, NSNotFound)
        XCTAssertGreaterThan(middle, 0)
        let paragraphStart = body.paragraphRange(for: NSRange(location: middle, length: 0)).location
        XCTAssertGreaterThan(paragraphStart, 0)
        XCTAssertEqual(body.substring(with: NSRange(location: paragraphStart - 1, length: 1)), "\n")
        let savedReply = await write { engine.saveReadingPosition(token: reading.token, eventSequence: 2, utf16Offset: Int32(middle + 3), completion: $0) }
        let saved = try XCTUnwrap(savedReply as? ReadingSaved)
        XCTAssertGreaterThan(saved.paragraphUtf16Offset, 0)
        XCTAssertEqual(saved.paragraphUtf16Offset, Int32(paragraphStart))
        let stale = await write { engine.saveReadingPosition(token: reading.token, eventSequence: 1, utf16Offset: 0, completion: $0) }
        XCTAssertEqual((stale as? EngineFailure)?.code, .staleUpdate)
        let invalid = await write { engine.saveReadingPosition(token: reading.token, eventSequence: 3, utf16Offset: Int32(body.length + 1), completion: $0) }
        XCTAssertEqual((invalid as? EngineFailure)?.code, .invalidInput)
        let finish = await write { engine.finishReading(token: reading.token, eventSequence: 4, utf16Offset: saved.paragraphUtf16Offset, completion: $0) }
        XCTAssertTrue(finish is ReadingSaved)
        let late = await write { engine.saveReadingPosition(token: reading.token, eventSequence: 5, utf16Offset: 0, completion: $0) }
        XCTAssertEqual((late as? EngineFailure)?.code, .staleUpdate)
        let disabled = await call { engine.importSources(json: json.replacingOccurrences(of: "\"enabled\": true", with: "\"enabled\": false"), completion: $0) }
        XCTAssertTrue(disabled is SourcesReply)
        let reopened = await call { engine.openReading(sourceId: base, bookId: book.id, cacheOnly: true, completion: $0) }
        let restored = try XCTUnwrap(reopened as? ContentReply)
        XCTAssertTrue(restored.fromCache)
        XCTAssertEqual(restored.reading?.paragraphUtf16Offset, saved.paragraphUtf16Offset)
        XCTAssertEqual(restored.text, content.text)
        let removed = await call { engine.removeFromShelf(sourceId: base, bookId: book.id, completion: $0) }
        XCTAssertTrue(removed is ShelfRemoved)
        let removedToken = try XCTUnwrap(restored.reading?.token)
        let afterRemoval = await write { engine.saveReadingPosition(token: removedToken, eventSequence: 1, utf16Offset: 0, completion: $0) }
        XCTAssertEqual((afterRemoval as? EngineFailure)?.code, .staleUpdate)
    }

    func testAcceptedSaveSurvivesSessionCloseAndAnotherEngineCanReopen() async throws {
        let engine = ReaderEngine()
        let (base, _, book, content) = try await fixture(engine)
        let token = try XCTUnwrap(content.reading?.token)
        let saved: EngineReply = await withCheckedContinuation { continuation in
            engine.saveReadingPosition(token: token, eventSequence: 1, utf16Offset: 0) {
                continuation.resume(returning: $0)
            }
            engine.close()
        }
        XCTAssertTrue(saved is ReadingSaved)
        let next = ReaderEngine()
        defer { next.close() }
        let ready = await call { next.initialize(completion: $0) }
        XCTAssertTrue(ready is EngineReady)
        let opened = await call { next.openReading(sourceId: base, bookId: book.id, cacheOnly: true, completion: $0) }
        let restored = try XCTUnwrap(opened as? ContentReply)
        XCTAssertEqual(restored.reading?.revision, (saved as? ReadingSaved)?.revision)
        XCTAssertEqual(restored.chapter.id, content.chapter.id)
    }
    private func cacheURL(book: BookSnapshot, chapter: ChapterSnapshot) -> URL {
        func shortHash(_ value: String) -> String {
            let full = Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
            return String(full.dropFirst(8).prefix(16))
        }
        let folder = String(book.title.prefix(9)) + shortHash(book.id)
        let name = String(format: "%05d", chapter.index) + "-" + shortHash(chapter.title) + ".nb"
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("book_cache").appendingPathComponent(folder).appendingPathComponent(name)
    }

    func testCacheWriteFailureKeepsDownloadedTextWithoutAcknowledgingProgress() async throws {
        let engine = ReaderEngine()
        defer { engine.close() }
        let (base, _, book, first) = try await fixture(engine)
        let firstToken = try XCTUnwrap(first.reading?.token)
        let saved = await write { engine.finishReading(token: firstToken, eventSequence: 1, utf16Offset: 0, completion: $0) }
        let revision = try XCTUnwrap(saved as? ReadingSaved).revision
        let entryReply = await call { engine.openShelfBook(sourceId: base, bookId: book.id, completion: $0) }
        let second = try XCTUnwrap((entryReply as? ShelfEntryReply)?.chapters.dropFirst().first)
        let target = cacheURL(book: book, chapter: second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let marker = target.appendingPathComponent("owned-test-marker")
        try Data("Block replacement".utf8).write(to: marker)
        defer { try? FileManager.default.removeItem(at: target) }
        let loaded = await call { engine.loadChapter(sourceId: base, bookId: book.id, chapterId: second.id, cacheOnly: false, completion: $0) }
        let visible = try XCTUnwrap(loaded as? ContentReply)
        XCTAssertTrue(visible.text.contains("C2-FIRST"))
        XCTAssertFalse(visible.storageNotice.isEmpty)
        XCTAssertEqual(visible.reading?.canSave, false)
        XCTAssertEqual(try Data(contentsOf: marker), Data("Block replacement".utf8))
        let token = try XCTUnwrap(visible.reading?.token)
        let refused = await write { engine.saveReadingPosition(token: token, eventSequence: 1, utf16Offset: 0, completion: $0) }
        XCTAssertEqual((refused as? EngineFailure)?.code, .cacheUnavailable)
        let reopened = await call { engine.openReading(sourceId: base, bookId: book.id, cacheOnly: true, completion: $0) }
        let retained = try XCTUnwrap(reopened as? ContentReply)
        XCTAssertEqual(retained.chapter.id, first.chapter.id)
        XCTAssertEqual(retained.reading?.revision, revision)
        let removed = await call { engine.removeFromShelf(sourceId: base, bookId: book.id, completion: $0) }
        XCTAssertTrue(removed is ShelfRemoved)
        let unshelvedReply = await call { engine.loadChapter(sourceId: base, bookId: book.id, chapterId: second.id, cacheOnly: false, completion: $0) }
        let unshelved = try XCTUnwrap(unshelvedReply as? ContentReply)
        XCTAssertNil(unshelved.reading)
        XCTAssertTrue(unshelved.text.contains("C2-FIRST"))
        XCTAssertFalse(unshelved.storageNotice.isEmpty)
    }

    func testCorruptCacheRejectsOfflineOpenAndPreservesSavedRevision() async throws {
        let engine = ReaderEngine()
        defer { engine.close() }
        let (base, json, book, content) = try await fixture(engine)
        let token = try XCTUnwrap(content.reading?.token)
        let offset = (content.text as NSString).paragraphRange(for: (content.text as NSString).range(of: "C1-MIDDLE")).location
        let savedReply = await write { engine.finishReading(token: token, eventSequence: 1, utf16Offset: Int32(offset), completion: $0) }
        let saved = try XCTUnwrap(savedReply as? ReadingSaved)
        let target = cacheURL(book: book, chapter: content.chapter)
        let original = try Data(contentsOf: target)
        defer { try? original.write(to: target, options: .atomic) }
        try Data("Truncated synthetic cache".utf8).write(to: target, options: .atomic)
        let disabled = await call { engine.importSources(json: json.replacingOccurrences(of: "\"enabled\": true", with: "\"enabled\": false"), completion: $0) }
        XCTAssertTrue(disabled is SourcesReply)
        let failed = await call { engine.openReading(sourceId: base, bookId: book.id, cacheOnly: true, completion: $0) }
        XCTAssertEqual((failed as? EngineFailure)?.code, .cacheUnavailable)
        try original.write(to: target, options: .atomic)
        let restoredReply = await call { engine.openReading(sourceId: base, bookId: book.id, cacheOnly: true, completion: $0) }
        let restored = try XCTUnwrap(restoredReply as? ContentReply)
        XCTAssertEqual(restored.reading?.revision, saved.revision)
        XCTAssertEqual(restored.reading?.paragraphUtf16Offset, saved.paragraphUtf16Offset)
    }

    func testMissingCacheRefusesOfflineOpenWithoutChangingSavedPosition() async throws {
        let engine = ReaderEngine()
        defer { engine.close() }
        let (base, _, book, content) = try await fixture(engine)
        let token = try XCTUnwrap(content.reading?.token)
        let body = content.text as NSString
        let offset = body.paragraphRange(for: body.range(of: "C1-MIDDLE")).location
        let savedReply = await write { engine.finishReading(token: token, eventSequence: 1, utf16Offset: Int32(offset), completion: $0) }
        let saved = try XCTUnwrap(savedReply as? ReadingSaved)
        let target = cacheURL(book: book, chapter: content.chapter)
        let backup = target.appendingPathExtension("owned-test-backup-" + UUID().uuidString)
        try FileManager.default.moveItem(at: target, to: backup)
        defer {
            if FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.moveItem(at: backup, to: target)
            }
        }
        let missing = await call { engine.openReading(sourceId: base, bookId: book.id, cacheOnly: true, completion: $0) }
        XCTAssertEqual((missing as? EngineFailure)?.code, .cacheUnavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try FileManager.default.moveItem(at: backup, to: target)
        let restoredReply = await call { engine.openReading(sourceId: base, bookId: book.id, cacheOnly: true, completion: $0) }
        let restored = try XCTUnwrap(restoredReply as? ContentReply)
        XCTAssertEqual(restored.reading?.revision, saved.revision)
        XCTAssertEqual(restored.reading?.paragraphUtf16Offset, saved.paragraphUtf16Offset)
    }

    private func deleteOwnedFixtureSource(_ sourceID: String) throws {
        let prefix = "http://127.0.0.1:18769/runs/"
        XCTAssertTrue(sourceID.hasPrefix(prefix))
        _ = try XCTUnwrap(UUID(uuidString: String(sourceID.dropFirst(prefix.count))))
        let databaseURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("legado.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(database) }
        XCTAssertEqual(opened, SQLITE_OK)
        let connection = try XCTUnwrap(database)
        sqlite3_busy_timeout(connection, 5_000)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection,
            "DELETE FROM book_sources WHERE bookSourceUrl = ? AND bookSourceName = 'Path C Controlled Source'",
            -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let prepared = try XCTUnwrap(statement)
        sourceID.withCString { pointer in
            XCTAssertEqual(sqlite3_bind_text(prepared, 1, pointer, -1, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(prepared), SQLITE_DONE)
        }
        XCTAssertEqual(sqlite3_changes(connection), 1, "Only the source created by this test may be deleted")
    }

    func testDeletedSourceKeepsVerifiedCacheReadableButCannotFetchAnotherChapter() async throws {
        let engine = ReaderEngine()
        defer { engine.close() }
        let (base, _, book, content) = try await fixture(engine)
        let token = try XCTUnwrap(content.reading?.token)
        let savedReply = await write { engine.finishReading(token: token, eventSequence: 1, utf16Offset: 0, completion: $0) }
        let saved = try XCTUnwrap(savedReply as? ReadingSaved)
        let entryReply = await call { engine.openShelfBook(sourceId: base, bookId: book.id, completion: $0) }
        let second = try XCTUnwrap((entryReply as? ShelfEntryReply)?.chapters.dropFirst().first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL(book: book, chapter: second).path))
        try deleteOwnedFixtureSource(base)
        let sourceReply = await call { engine.listSources(completion: $0) }
        XCTAssertFalse(try XCTUnwrap(sourceReply as? SourcesReply).sources.contains { $0.id == base })
        let reopened = await call { engine.openReading(sourceId: base, bookId: book.id, cacheOnly: false, completion: $0) }
        let restored = try XCTUnwrap(reopened as? ContentReply)
        XCTAssertTrue(restored.fromCache)
        XCTAssertEqual(restored.text, content.text)
        XCTAssertEqual(restored.reading?.revision, saved.revision)
        let uncached = await call { engine.loadChapter(sourceId: base, bookId: book.id, chapterId: second.id, cacheOnly: false, completion: $0) }
        XCTAssertEqual((uncached as? EngineFailure)?.code, .cacheUnavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL(book: book, chapter: second).path))
        let retainedReply = await call { engine.openReading(sourceId: base, bookId: book.id, cacheOnly: true, completion: $0) }
        XCTAssertEqual((retainedReply as? ContentReply)?.reading?.revision, saved.revision)
    }

}
