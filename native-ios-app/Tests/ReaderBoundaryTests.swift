import XCTest
import ReaderEngine
import SwiftUI
import SQLite3
import Vision
import CryptoKit
@testable import NativeReader

/// Real bridge/storage integration; hosted views provide selected rendering evidence.
@MainActor
final class ReaderBoundaryTests: XCTestCase {
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "Expected boundary state", file: file, line: line)
    }
    private func settle(_ model: ReaderModel) async throws {
        try await wait { !model.busy && !model.searchRunning && !model.searchCommandPending }
        XCTAssertNil(model.message)
    }
    private func control(_ base: String, _ action: String, _ key: String) async throws {
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/control/" + action + "/" + key)))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), ["hold": "held", "entered": "entered", "release": "released", "completed": "completed"][action])
    }
    private func fixture(_ model: ReaderModel, toc: String? = nil) async throws -> (String, BookSnapshot) {
        model.start(); try await settle(model)
        let base = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/sources.json")))
        let suffix = UUID().uuidString
        var json = try XCTUnwrap(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "class.name@text", with: "class.name@text##$## " + suffix)
            .replacingOccurrences(of: "tag.h1@text", with: "tag.h1@text##$## " + suffix)
            .replacingOccurrences(of: "id.content@text", with: "id.content@text##MIDDLE##\\nMIDDLE")
        if let toc { json = json.replacingOccurrences(of: "class.toc@href", with: "class.toc@href##toc/1##toc/" + toc) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(json.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        model.importFile(file); try await settle(model); model.confirmFixtureImport(); try await settle(model)
        model.searchScope = .selected; model.selectedSourceIDs = [base]; model.query = "Path"; model.search()
        try await settle(model)
        return (base, try XCTUnwrap(model.results.first))
    }
    private func host(_ model: ReaderModel) async throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = UIHostingController(rootView: ReaderScreen(model: model))
        window.makeKeyAndVisible()
        try await Task.sleep(nanoseconds: 250_000_000)
        window.rootViewController?.view.layoutIfNeeded()
        return window
    }
    private func textView(_ root: UIView) -> AnchoredTextView? {
        if let text = root as? AnchoredTextView { return text }
        return root.subviews.lazy.compactMap { self.textView($0) }.first
    }
    private func assertVisible(_ label: String, in window: UIWindow, file: StaticString = #filePath, line: UInt = #line) throws {
        let view = try XCTUnwrap(window.rootViewController?.view)
        view.layoutIfNeeded()
        XCTAssertGreaterThan(view.bounds.width, 0)
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        func compact(_ value: String) -> String { value.filter { !$0.isWhitespace }.lowercased() }
        XCTAssertTrue(compact(visible).contains(compact(label)), "Missing visible text: \(label); rendered: \(visible)", file: file, line: line)
        let attachment = XCTAttachment(image: image)
        attachment.name = label; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func sql(_ statement: String) throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(documents.appendingPathComponent("legado.db").path, &connection, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, statement, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    func testLateDetailCannotReplaceSelectedBook() async throws { try await replacement(gate: "detail") }
    func testLateTocCannotReplaceSelectedBook() async throws { try await replacement(gate: "toc") }
    private func replacement(gate: String) async throws {
        let model = ReaderModel()
        let (a, candidateA) = try await fixture(model)
        let (b, candidateB) = try await fixture(model)
        try await control(a, "hold", gate)
        defer { model.cancel() }
        model.select(candidateA)
        try await control(a, "entered", gate)
        model.select(candidateB); try await settle(model)
        let chapters = model.chapters.map(\.id)
        XCTAssertEqual(model.book?.sourceId, b)
        XCTAssertEqual(model.book?.id, candidateB.id)
        XCTAssertEqual(model.route, .details)
        XCTAssertFalse(chapters.isEmpty)
        try await control(a, "release", gate)
        try await control(a, "completed", gate)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.book?.sourceId, b)
        XCTAssertEqual(model.book?.id, candidateB.id)
        XCTAssertEqual(model.chapters.map(\.id), chapters)
        XCTAssertTrue(model.chapters.allSatisfy { $0.sourceId == b && $0.bookId == candidateB.id })
        XCTAssertNil(model.content); XCTAssertNil(model.message)
        XCTAssertEqual(model.route, .details)
        model.read(try XCTUnwrap(model.chapters.first)); try await settle(model)
        XCTAssertEqual(model.content?.chapter.sourceId, b)
        XCTAssertEqual(model.content?.chapter.bookId, candidateB.id)
        XCTAssertTrue(model.content?.text.contains("C1-FIRST") == true)
        XCTAssertEqual(model.route, .reading)
    }

    /// Snapshot both native resume and the shared projection, without issuing a write.
    private func storedProgress(_ bookID: String) throws -> [String] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(documents.appendingPathComponent("legado.db").path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let query = "SELECT r.sourceId, r.chapterUrl, r.chapterIndex, r.textVersion, r.textSha256, r.textUtf16Length, r.paragraphUtf16Offset, r.revision, r.savedAt, b.origin, b.durChapterIndex, b.durChapterTitle, b.durChapterPos, b.durChapterTime FROM native_reading_resume r JOIN books b ON b.bookUrl = r.bookUrl WHERE r.bookUrl = ?"
        XCTAssertEqual(sqlite3_prepare_v2(db, query, -1, &statement, nil), SQLITE_OK)
        let row = try XCTUnwrap(statement)
        defer { sqlite3_finalize(row) }
        return try bookID.withCString { id in
            XCTAssertEqual(sqlite3_bind_text(row, 1, id, -1, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(row), SQLITE_ROW)
            return try (0..<sqlite3_column_count(row)).map { column in
                String(cString: try XCTUnwrap(sqlite3_column_text(row, column)))
            }
        }
    }

    func testEmptyCatalogReportsRuleFailureWithoutAdmissionOrProgressLoss() async throws {
        let model = ReaderModel()
        let (_, savedCandidate) = try await fixture(model)
        model.select(savedCandidate); try await settle(model)
        model.addCurrentBook(); try await settle(model)
        model.read(model.chapters[0]); try await settle(model)
        let previous = try XCTUnwrap(model.content)
        let token = try XCTUnwrap(previous.reading?.token)
        let paragraph = (previous.text as NSString).paragraphRange(for: (previous.text as NSString).range(of: "MIDDLE")).location
        XCTAssertGreaterThan(paragraph, 0)
        model.readingDisplayed(token, paragraph)
        model.showShelf(); try await settle(model)
        let stored = try storedProgress(savedCandidate.id)
        let shelfIDs = Set(model.shelf.map { $0.book.id })

        let (_, candidate) = try await fixture(model, toc: "empty")
        model.select(candidate); try await wait { !model.busy }
        let failure = try XCTUnwrap(model.message)
        XCTAssertTrue(failure.hasPrefix("RULE:"))
        XCTAssertTrue(failure.contains("chapter_list_empty"))
        XCTAssertEqual(model.route, .search, "Failed TOC must not take the successful Contents path")
        XCTAssertTrue(model.canRetry)
        XCTAssertNil(model.book); XCTAssertNil(model.content)
        XCTAssertTrue(model.chapters.isEmpty)
        let window = try await host(model)
        defer { window.isHidden = true }
        try assertVisible("RULE: chapter_list_empty", in: window)
        try assertVisible("Retry", in: window)
        model.retry(); try await wait { !model.busy }
        XCTAssertEqual(model.message, failure)
        XCTAssertTrue(model.canRetry)
        model.addCurrentBook()
        XCTAssertEqual(model.message, failure)
        XCTAssertEqual(model.route, .search)
        XCTAssertNil(model.content)
        window.isHidden = true
        model.showShelf(); try await settle(model)
        XCTAssertEqual(Set(model.shelf.map { $0.book.id }), shelfIDs)
        XCTAssertFalse(model.shelf.contains { $0.book.id == candidate.id })
        XCTAssertEqual(try storedProgress(savedCandidate.id), stored, "Neither the resume row nor shared projection may change")
        model.openShelfBook(try XCTUnwrap(model.shelf.first { $0.book.id == savedCandidate.id })); try await settle(model)
        XCTAssertEqual(model.content?.chapter.sourceId, previous.chapter.sourceId)
        XCTAssertEqual(model.content?.chapter.bookId, previous.chapter.bookId)
        XCTAssertEqual(model.content?.chapter.id, previous.chapter.id)
        XCTAssertEqual(model.content?.text, previous.text)
        XCTAssertEqual(model.content?.reading?.paragraphUtf16Offset, Int32(paragraph))
    }

    private func searchCacheURL(_ book: BookSnapshot, _ chapter: ChapterSnapshot) -> URL {
        func shortHash(_ value: String) -> String {
            String(Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().dropFirst(8).prefix(16))
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("book_cache").appendingPathComponent(String(book.title.prefix(9)) + shortHash(book.id))
            .appendingPathComponent(String(format: "%05d", chapter.index) + "-" + shortHash(chapter.title) + ".nb")
    }

    func testCachedSearchRedundantBindingPreservesResultsAndTruncationIsVisible() async throws {
        let model = ReaderModel(); defer { model.cancel() }
        let (_, candidate) = try await fixture(model)
        model.select(candidate); try await settle(model)
        model.addCurrentBook(); try await settle(model)
        model.read(try XCTUnwrap(model.chapters.first)); try await settle(model)
        let content = try XCTUnwrap(model.content)
        let path = searchCacheURL(try XCTUnwrap(model.book), content.chapter)
        try String(repeating: "needle ", count: 201).write(to: path, atomically: true, encoding: .utf8)
        model.showCachedSearch(); model.cachedSearchQuery = "needle"; model.searchCachedChapters()
        try await wait { !model.cachedSearchBusy }
        let result = try XCTUnwrap(model.cachedSearchResults)
        XCTAssertTrue(result.truncated); XCTAssertEqual(result.hits.count, 200)
        model.cachedSearchQuery = "needle"
        XCTAssertTrue(model.cachedSearchResults === result, "Redundant binding writes must not clear results")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = UIHostingController(rootView: CachedSearchSheet(model: model))
        window.makeKeyAndVisible(); defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 250_000_000)
        window.rootViewController?.view.layoutIfNeeded()
        try assertVisible("Showing the first 200 matches", in: window)
        try String(repeating: "needle ", count: 200).write(to: path, atomically: true, encoding: .utf8)
        model.searchCachedChapters(); try await wait { !model.cachedSearchBusy }
        XCTAssertFalse(try XCTUnwrap(model.cachedSearchResults).truncated)
        model.cachedSearchQuery = "é"; model.searchCachedChapters()
        try await wait { !model.cachedSearchBusy }
        XCTAssertNotNil(model.cachedSearchResults)
        model.cachedSearchQuery = "e\u{301}"
        XCTAssertNil(model.cachedSearchResults, "Canonical equality must not hide a changed original UTF-16 query")
    }

    func testCachedSearchStaleHitRerunClearsReaderErrorAndKeepsQuery() async throws {
        let model = ReaderModel(); defer { model.cancel() }
        let (_, candidate) = try await fixture(model)
        model.select(candidate); try await settle(model)
        model.addCurrentBook(); try await settle(model)
        model.read(try XCTUnwrap(model.chapters.first)); try await settle(model)
        let content = try XCTUnwrap(model.content)
        let path = searchCacheURL(try XCTUnwrap(model.book), content.chapter)
        model.showCachedSearch(); model.cachedSearchQuery = "C1-FIRST"; model.searchCachedChapters()
        try await wait { !model.cachedSearchBusy }
        let hit = try XCTUnwrap(model.cachedSearchResults?.hits.first)
        try "C1-FIRST changed cached text".write(to: path, atomically: true, encoding: .utf8)
        model.openCachedSearchHit(hit)
        try await wait { !model.busy }
        XCTAssertTrue(model.cachedSearchPresented)
        XCTAssertEqual(model.cachedSearchQuery, "C1-FIRST")
        XCTAssertEqual(model.cachedSearchNotice, "Cached text changed or is missing. Search again.")
        XCTAssertNil(model.message); XCTAssertFalse(model.canRetry)
        model.searchCachedChapters(); try await wait { !model.cachedSearchBusy }
        XCTAssertEqual(model.cachedSearchResults?.hits.count, 1)
        XCTAssertNil(model.cachedSearchNotice); XCTAssertNil(model.message)
        model.openCachedSearchHit(try XCTUnwrap(model.cachedSearchResults?.hits.first))
        try await settle(model)
        XCTAssertEqual(model.content?.text, "C1-FIRST changed cached text")
        XCTAssertFalse(model.cachedSearchPresented)
        XCTAssertNotNil(model.cachedSearchSelection)
        model.closeCachedSearch()
        XCTAssertNil(model.message); XCTAssertFalse(model.canRetry)
    }

    private final class ReplyQueue {
        let stage: ReaderModel.ReplyStage
        private var holdNext = true
        var pending: (reply: EngineReply, apply: (EngineReply) -> Void)?
        var tocSources: [String] = []
        var replayCount = 0
        init(stage: ReaderModel.ReplyStage) { self.stage = stage }
        func deliver(_ stage: ReaderModel.ReplyStage, _ reply: EngineReply, _ apply: @escaping (EngineReply) -> Void) {
            if let toc = reply as? TocReply, let source = toc.chapters.first?.sourceId { tocSources.append(source) }
            if holdNext && stage == self.stage && (reply is BookReply || reply is TocReply || reply is CachedChapterResults || reply is ChapterUpdateReply) {
                holdNext = false
                pending = (reply, apply)
            } else { apply(reply) }
        }
        func replay() throws {
            let held = try XCTUnwrap(pending)
            pending = nil
            replayCount += 1
            held.apply(held.reply)
        }
    }

    func testLocalTxtDuplicateKeepsBookmarkAndRestoresWithoutOriginal() async throws {
        let title = "Local-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent(title + ".txt")
        let text = "第一章 开始\n" + title + "\nfirst paragraph\nsecond paragraph 🌿\n第三段\n第二章 继续\nlast paragraph\n"
        try Data(text.utf8).write(to: source)
        let model = ReaderModel(); defer { model.cancel() }
        model.start(); try await settle(model)
        model.importTxt(source); try await settle(model)
        let entry = try XCTUnwrap(model.shelf.first { $0.book.title == title })
        XCTAssertTrue(entry.book.isLocal)
        model.openShelfBook(entry); try await settle(model)
        let content = try XCTUnwrap(model.content)
        let reading = try XCTUnwrap(content.reading)
        let offset = try XCTUnwrap(content.text.range(of: "second paragraph")).lowerBound.utf16Offset(in: content.text)
        XCTAssertGreaterThan(offset, 0)
        model.readingDisplayed(reading.token, offset)
        model.readingScrolled(reading.token, offset)
        model.flushReadingPosition()
        try await wait { model.canSaveBookmark }
        model.saveCurrentBookmark()
        try await wait { !model.bookmarkBusy && model.bookmarkNotice == "Bookmark saved." }
        model.showShelf(); try await settle(model)
        let renamed = directory.appendingPathComponent("renamed.txt")
        try Data(text.utf8).write(to: renamed)
        let concurrent = ReaderModel(); defer { concurrent.cancel() }
        concurrent.start(); try await settle(concurrent)
        model.importTxt(renamed)
        concurrent.importTxt(renamed)
        try await settle(model); try await settle(concurrent)
        XCTAssertEqual(concurrent.shelf.filter { $0.book.id == entry.book.id }.count, 1)
        XCTAssertEqual(model.shelf.filter { $0.book.id == entry.book.id }.count, 1)
        XCTAssertEqual(model.shelf.first { $0.book.id == entry.book.id }?.book.title, title)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: renamed)
        let reopened = ReaderModel(); defer { reopened.cancel() }
        reopened.start(); try await settle(reopened)
        reopened.openShelfBook(try XCTUnwrap(reopened.shelf.first { $0.book.id == entry.book.id }))
        try await settle(reopened)
        XCTAssertEqual(reopened.content?.text, content.text)
        XCTAssertEqual(reopened.content?.reading?.paragraphUtf16Offset, Int32(offset))
        reopened.showBookmarks()
        try await wait { !reopened.bookmarkBusy }
        XCTAssertEqual(reopened.bookmarks.count, 1)
        reopened.openBookmark(try XCTUnwrap(reopened.bookmarks.first)); try await settle(reopened)
        XCTAssertEqual(reopened.content?.reading?.paragraphUtf16Offset, Int32(offset))
    }

    func testManualChapterReplyPreservesLiveReadingAndIgnoresStaleDelivery() async throws {
        for leaveReader in [false, true] {
            let queue = ReplyQueue(stage: .operation)
            let model = ReaderModel(deliverReply: queue.deliver)
            defer { model.cancel() }
            let (base, candidate) = try await fixture(model)
            model.select(candidate); try await settle(model)
            model.addCurrentBook(); try await settle(model)
            model.read(try XCTUnwrap(model.chapters.first)); try await settle(model)
            let original = try XCTUnwrap(model.content)
            let catalog = model.chapters.map(\.id)
            let entry = try XCTUnwrap(model.shelf.first { $0.book.sourceId == base })
            let (_, response) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/control/catalog/append")))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            model.checkNewChapters(entry)
            try await wait { queue.pending != nil }
            let reply = try XCTUnwrap(queue.pending?.reply as? ChapterUpdateReply)
            XCTAssertEqual(reply.added, 1)
            XCTAssertEqual(reply.chapters.count, catalog.count + 1)
            if leaveReader { model.showShelf(); try await settle(model) }
            try queue.replay()
            try await wait { !model.busy }
            XCTAssertEqual(queue.replayCount, 1)
            if leaveReader {
                XCTAssertEqual(model.route, .shelf)
                XCTAssertEqual(model.chapters.map(\.id), catalog)
                XCTAssertNotEqual(model.message, "Added 1 new chapter")
            } else {
                XCTAssertEqual(model.route, .reading)
                XCTAssertTrue(model.content === original)
                XCTAssertEqual(model.content?.reading?.token, original.reading?.token)
                XCTAssertEqual(model.chapters.map(\.id), reply.chapters.map(\.id))
                XCTAssertEqual(model.message, "Added 1 new chapter")
            }
        }
    }

    func testLateCachedSearchCannotReplaceNewQuery() async throws { try await delayedCachedSearch(leaveReader: false) }
    func testLateCachedSearchCannotReopenSheetAfterLeavingReader() async throws { try await delayedCachedSearch(leaveReader: true) }

    private func delayedCachedSearch(leaveReader: Bool) async throws {
        let queue = ReplyQueue(stage: .cachedSearch)
        let model = ReaderModel(deliverReply: queue.deliver)
        defer { model.cancel() }
        let (_, candidate) = try await fixture(model)
        model.select(candidate); try await settle(model)
        model.addCurrentBook(); try await settle(model)
        model.read(try XCTUnwrap(model.chapters.first)); try await settle(model)
        model.showCachedSearch(); model.cachedSearchQuery = "C1-FIRST"; model.searchCachedChapters()
        try await wait { queue.pending != nil }
        XCTAssertFalse(try XCTUnwrap(queue.pending?.reply as? CachedChapterResults).hits.isEmpty)
        if leaveReader {
            model.showShelf(); try await settle(model)
        } else {
            model.cachedSearchQuery = "ZZZNOMATCH"; model.searchCachedChapters()
            try await wait { !model.cachedSearchBusy }
            XCTAssertTrue(try XCTUnwrap(model.cachedSearchResults).hits.isEmpty)
        }
        try queue.replay()
        XCTAssertFalse(model.cachedSearchBusy)
        if leaveReader {
            XCTAssertFalse(model.cachedSearchPresented); XCTAssertNil(model.cachedSearchResults)
            XCTAssertEqual(model.route, .shelf)
        } else {
            XCTAssertTrue(model.cachedSearchPresented)
            XCTAssertEqual(model.cachedSearchQuery, "ZZZNOMATCH")
            XCTAssertTrue(try XCTUnwrap(model.cachedSearchResults).hits.isEmpty)
        }
    }

    func testDeliveredLateDetailSuccessCannotReplaceCompletedReading() async throws { try await delayedDelivery(stage: .detail) }
    func testDeliveredLateTocSuccessCannotReplaceCompletedReading() async throws { try await delayedDelivery(stage: .contents) }
    private func delayedDelivery(stage: ReaderModel.ReplyStage) async throws {
        let queue = ReplyQueue(stage: stage)
        let model = ReaderModel(deliverReply: queue.deliver)
        let (a, candidateA) = try await fixture(model)
        let (b, candidateB) = try await fixture(model)
        model.select(candidateA)
        try await wait { queue.pending != nil }
        let reply = try XCTUnwrap(queue.pending?.reply)
        if stage == .detail {
            XCTAssertEqual(try XCTUnwrap(reply as? BookReply).book.sourceId, a)
        } else {
            XCTAssertTrue(try XCTUnwrap(reply as? TocReply).chapters.allSatisfy { $0.sourceId == a })
        }
        XCTAssertFalse(reply is EngineFailure, "Hold an actual engine success after cancellation conversion, not a delayed HTTP request")
        model.select(candidateB); try await settle(model)
        let catalog = model.chapters.map(\.id)
        model.read(try XCTUnwrap(model.chapters.first)); try await settle(model)
        let body = try XCTUnwrap(model.content)
        XCTAssertEqual(body.chapter.sourceId, b)
        XCTAssertEqual(body.chapter.bookId, candidateB.id)
        XCTAssertEqual(model.route, .reading)
        let aTocCount = queue.tocSources.filter { $0 == a }.count
        print("DELIVERY held=\(stage) A=\(a) B-completed=\(body.chapter.id)")
        try queue.replay()
        XCTAssertEqual(queue.replayCount, 1, "The late success must actually reach the adapter")
        try await settle(model)
        XCTAssertEqual(queue.tocSources.filter { $0 == a }.count, aTocCount, "Late detail must not start an A TOC follow-up")
        XCTAssertEqual(model.book?.sourceId, b)
        XCTAssertEqual(model.book?.id, candidateB.id)
        XCTAssertEqual(model.chapters.map(\.id), catalog)
        XCTAssertTrue(model.chapters.allSatisfy { $0.sourceId == b && $0.bookId == candidateB.id })
        XCTAssertEqual(model.content?.chapter.sourceId, b)
        XCTAssertEqual(model.content?.chapter.bookId, candidateB.id)
        XCTAssertEqual(model.content?.chapter.id, body.chapter.id)
        XCTAssertEqual(model.content?.text, body.text)
        XCTAssertEqual(model.route, .reading)
        XCTAssertFalse(model.canRetry)
        print("DELIVERY replayed=\(queue.replayCount) retained=\(model.content?.chapter.id ?? "missing")")
    }

    func testSingleFirstAndLastChapterBoundaries() async throws {
        for kind in ["single", "1"] {
            let model = ReaderModel()
            let (_, candidate) = try await fixture(model, toc: kind == "1" ? nil : kind)
            model.select(candidate); try await settle(model)
            XCTAssertEqual(model.route, .details)
            XCTAssertEqual(model.chapters.count, kind == "single" ? 1 : 3)

            model.addCurrentBook(); try await settle(model)
            for index in Set([0, model.chapters.count - 1]).sorted() {
                model.read(model.chapters[index]); try await wait { !model.busy }
                // Chapter 3 deliberately fails once in the shared reading fixture.
                if model.content?.chapter.id != model.chapters[index].id { model.retry(); try await settle(model) }
                let original = try XCTUnwrap(model.content)
                let window = try await host(model)
                let label = index == 0 ? "Previous" : "Next"
                try assertVisible(label, in: window)
                if kind == "single" { try assertVisible("Next", in: window) }
                for delta in kind == "single" ? [-1, 1] : [index == 0 ? -1 : 1] {
                    model.moveChapter(delta)
                    XCTAssertFalse(model.busy)
                    XCTAssertEqual(model.content?.chapter.id, original.chapter.id)
                    XCTAssertEqual(model.content?.reading?.token, original.reading?.token)
                    XCTAssertEqual(model.content?.reading?.revision, original.reading?.revision)
                    XCTAssertEqual(model.content?.text, original.text)
                }
                window.isHidden = true
                model.showShelf(); try await settle(model)
            }
        }
    }

    func testCancelLoadingRestoresShelvedBodyAndWritableToken() async throws { try await cancellation(saveInFlight: false) }
    func testCancelLoadingWhileSaveInFlightRestoresWritableToken() async throws { try await cancellation(saveInFlight: true) }
    private func cancellation(saveInFlight: Bool) async throws {
        let model = ReaderModel()
        let (base, candidate) = try await fixture(model)
        model.select(candidate); try await settle(model)
        model.addCurrentBook(); try await settle(model)
        model.read(model.chapters[0]); try await settle(model)
        let original = try XCTUnwrap(model.content)
        let token = try XCTUnwrap(original.reading?.token)
        let marker = (original.text as NSString).range(of: "MIDDLE")
        XCTAssertNotEqual(marker.location, NSNotFound)
        let offset = (original.text as NSString).paragraphRange(for: marker).location
        XCTAssertGreaterThan(offset, 0)
        model.readingDisplayed(token, offset)
        try await Task.sleep(nanoseconds: 100_000_000)
        if saveInFlight {
            // Hold only this disposable host database's writer while a real save starts.
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            var lock: OpaquePointer?
            XCTAssertEqual(sqlite3_open(documents.appendingPathComponent("legado.db").path, &lock), SQLITE_OK)
            let db = try XCTUnwrap(lock)
            defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
            model.readingScrolled(token, offset); model.flushReadingPosition()
            model.moveChapter(1)
            XCTAssertTrue(model.busy)
            model.cancelLoading()
            XCTAssertEqual(model.content?.chapter.id, original.chapter.id)
            XCTAssertEqual(sqlite3_exec(db, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        } else {
            try await control(base, "hold", "chapter")
            model.moveChapter(1)
            try await control(base, "entered", "chapter")
            model.cancelLoading()
            try await control(base, "release", "chapter")
            try await control(base, "completed", "chapter")
        }
        try await wait { !model.busy && model.content?.reading?.token != token }
        XCTAssertNil(model.message); XCTAssertNil(model.saveNotice)
        XCTAssertEqual(model.route, .reading)
        XCTAssertEqual(model.content?.text, original.text)
        XCTAssertEqual(model.content?.chapter.id, original.chapter.id)
        XCTAssertEqual(model.content?.reading?.paragraphUtf16Offset, Int32(offset))
        let recovered = try XCTUnwrap(model.content?.reading?.token)
        let window = try await host(model)
        defer { window.isHidden = true }
        XCTAssertEqual(try XCTUnwrap(textView(window)).text, original.text)
        model.readingDisplayed(recovered, offset); model.readingScrolled(recovered, 0)
        model.showShelf(); try await settle(model)
        let entry = try XCTUnwrap(model.shelf.first { $0.book.id == candidate.id })
        model.openShelfBook(entry); try await settle(model)
        XCTAssertEqual(model.content?.chapter.id, original.chapter.id)
        XCTAssertEqual(model.content?.reading?.paragraphUtf16Offset, 0)
        XCTAssertGreaterThan(try XCTUnwrap(model.content?.reading?.revision), try XCTUnwrap(original.reading?.revision))
    }

    func testRealSaveFailureBlocksLeavingAndRetrySaveAllowsNavigation() async throws {
        let model = ReaderModel()
        let (_, candidate) = try await fixture(model)
        model.select(candidate); try await settle(model)
        model.addCurrentBook(); try await settle(model)
        model.read(model.chapters[0]); try await settle(model)
        let body = try XCTUnwrap(model.content)
        let token = try XCTUnwrap(body.reading?.token)
        model.readingDisplayed(token, 0)
        try await Task.sleep(nanoseconds: 150_000_000)
        let trigger = "boundary_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let bookID = candidate.id.replacingOccurrences(of: "'", with: "''")
        try sql("CREATE TRIGGER \(trigger) BEFORE UPDATE ON native_reading_resume WHEN NEW.bookUrl = '\(bookID)' BEGIN SELECT RAISE(ABORT, 'Owned boundary save rejection'); END")
        defer { try? sql("DROP TRIGGER IF EXISTS \(trigger)") }
        let window = try await host(model)
        defer { window.isHidden = true }
        model.readingScrolled(token, (body.text as NSString).range(of: "MIDDLE").location)
        model.showShelf()
        try await wait { model.saveNotice != nil && !model.busy }
        XCTAssertEqual(model.route, .reading)
        XCTAssertEqual(model.content?.chapter.id, body.chapter.id)
        XCTAssertTrue(model.saveNotice?.contains("Position not saved:") == true)
        XCTAssertTrue(model.saveNotice?.contains("Owned boundary save rejection") == true)
        try await Task.sleep(nanoseconds: 150_000_000)
        try assertVisible("Position not saved:", in: window)
        try assertVisible("Owned boundary", in: window)
        try assertVisible("save rejection", in: window)
        try assertVisible("Retry save", in: window)
        try sql("DROP TRIGGER \(trigger)")
        // Invoke the same action wired by ReaderScreen's rendered Retry save control.
        model.flushReadingPosition()
        try await wait { model.saveNotice == nil }
        XCTAssertEqual(model.route, .reading)
        model.showShelf(); try await settle(model)
        XCTAssertEqual(model.route, .shelf)
        model.openShelfBook(try XCTUnwrap(model.shelf.first { $0.book.id == candidate.id })); try await settle(model)
        XCTAssertEqual(model.content?.chapter.id, body.chapter.id)
        XCTAssertGreaterThan(try XCTUnwrap(model.content?.reading?.paragraphUtf16Offset), 0)
    }
}
