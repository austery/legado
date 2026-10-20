import XCTest
import ReaderEngine
import CryptoKit

@MainActor
final class OfflineCacheTests: XCTestCase {
    private func call(_ start: (@escaping (EngineReply) -> Void) -> EngineRequest) async -> EngineReply {
        await withCheckedContinuation { continuation in _ = start { continuation.resume(returning: $0) } }
    }
    private func batch(_ engine: ReaderEngine, _ book: BookSnapshot, _ chapter: ChapterSnapshot,
                       prefetch: Bool = false) async -> EngineReply {
        await withCheckedContinuation { continuation in
            _ = engine.cacheNextChapters(sourceId: book.sourceId, bookId: book.id,
                afterChapterId: chapter.id, prefetch: prefetch) { reply in
                if let progress = reply as? CacheProgress, progress.running { return }
                continuation.resume(returning: reply)
            }
        }
    }
    private func progress(_ engine: ReaderEngine, _ book: BookSnapshot, _ chapter: ChapterSnapshot,
                          prefetch: Bool = false) async throws -> CacheProgress {
        let reply = await batch(engine, book, chapter, prefetch: prefetch)
        return try XCTUnwrap(reply as? CacheProgress)
    }
    private func control(_ base: String, _ route: String) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + route)))
        return String(decoding: data, as: UTF8.self)
    }
    private func fixture(_ engine: ReaderEngine) async throws -> (BookSnapshot, [ChapterSnapshot], ContentReply) {
        let ready = await call { engine.initialize(completion: $0) }
        XCTAssertTrue(ready is EngineReady)
        let base = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        let suffix = UUID().uuidString
        let json = try await control(base, "/sources.json")
            .replacingOccurrences(of: "class.name@text", with: "class.name@text##$## " + suffix)
            .replacingOccurrences(of: "tag.h1@text", with: "tag.h1@text##$## " + suffix)
            .replacingOccurrences(of: "class.toc@href", with: "class.toc@href##/toc/1##/toc/offline")
        let imported = await call { engine.importSources(json: json, completion: $0) }
        XCTAssertTrue(imported is SourcesReply)
        let result = await call { engine.search(sourceId: base, query: "Path", page: 1, completion: $0) }
        let book = try XCTUnwrap((result as? SearchReply)?.books.first)
        _ = await call { engine.loadBook(sourceId: base, bookId: book.id, completion: $0) }
        let toc = await call { engine.loadToc(sourceId: base, bookId: book.id, completion: $0) }
        let chapters = try XCTUnwrap((toc as? TocReply)?.chapters)
        XCTAssertEqual(chapters.count, 26)
        let added = await call { engine.addToShelf(sourceId: base, bookId: book.id, completion: $0) }
        XCTAssertTrue(added is ShelfEntryReply)
        let loaded = await call { engine.loadChapter(sourceId: base, bookId: book.id,
            chapterId: chapters[0].id, cacheOnly: false, completion: $0) }
        return (book, chapters, try XCTUnwrap(loaded as? ContentReply))
    }
    private func status(_ engine: ReaderEngine, _ book: BookSnapshot) async throws -> OfflineStatus {
        let reply = await call { engine.offlineStatus(sourceId: book.sourceId, bookId: book.id, completion: $0) }
        return try XCTUnwrap(reply as? OfflineStatus)
    }
    private func cacheURL(_ book: BookSnapshot, _ chapter: ChapterSnapshot) -> URL {
        func hash(_ value: String) -> String {
            String(Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().dropFirst(8).prefix(16))
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("book_cache").appendingPathComponent(String(book.title.prefix(9)) + hash(book.id))
            .appendingPathComponent(String(format: "%05d", chapter.index) + "-" + hash(chapter.title) + ".nb")
    }

    func testNextTwentyPartialFailureRetryAndOfflineReadsWithoutNetwork() async throws {
        let engine = ReaderEngine(); defer { engine.close() }
        let (book, chapters, first) = try await fixture(engine)
        _ = try await control(book.sourceId, "/offline/fail/3")
        let partial = try await progress(engine, book, chapters[0])
        XCTAssertEqual(partial.target, 20); XCTAssertEqual(partial.completed, 19)
        XCTAssertEqual(partial.failedChapterIds, [chapters[2].id])
        _ = try await control(book.sourceId, "/offline/fail/none")
        let requestsBefore = try await control(book.sourceId, "/offline/count")
        let retried = try await progress(engine, book, chapters[0])
        XCTAssertEqual(retried.completed, 20); XCTAssertTrue(retried.failedChapterIds.isEmpty)
        let requestsAfter = try await control(book.sourceId, "/offline/count")
        XCTAssertEqual(requestsAfter, requestsBefore + ",3")
        let available = try await status(engine, book).chapters.filter { $0.availability == .available }
        XCTAssertEqual(available.count, 21)
        _ = try await control(book.sourceId, "/offline/disable")
        for chapter in available {
            let read = await call { engine.loadChapter(sourceId: book.sourceId, bookId: book.id,
                chapterId: chapter.chapterId, cacheOnly: true, completion: $0) }
            XCTAssertTrue((read as? ContentReply)?.fromCache == true)
        }
        let unchanged = try await control(book.sourceId, "/offline/count")
        XCTAssertEqual(unchanged, requestsAfter)
        XCTAssertNotNil(first.reading)
    }

    func testPrefetchBoundAndClearProtectSavedAndCrossEngineDisplayedBodies() async throws {
        let engine = ReaderEngine(); defer { engine.close() }
        let (book, chapters, first) = try await fixture(engine)
        let saved: EngineReply = await withCheckedContinuation { continuation in
            engine.finishReading(token: first.reading!.token, eventSequence: 1, utf16Offset: 0) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(saved is ReadingSaved)
        let prefetched = try await progress(engine, book, chapters[0], prefetch: true)
        XCTAssertEqual(prefetched.target, 2); XCTAssertEqual(prefetched.completed, 2)
        let other = ReaderEngine(); defer { other.close() }
        _ = await call { other.initialize(completion: $0) }
        _ = await call { other.openShelfBook(sourceId: book.sourceId, bookId: book.id, completion: $0) }
        let displayed = await call { other.loadChapter(sourceId: book.sourceId, bookId: book.id,
            chapterId: chapters[1].id, cacheOnly: true, completion: $0) }
        XCTAssertTrue(displayed is ContentReply)
        let prepared = await call { engine.prepareCacheClear(sourceId: book.sourceId, bookId: book.id, completion: $0) }
        let plan = try XCTUnwrap(prepared as? CacheClearPrepared)
        XCTAssertEqual(plan.count, 1)
        let cleared = await call { engine.clearOptionalCache(token: plan.token, completion: $0) }
        XCTAssertEqual((cleared as? CacheCleared)?.deleted, 1)
        let states = try await status(engine, book).chapters
        XCTAssertEqual(states[0].availability, .available)
        XCTAssertEqual(states[1].availability, .available)
        XCTAssertEqual(states[2].availability, .missing)
        _ = try await control(book.sourceId, "/offline/disable")
        let restored = await call { engine.openReading(sourceId: book.sourceId, bookId: book.id, cacheOnly: true, completion: $0) }
        XCTAssertEqual((restored as? ContentReply)?.reading?.revision, (saved as? ReadingSaved)?.revision)
    }

    func testInvalidBodiesAndStorageFailureAreNotAvailable() async throws {
        let engine = ReaderEngine(); defer { engine.close() }
        let (book, chapters, first) = try await fixture(engine)
        let saved: EngineReply = await withCheckedContinuation { continuation in
            engine.finishReading(token: first.reading!.token, eventSequence: 1, utf16Offset: 0) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(saved is ReadingSaved)
        try Data("Changed body".utf8).write(to: cacheURL(book, chapters[0]))
        try Data().write(to: cacheURL(book, chapters[1]))
        let blocked = cacheURL(book, chapters[2])
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("owned fixture".utf8).write(to: blocked.appendingPathComponent("marker"))
        defer { try? FileManager.default.removeItem(at: blocked) }
        let initial = try await status(engine, book).chapters
        XCTAssertEqual(initial[0].availability, .unavailable)
        XCTAssertEqual(initial[1].availability, .unavailable)
        XCTAssertEqual(initial[2].availability, .unavailable)
        let result = try await progress(engine, book, chapters[0], prefetch: true)
        XCTAssertEqual(result.completed, 1); XCTAssertEqual(result.failedChapterIds, [chapters[2].id])
        let final = try await status(engine, book).chapters
        XCTAssertEqual(final[0].availability, .unavailable)
        XCTAssertEqual(final[1].availability, .available)
        XCTAssertEqual(final[2].availability, .unavailable)
    }

    func testCancelThenClearRejectsLateNetworkPublication() async throws {
        let engine = ReaderEngine(); defer { engine.close() }
        let (book, chapters, _) = try await fixture(engine)
        _ = try await control(book.sourceId, "/control/hold/chapter")
        let finished = expectation(description: "Cancelled batch")
        var terminal: CacheProgress?
        _ = engine.cacheNextChapters(sourceId: book.sourceId, bookId: book.id,
            afterChapterId: chapters[0].id, prefetch: false) { reply in
            if let progress = reply as? CacheProgress, !progress.running { terminal = progress; finished.fulfill() }
        }
        let entered = try await control(book.sourceId, "/control/entered/chapter")
        XCTAssertEqual(entered, "entered")
        engine.cancelCaching()
        let prepared = await call { engine.prepareCacheClear(sourceId: book.sourceId, bookId: book.id, completion: $0) }
        XCTAssertEqual((prepared as? CacheClearPrepared)?.count, 0)
        _ = try await control(book.sourceId, "/control/release/chapter")
        _ = try await control(book.sourceId, "/control/completed/chapter")
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(terminal?.cancelled, true)
        let states = try await status(engine, book).chapters
        XCTAssertEqual(states.filter { $0.availability == .available }.count, 1)
    }

    func testForegroundReadingAndRemovalRetireHeldCacheWork() async throws {
        for remove in [false, true] {
            let engine = ReaderEngine(); defer { engine.close() }
            let (book, chapters, _) = try await fixture(engine)
            _ = try await control(book.sourceId, "/control/hold/chapter")
            let finished = expectation(description: "Preempted cache")
            _ = engine.cacheNextChapters(sourceId: book.sourceId, bookId: book.id,
                afterChapterId: chapters[0].id, prefetch: true) { reply in
                if let progress = reply as? CacheProgress, !progress.running {
                    XCTAssertTrue(progress.cancelled); finished.fulfill()
                }
            }
            let entered = try await control(book.sourceId, "/control/entered/chapter")
            XCTAssertEqual(entered, "entered")
            // Both foreground operations must complete before the held background response is released.
            if remove {
                let removed = await call { engine.removeFromShelf(sourceId: book.sourceId, bookId: book.id, completion: $0) }
                XCTAssertTrue(removed is ShelfRemoved)
            } else {
                let visible = await call { engine.loadChapter(sourceId: book.sourceId, bookId: book.id,
                    chapterId: chapters[2].id, cacheOnly: false, completion: $0) }
                XCTAssertTrue(visible is ContentReply)
            }
            _ = try await control(book.sourceId, "/control/release/chapter")
            _ = try await control(book.sourceId, "/control/completed/chapter")
            await fulfillment(of: [finished], timeout: 10)
            XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL(book, chapters[1]).path))
        }
    }
}
