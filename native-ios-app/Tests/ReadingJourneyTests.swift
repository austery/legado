import XCTest
import ReaderEngine
import SwiftUI
import CryptoKit
import SQLite3
@testable import NativeReader

@MainActor
final class ReadingJourneyTests: XCTestCase {
    private func findText(_ view: UIView) -> AnchoredTextView? {
        if let text = view as? AnchoredTextView { return text }
        return view.subviews.lazy.compactMap { self.findText($0) }.first
    }

    private func checkDirectoryRoundTrip(_ model: ReaderModel) async throws {
        let host = UIHostingController(rootView: ReaderScreen(model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 200_000_000)
        host.view.layoutIfNeeded()
        let text = try XCTUnwrap(findText(host.view))
        text.layoutManager.ensureLayout(for: text.textContainer)
        let glyphs = text.layoutManager.glyphRange(forCharacterRange: (text.text as NSString).range(of: "第50段"), actualCharacterRange: nil)
        let rect = text.layoutManager.boundingRect(forGlyphRange: glyphs, in: text.textContainer)
        text.setContentOffset(CGPoint(x: 0, y: rect.minY), animated: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        let offset = text.contentOffset.y
        XCTAssertGreaterThan(offset, 0)
        model.navigate(.contents)
        try await Task.sleep(nanoseconds: 100_000_000)
        model.navigate(.reading)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(findText(host.view) === text)
        XCTAssertEqual(text.contentOffset.y, offset, accuracy: 2)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) })
        attachment.name = "Reader controls after contents round trip"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTypographyAndResizeKeepVisibleParagraph() async throws {
        let text = (0..<200).map { "第\($0)段：春天的风吹过窗前，读者继续阅读。标点、中文与 emoji 🌿 都应保持完整。" }.joined(separator: "\n\n")
        var style = ReadingStyle()
        let host = UIHostingController(rootView: ReadingText(chapterKey: "sample", text: text, style: style))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 200_000_000)
        host.view.layoutIfNeeded()
        let view = try XCTUnwrap(findText(host.view))
        let target = (text as NSString).range(of: "第100段")
        view.layoutManager.ensureLayout(for: view.textContainer)
        let targetGlyphs = view.layoutManager.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
        let targetRect = view.layoutManager.boundingRect(forGlyphRange: targetGlyphs, in: view.textContainer)
        view.setContentOffset(CGPoint(x: 0, y: targetRect.minY), animated: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        let point = CGPoint(x: view.textContainerInset.left + 1, y: view.contentOffset.y + view.textContainerInset.top + 1)
        let position = try XCTUnwrap(view.closestPosition(to: point))
        let anchor = view.offset(from: view.beginningOfDocument, to: position)
        let paragraph = (text as NSString).paragraphRange(for: NSRange(location: anchor, length: 0))
        XCTAssertGreaterThan(paragraph.location, 0)
        style.size = 30; style.lineSpacing = 12; style.paragraphSpacing = 24; style.margin = 48
        host.rootView = ReadingText(chapterKey: "sample", text: text, style: style)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        try await Task.sleep(nanoseconds: 200_000_000)
        host.view.layoutIfNeeded()
        XCTAssertTrue(view.usesSpreads)
        XCTAssertNotNil(view.spreadView)
        XCTAssertTrue(renderedSpreadRanges(in: view).contains { NSIntersectionRange($0, paragraph).length > 0 },
                      "Original paragraph must remain visible in the actual two-page layout")
        XCTAssertEqual(view.text, text)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) })
        attachment.name = "Long Chinese text after typography and landscape resize"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settle(_ model: ReaderModel, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(20)
        while (model.busy || model.searchRunning || model.searchCommandPending) && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(model.busy || model.searchRunning || model.searchCommandPending, "Operation did not finish", file: file, line: line)
    }

    private func captureShelfView(_ model: ReaderModel, name: String) async throws {
        let host = UIHostingController(rootView: ReaderScreen(model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 834, height: 1194))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 200_000_000)
        host.view.layoutIfNeeded()
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        })
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func importFixture(_ model: ReaderModel, base: String, unknown: Bool = false, enabled: Bool = true, titleSuffix: String = "", paragraphs: Bool = false, duplicateChapters: Bool = false) async throws {
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/sources.json")))
        var json = try XCTUnwrap(String(data: data, encoding: .utf8))
        if !titleSuffix.isEmpty {
            json = json.replacingOccurrences(of: "class.name@text", with: "class.name@text##$## " + titleSuffix)
                .replacingOccurrences(of: "tag.h1@text", with: "tag.h1@text##$## " + titleSuffix)
        }
        if paragraphs { json = json.replacingOccurrences(of: "id.content@text", with: "id.content@text##第##\\n第") }
        if duplicateChapters {
            json = json.replacingOccurrences(of: "\"chapterName\": \"text\"", with: "\"chapterName\": \"text##Chapter [0-9]+##Chapter 1\"")
        }
        if unknown { json = json.replacingOccurrences(of: "class.author@text", with: "class.absent-author@text") }
        if !enabled { json = json.replacingOccurrences(of: "\"enabled\": true", with: "\"enabled\": false") }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        try Data(json.utf8).write(to: local)
        model.importFile(local); try await settle(model); model.confirmFixtureImport(); try await settle(model); XCTAssertNil(model.message)
    }

    func testConflictingTargetKeepsItsCacheAndIsNeverReportedAsSuccessfulSwitch() async throws {
        let model = ReaderModel()
        model.start(); try await settle(model)
        let first = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        let second = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        let title = UUID().uuidString
        try await importFixture(model, base: first, titleSuffix: title)
        try await importFixture(model, base: second, titleSuffix: title)
        model.searchScope = .selected; model.selectedSourceIDs = [first, second]
        model.query = "Path"; model.search(); try await settle(model)
        let old = try XCTUnwrap(model.results.first { $0.sourceId == first })
        let target = try XCTUnwrap(model.results.first { $0.sourceId == second })
        model.select(old); try await settle(model)
        model.addCurrentBook(); try await settle(model)
        model.read(try XCTUnwrap(model.chapters.first)); try await settle(model)
        model.beginSourceSwitch(); try await settle(model)
        model.select(target); try await settle(model)
        let chapter = try XCTUnwrap(model.switchChapters.first)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(documents.appendingPathComponent("legado.db").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        let insert = """
        INSERT INTO books(bookUrl,origin,name,author,type) VALUES(\(quoted(target.id)),\(quoted(second)),\(quoted(target.title)),'Different author',8);
        INSERT INTO chapters(bookUrl,url,title,`index`,isVolume,isVip,isPay) VALUES(\(quoted(target.id)),\(quoted(chapter.id)),\(quoted(chapter.title)),0,0,0,0);
        """
        guard sqlite3_exec(db, insert, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SwitchFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        func shortHash(_ value: String) -> String {
            let hash = Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
            return String(hash.dropFirst(8).prefix(16))
        }
        let cache = documents.appendingPathComponent("book_cache")
            .appendingPathComponent(String(target.title.prefix(9)) + shortHash(target.id))
            .appendingPathComponent("00000-" + shortHash(chapter.title) + ".nb")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalBody = "unrelated\npreserve this offline paragraph"
        try Data(originalBody.utf8).write(to: cache)
        let other = ReaderEngine()
        defer { other.close() }
        func call(_ action: (@escaping (EngineReply) -> Void) -> EngineRequest) async -> EngineReply {
            await withCheckedContinuation { continuation in _ = action { continuation.resume(returning: $0) } }
        }
        _ = await call { other.initialize(completion: $0) }
        let opened = await call { other.openReading(sourceId: second, bookId: target.id, cacheOnly: true, completion: $0) }
        let token = try XCTUnwrap((opened as? ContentReply)?.reading?.token)
        let saved: EngineReply = await withCheckedContinuation { continuation in
            other.saveReadingPosition(token: token, eventSequence: 1, utf16Offset: 10) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(saved is ReadingSaved)
        model.prepareSourceSwitch(chapter); try await settle(model)
        XCTAssertNotNil(model.preparedSwitch)
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), originalBody)
        model.confirmSourceSwitch(); try await settle(model)
        XCTAssertNotNil(model.message)
        XCTAssertNotNil(model.switchingFrom)
        XCTAssertEqual(model.book?.sourceId, first)
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), originalBody)
        let recovered = await call { other.openReading(sourceId: second, bookId: target.id, cacheOnly: true, completion: $0) }
        XCTAssertEqual((recovered as? ContentReply)?.text, originalBody)
        XCTAssertEqual((recovered as? ContentReply)?.reading?.paragraphUtf16Offset, 10)
    }

    func testExplicitSourceSwitchCancellationCommitAndReopen() async throws {
        let model = ReaderModel()
        model.start(); try await settle(model)
        let first = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        let second = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        let title = UUID().uuidString
        try await importFixture(model, base: first, titleSuffix: title, paragraphs: true)
        try await importFixture(model, base: second, titleSuffix: title, paragraphs: true)
        model.searchScope = .selected; model.selectedSourceIDs = [first, second]
        model.query = "Path"; model.search(); try await settle(model)
        let oldBook = try XCTUnwrap(model.results.first { $0.sourceId == first })
        let replacement = try XCTUnwrap(model.results.first { $0.sourceId == second })
        model.select(oldBook); try await settle(model)
        model.addCurrentBook(); try await settle(model)
        model.refreshShelf(); try await settle(model)
        model.read(try XCTUnwrap(model.chapters.first)); try await settle(model)
        XCTAssertTrue(model.canChangeSource)
        model.beginSourceSwitch(); try await settle(model)
        model.select(replacement); try await settle(model)
        XCTAssertEqual(model.route, .sourceSwitch)
        let recommended = try XCTUnwrap(model.recommendedSwitchChapter)
        model.prepareSourceSwitch(recommended); try await settle(model)
        XCTAssertNotNil(model.preparedSwitch)
        model.cancelSourceSwitch(); try await settle(model)
        XCTAssertEqual(model.book?.sourceId, first)
        XCTAssertEqual(model.content?.chapter.sourceId, first)
        model.beginSourceSwitch(); try await settle(model)
        model.select(replacement); try await settle(model)
        model.prepareSourceSwitch(try XCTUnwrap(model.recommendedSwitchChapter)); try await settle(model)
        model.confirmSourceSwitch(); try await settle(model)
        XCTAssertNil(model.message)
        XCTAssertNil(model.switchingFrom)
        XCTAssertEqual(model.book?.sourceId, second)
        XCTAssertEqual(model.content?.reading?.paragraphUtf16Offset, 0)
        model.refreshShelf(); try await settle(model)
        XCTAssertEqual(model.shelf.filter { $0.book.title == oldBook.title }.count, 1)
        let reopened = ReaderEngine()
        defer { reopened.close() }
        func call(_ action: (@escaping (EngineReply) -> Void) -> EngineRequest) async -> EngineReply {
            await withCheckedContinuation { continuation in _ = action { continuation.resume(returning: $0) } }
        }
        let ready = await call { reopened.initialize(completion: $0) }
        XCTAssertTrue(ready is EngineReady)
        let result = await call { reopened.openReading(sourceId: second, bookId: replacement.id, cacheOnly: true, completion: $0) }
        let content = try XCTUnwrap(result as? ContentReply)
        XCTAssertEqual(content.chapter.id, recommended.id)
        XCTAssertEqual(content.reading?.paragraphUtf16Offset, 0)
    }

    func testSwitchPreparationFailureRetainsOriginalReading() async throws {
        let model = ReaderModel()
        model.start(); try await settle(model)
        let first = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        let second = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        let title = UUID().uuidString
        try await importFixture(model, base: first, titleSuffix: title)
        try await importFixture(model, base: second, titleSuffix: title, duplicateChapters: true)
        model.searchScope = .selected; model.selectedSourceIDs = [first, second]
        model.query = "Path"; model.search(); try await settle(model)
        let replacement = try XCTUnwrap(model.results.first { $0.sourceId == second })
        model.select(try XCTUnwrap(model.results.first { $0.sourceId == first })); try await settle(model)
        model.addCurrentBook(); try await settle(model)
        model.refreshShelf(); try await settle(model)
        model.read(try XCTUnwrap(model.chapters.first)); try await settle(model)
        let originalText = model.content?.text
        model.beginSourceSwitch(); try await settle(model)
        model.select(replacement); try await settle(model)
        XCTAssertNil(model.recommendedSwitchChapter, "Duplicate titles require explicit chapter selection")
        model.prepareSourceSwitch(try XCTUnwrap(model.switchChapters.last)); try await settle(model)
        XCTAssertNil(model.preparedSwitch)
        XCTAssertNotNil(model.message)
        XCTAssertEqual(model.book?.sourceId, first)
        XCTAssertEqual(model.content?.text, originalText)
        model.prepareSourceSwitch(try XCTUnwrap(model.switchChapters.last)); try await settle(model)
        XCTAssertNotNil(model.preparedSwitch)
        model.confirmSourceSwitch(); try await settle(model)
        XCTAssertNil(model.message)
        XCTAssertEqual(model.content?.chapter.sourceId, second)
        XCTAssertEqual(model.content?.chapter.index, 2, "Manual selection must win over chapter index matching")
        XCTAssertEqual(model.content?.reading?.paragraphUtf16Offset, 0)
    }

    private func storedProgress(_ bookID: String) throws -> [String] {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("legado.db")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let db = try XCTUnwrap(connection); defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT revision, paragraphUtf16Offset, savedAt FROM native_reading_resume WHERE bookUrl = ?", -1, &statement, nil), SQLITE_OK)
        let row = try XCTUnwrap(statement); defer { sqlite3_finalize(row) }
        return try bookID.withCString { id in
            XCTAssertEqual(sqlite3_bind_text(row, 1, id, -1, nil), SQLITE_OK)
            if sqlite3_step(row) == SQLITE_DONE { return [] }
            return try (0..<sqlite3_column_count(row)).map { String(cString: try XCTUnwrap(sqlite3_column_text(row, $0))) }
        }
    }

    func testSourceExportAndListKeepActiveReadingTokenAndDurableProgress() async throws {
        let model = ReaderModel()
        model.start(); try await settle(model)
        let base = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        try await importFixture(model, base: base, titleSuffix: UUID().uuidString, paragraphs: true)
        model.searchScope = .selected; model.selectedSourceIDs = [base]; model.query = "Path"; model.search()
        try await settle(model)
        model.select(try XCTUnwrap(model.results.first)); try await settle(model)
        model.addCurrentBook(); try await settle(model)
        model.read(try XCTUnwrap(model.chapters.first)); try await settle(model)
        let original = try XCTUnwrap(model.content)
        let token = try XCTUnwrap(original.reading?.token)
        let book = try XCTUnwrap(model.book)
        let before = try storedProgress(book.id)
        model.refreshManagedSources(); try await settle(model)
        model.exportSources([base]); try await settle(model)
        XCTAssertNotNil(model.sourceExportJSON)
        XCTAssertEqual(model.content?.reading?.token, token)
        XCTAssertEqual(model.route, .reading)
        XCTAssertEqual(try storedProgress(book.id), before)
        // A displayed acknowledgment must still be accepted using the original engine token.
        model.readingDisplayed(token, 0)
        model.flushReadingPosition()
        let deadline = Date().addingTimeInterval(5)
        while model.canRetryPosition && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(model.saveNotice)
        XCTAssertNil(model.resumeNotice)
    }

    func testStalePositionCanBeDiscardedWithoutOverwritingSharedProgress() async throws {
        let model = ReaderModel()
        model.start(); try await settle(model)
        let base = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        try await importFixture(model, base: base, titleSuffix: UUID().uuidString, paragraphs: true)
        model.searchScope = .selected; model.selectedSourceIDs = [base]; model.query = "Path"; model.search(); try await settle(model)
        model.select(try XCTUnwrap(model.results.first)); try await settle(model)
        model.addCurrentBook(); try await settle(model)
        model.read(try XCTUnwrap(model.chapters.first)); try await settle(model)
        let original = try XCTUnwrap(model.content)
        let token = try XCTUnwrap(original.reading?.token)

        let other = ReaderEngine()
        defer { other.close() }
        func call(_ start: (@escaping (EngineReply) -> Void) -> EngineRequest) async -> EngineReply {
            await withCheckedContinuation { continuation in _ = start { continuation.resume(returning: $0) } }
        }
        _ = await call { other.initialize(completion: $0) }
        _ = await call { other.openShelfBook(sourceId: base, bookId: original.chapter.bookId, completion: $0) }
        let opened = await call { other.openReading(sourceId: base, bookId: original.chapter.bookId, cacheOnly: true, completion: $0) }
        let otherToken = try XCTUnwrap((opened as? ContentReply)?.reading?.token)
        let saved: EngineReply = await withCheckedContinuation { continuation in
            other.saveReadingPosition(token: otherToken, eventSequence: 1, utf16Offset: 0) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(saved is ReadingSaved)
        model.readingDisplayed(token, 0)
        for _ in 0..<100 {
            if model.saveNotice != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(model.saveNotice)
        model.showShelf(); try await settle(model)
        XCTAssertEqual(model.route, .reading, "Stale writes must not silently discard progress")
        model.discardPositionAndReturnToShelf(); try await settle(model)
        XCTAssertEqual(model.route, .shelf)
        XCTAssertFalse(model.canRetryPosition)
        XCTAssertNil(model.content)
        let entry = try XCTUnwrap(model.shelf.first { $0.book.id == original.chapter.bookId })
        model.openShelfBook(entry); try await settle(model)
        XCTAssertEqual(model.route, .reading)
        XCTAssertNil(model.message)
        XCTAssertEqual(model.content?.reading?.revision, (saved as? ReadingSaved)?.revision)
    }

    func testShelfAddReopenAndRemoveThroughRealEngine() async throws {
        let titleSuffix = UUID().uuidString
        let model = ReaderModel()
        model.start()
        try await settle(model)
        XCTAssertEqual(model.route, .shelf)
        let base = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        try await importFixture(model, base: base, titleSuffix: titleSuffix)
        model.searchScope = .selected; model.selectedSourceIDs = [base]; model.query = "Path"; model.search()
        try await settle(model)
        model.select(try XCTUnwrap(model.results.first))
        try await settle(model)
        model.addCurrentBook()
        try await settle(model)
        XCTAssertNil(model.message)
        let saved = try XCTUnwrap(model.book)
        let catalog = model.chapters.map(\.id)
        model.read(try XCTUnwrap(model.chapters.first)); try await settle(model)
        XCTAssertNil(model.message)
        let candidateBase = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        try await importFixture(model, base: candidateBase, titleSuffix: titleSuffix)
        model.searchScope = .selected; model.selectedSourceIDs = [candidateBase]; model.query = "Path"; model.search(); try await settle(model)
        model.select(try XCTUnwrap(model.results.first)); try await settle(model)
        model.read(try XCTUnwrap(model.chapters.first)); try await settle(model)
        XCTAssertEqual(model.content?.chapter.sourceId, candidateBase)
        model.addCurrentBook(); try await settle(model)
        XCTAssertNil(model.message)
        XCTAssertEqual(model.book?.id, saved.id)
        XCTAssertEqual(model.book?.sourceId, saved.sourceId)
        XCTAssertEqual(model.chapters.map(\.id), catalog)
        XCTAssertNil(model.content, "Candidate text must not attach to the preserved shelf record")
        try await captureShelfView(model, name: "C3 preserved original contents after duplicate add")
        try await importFixture(model, base: base, enabled: false, titleSuffix: titleSuffix)
        let reopened = ReaderModel()
        reopened.start()
        try await settle(reopened)
        let entry = try XCTUnwrap(reopened.shelf.first { $0.book.id == saved.id })
        try await captureShelfView(reopened, name: "C3 persisted shelf")
        reopened.openShelfBook(entry)
        try await settle(reopened)
        XCTAssertNil(reopened.message)
        XCTAssertEqual(reopened.book?.sourceId, saved.sourceId)
        XCTAssertEqual(reopened.chapters.map(\.id), catalog)
        reopened.read(try XCTUnwrap(reopened.chapters.first)); try await settle(reopened)
        XCTAssertNil(reopened.message)
        XCTAssertTrue(reopened.content?.fromCache == true)
        reopened.read(reopened.chapters[1]); try await settle(reopened)
        XCTAssertTrue(reopened.message?.contains("CACHE_UNAVAILABLE") == true, "Disabled sources must not fetch uncached chapters")
        XCTAssertEqual(reopened.content?.chapter.id, catalog.first)
        reopened.removeShelfBook(entry)
        try await settle(reopened)
        XCTAssertNil(reopened.message)
        XCTAssertFalse(reopened.shelf.contains { $0.book.id == saved.id })
    }

    func testDisplayedParagraphSurvivesShelfReopenAndFailedNextChapter() async throws {
        let model = ReaderModel()
        model.start(); try await settle(model)
        let base = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        try await importFixture(model, base: base, titleSuffix: UUID().uuidString, paragraphs: true)
        model.searchScope = .selected; model.selectedSourceIDs = [base]; model.query = "Path"; model.search(); try await settle(model)
        model.select(try XCTUnwrap(model.results.first)); try await settle(model)
        model.addCurrentBook(); try await settle(model)
        model.read(model.chapters[1]); try await settle(model)
        let chapterID = try XCTUnwrap(model.content?.chapter.id)
        let oldToken = try XCTUnwrap(model.content?.reading?.token)
        XCTAssertTrue(model.content?.reading?.canSave == true)
        let host = UIHostingController(rootView: ReaderScreen(model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 300_000_000)
        host.view.layoutIfNeeded()
        let view = try XCTUnwrap(findText(host.view) as? AnchoredTextView)
        let displayDeadline = Date().addingTimeInterval(2)
        while !model.canRetryPosition && Date() < displayDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(model.canRetryPosition, "Visible ReaderScreen must acknowledge its body before scrolling; notice=\(model.resumeNotice ?? "none")")
        let target = (view.text as NSString).range(of: "第80段")
        XCTAssertNotEqual(target.location, NSNotFound)
        let glyph = view.layoutManager.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
        let rect = view.layoutManager.boundingRect(forGlyphRange: glyph, in: view.textContainer)
        view.scrollViewWillBeginDragging(view)
        view.setContentOffset(CGPoint(x: 0, y: rect.minY), animated: false)
        view.scrollViewDidScroll(view)
        view.scrollViewDidEndDragging(view, willDecelerate: false)
        let expected = view.anchor
        XCTAssertGreaterThan(expected, 0)
        model.moveChapter(1); try await settle(model)
        XCTAssertTrue(model.message?.contains("NETWORK") == true)
        XCTAssertEqual(model.content?.chapter.id, chapterID)
        XCTAssertNotEqual(model.content?.reading?.token, oldToken)
        XCTAssertEqual(model.content?.reading?.paragraphUtf16Offset, Int32(expected))
        model.showShelf(); try await settle(model)
        let saved = try XCTUnwrap(model.book)
        let reopened = ReaderModel()
        reopened.start(); try await settle(reopened)
        let entry = try XCTUnwrap(reopened.shelf.first { $0.book.id == saved.id })
        reopened.openShelfBook(entry); try await settle(reopened)
        XCTAssertEqual(reopened.route, .reading)
        XCTAssertEqual(reopened.content?.chapter.id, chapterID)
        XCTAssertEqual(reopened.content?.reading?.paragraphUtf16Offset, Int32(expected))
    }

    func testUnknownAuthorsRemainSeparateAndRemovedBookCanBeReadded() async throws {
        let model = ReaderModel()
        model.start(); try await settle(model)
        let titleSuffix = UUID().uuidString
        var identities: [String] = []
        for _ in 0..<2 {
            let base = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
            try await importFixture(model, base: base, unknown: true, titleSuffix: titleSuffix)
            model.searchScope = .selected; model.selectedSourceIDs = [base]; model.query = "Path"; model.search(); try await settle(model)
            model.select(try XCTUnwrap(model.results.first)); try await settle(model)
            model.addCurrentBook(); try await settle(model)
            XCTAssertNil(model.message)
            let book = try XCTUnwrap(model.book)
            XCTAssertEqual(book.author, "")
            XCTAssertEqual(ReaderModel.authorLabel(book.author), "Unknown author")
            XCTAssertEqual(book.sourceId, base)
            identities.append(book.id)
        }
        XCTAssertNotEqual(identities[0], identities[1])
        model.showShelf(); try await settle(model)
        let entries = model.shelf.filter { identities.contains($0.book.id) }
        XCTAssertEqual(entries.count, 2)
        try await captureShelfView(model, name: "C3 unknown authors coexist")
        let entry = try XCTUnwrap(entries.first)
        model.openShelfBook(entry); try await settle(model)
        let catalog = model.chapters.map(\.id)
        model.removeShelfBook(entry); try await settle(model)
        XCTAssertFalse(model.shelf.contains { $0.book.id == entry.book.id })
        model.addCurrentBook(); try await settle(model)
        XCTAssertNil(model.message)
        XCTAssertEqual(model.book?.id, entry.book.id)
        XCTAssertEqual(model.chapters.map(\.id), catalog)
        model.showShelf(); try await settle(model)
        XCTAssertEqual(model.shelf.filter { identities.contains($0.book.id) }.count, 2)
        for item in entries { model.removeShelfBook(item); try await settle(model) }
    }

    func testPreviouslyNonProgressingRegexCompletesAndNextSearchWorks() async throws {
        let model = ReaderModel()
        model.start()
        try await settle(model)
        let base = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        for name in ["regex-sources.json", "sources.json"] {
            let url = try XCTUnwrap(URL(string: "\(base)/\(name)"))
            let (data, _) = try await URLSession.shared.data(from: url)
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
            try data.write(to: local)
            model.importFile(local)
            try await settle(model)
            model.confirmFixtureImport(); try await settle(model)
            XCTAssertNil(model.message)
        }
        model.searchScope = .selected; model.selectedSourceIDs = [base + "/regex"]
        model.query = "Path"
        model.search()
        try await settle(model)
        XCTAssertNil(model.message)
        XCTAssertTrue(model.results.isEmpty, "ICU removes every matched title fragment without stalling")
        model.cancel()
        model.searchScope = .selected; model.selectedSourceIDs = [base]
        model.search()
        try await settle(model)
        XCTAssertNil(model.message)
        XCTAssertEqual(model.results.first?.title, "Path C Book")
    }

    func testRealImportSearchContentsReadingAndCancellation() async throws {
        let model = ReaderModel()
        model.start()
        model.cancel()
        XCTAssertFalse(model.initialized)
        model.start()
        try await settle(model)
        XCTAssertNil(model.message)
        let sourceURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18769/runs/\(UUID().uuidString)/sources.json"))
        let (data, _) = try await URLSession.shared.data(from: sourceURL)
        let importURL = FileManager.default.temporaryDirectory.appendingPathComponent("sources-\(UUID().uuidString).json")
        try data.write(to: importURL)
        model.importFile(importURL)
        try await settle(model)
        model.confirmFixtureImport(); try await settle(model)
        XCTAssertNil(model.message)
        XCTAssertTrue(model.importDetails?.contains(importURL.lastPathComponent) == true)
        model.searchScope = .selected; model.selectedSourceIDs = [String(sourceURL.absoluteString.dropLast("/sources.json".count))]
        XCTAssertTrue(model.sources.contains { model.selectedSourceIDs.contains($0.id) })
        model.query = "Path"
        model.search()
        try await settle(model)
        XCTAssertNil(model.message)
        let book = try XCTUnwrap(model.results.first)
        XCTAssertEqual(book.title, "Path C Book")
        model.select(book)
        try await settle(model)
        XCTAssertNil(model.message)
        XCTAssertEqual(model.route, .details)
        XCTAssertEqual(model.chapters.count, 3)
        let chapter = try XCTUnwrap(model.chapters.first)
        model.read(chapter)
        try await settle(model)
        XCTAssertEqual(model.route, .reading)
        let first = try XCTUnwrap(model.content)
        XCTAssertTrue(first.text.contains("C1-FIRST"))
        XCTAssertTrue(first.text.contains("C1-MIDDLE"))
        XCTAssertTrue(first.text.contains("C1-LAST"))
        XCTAssertFalse(first.fromCache)
        model.moveChapter(1)
        try await settle(model)
        XCTAssertTrue(model.content?.text.contains("C2-LAST") == true)
        XCTAssertEqual(model.chapterPosition, 1)
        try await checkDirectoryRoundTrip(model)
        let second = try XCTUnwrap(model.content)
        model.moveChapter(-1)
        model.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(model.message)
        XCTAssertEqual(model.content?.chapter.id, second.chapter.id)
        XCTAssertEqual(model.content?.text, second.text)
        model.moveChapter(1)
        try await settle(model)
        XCTAssertNotNil(model.message)
        XCTAssertTrue(model.canRetry)
        XCTAssertEqual(model.content?.chapter.id, second.chapter.id)
        XCTAssertEqual(model.content?.text, second.text)
        model.retry()
        try await settle(model)
        XCTAssertNil(model.message)
        XCTAssertTrue(model.content?.text.contains("C3-LAST") == true)
        model.navigate(.contents)
        model.navigate(.reading)
        XCTAssertEqual(model.content?.chapter.id, model.chapters[2].id)
        model.navigate(.search)
        model.query = "slow"
        model.search()
        model.query = "missing"
        model.search()
        try await settle(model)
        XCTAssertNil(model.message)
        XCTAssertTrue(model.hasSearched)
        XCTAssertTrue(model.results.isEmpty)
        model.query = "http-error"
        model.search()
        try await settle(model)
        XCTAssertNotNil(model.message)
        XCTAssertTrue(model.results.isEmpty)
        model.reportFileError("File provider unavailable")
        XCTAssertFalse(model.canRetry)
        XCTAssertEqual(model.message, "Unable to import file: File provider unavailable")
        XCTAssertNil(model.importDetails)
        model.importFile(FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).json"))
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.canRetry)
        model.cancel()
        XCTAssertNil(model.message)
        XCTAssertFalse(model.busy)
        let invalidURL = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-\(UUID().uuidString).json")
        try Data("{".utf8).write(to: invalidURL)
        let sourceIDs = model.sources.map(\.id)
        model.importFile(invalidURL)
        try await settle(model)
        XCTAssertTrue(model.message?.contains("Malformed source JSON") == true)
        XCTAssertTrue(model.importDetails?.contains(invalidURL.lastPathComponent) == true)
        XCTAssertTrue(model.importDetails?.contains("1 bytes") == true)
        XCTAssertEqual(model.sources.map(\.id), sourceIDs)
    }
}
