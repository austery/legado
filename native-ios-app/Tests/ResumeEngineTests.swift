import XCTest
import ReaderEngine

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
}
