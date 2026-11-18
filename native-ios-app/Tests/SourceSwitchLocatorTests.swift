import XCTest
import ReaderEngine
@testable import NativeReader

/// Issue #108: the one-step switch prepares the chapter that upstream
/// BookHelpChapterLocator.getDurChapter locates. Each case renames fixture chapters through the
/// source's own chapterName replacement rule, so the located index differs from the old index.
@MainActor
final class SourceSwitchLocatorTests: XCTestCase {
    private func call(_ start: (@escaping (EngineReply) -> Void) -> EngineRequest) async -> EngineReply {
        await withCheckedContinuation { continuation in _ = start { continuation.resume(returning: $0) } }
    }

    /// Imports the fixture source at a fresh base with an optional chapterName replacement.
    private func source(_ engine: ReaderEngine, _ base: String, suffix: String, chapterName: String?) async throws {
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/sources.json")))
        var json = try XCTUnwrap(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "class.name@text", with: "class.name@text##$## " + suffix)
            .replacingOccurrences(of: "tag.h1@text", with: "tag.h1@text##$## " + suffix)
        if let chapterName {
            json = json.replacingOccurrences(of: "\"chapterName\": \"text\"", with: "\"chapterName\": \"text##\(chapterName)\"")
        }
        let imported = await call { engine.importSources(json: json, completion: $0) }
        XCTAssertTrue(imported is SourcesReply, "\(imported)")
    }

    private func catalog(_ engine: ReaderEngine, _ base: String) async throws -> (BookSnapshot, [ChapterSnapshot]) {
        let search = await call { engine.search(sourceId: base, query: "Path", page: 1, completion: $0) }
        let book = try XCTUnwrap((search as? SearchReply)?.books.first, "\(search)")
        let detail = await call { engine.loadBook(sourceId: base, bookId: book.id, completion: $0) }
        XCTAssertTrue(detail is BookReply, "\(detail)")
        let toc = await call { engine.loadToc(sourceId: base, bookId: book.id, completion: $0) }
        return (book, try XCTUnwrap((toc as? TocReply)?.chapters, "\(toc)"))
    }

    /// Shelves the old listing, then prepares a located switch from its chapter at index 1.
    /// Returns the replacement catalog titles and the prepared chapter index.
    private func locate(old oldRule: String?, new newRule: String?) async throws -> (titles: [String], located: Int32) {
        let engine = ReaderEngine()
        defer { engine.close() }
        let ready = await call { engine.initialize(completion: $0) }
        XCTAssertTrue(ready is EngineReady)
        let suffix = UUID().uuidString
        let old = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        let new = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        try await source(engine, old, suffix: suffix, chapterName: oldRule)
        try await source(engine, new, suffix: suffix, chapterName: newRule)
        let (oldBook, oldChapters) = try await catalog(engine, old)
        let added = await call { engine.addToShelf(sourceId: old, bookId: oldBook.id, completion: $0) }
        XCTAssertTrue(added is ShelfEntryReply, "\(added)")
        let (candidate, newChapters) = try await catalog(engine, new)
        // The reading fixture fails chapter 3 once per run on purpose; consume that failure first.
        _ = try? await URLSession.shared.data(from: XCTUnwrap(URL(string: new + "/chapter/3")))
        let prepared = await call { engine.prepareLocatedSourceSwitch(oldSourceId: old, oldBookId: oldBook.id,
            sourceId: new, bookId: candidate.id, readingChapterId: oldChapters[1].id, completion: $0) }
        let plan = try XCTUnwrap(prepared as? SourceSwitchPrepared, "\(prepared)")
        XCTAssertEqual(plan.chapter.sourceId, new)
        _ = await call { engine.cancelSourceSwitch(completion: $0) }
        return (newChapters.map(\.title), plan.chapter.index)
    }

    func testChineseAndArabicNumeralsWithDifferentPositionMatchByTitle() async throws {
        // Old index 1 is "第三十六章 白眉针"; the replacement has the same chapter at index 2 as "第36章 白眉针".
        let result = try await locate(old: "Chapter 2##第三十六章 白眉针", new: "Chapter 3##第36章 白眉针")
        XCTAssertEqual(result.titles, ["Chapter 1", "Chapter 2", "第36章 白眉针"])
        XCTAssertEqual(result.located, 2)
    }

    func testPunctuationAndSpacingDifferencesStillMatch() async throws {
        let result = try await locate(old: "Chapter 2##第2章 白眉针", new: "Chapter 3##第2章：白眉针！")
        XCTAssertEqual(result.titles, ["Chapter 1", "Chapter 2", "第2章：白眉针！"])
        XCTAssertEqual(result.located, 2)
    }

    func testSameChapterNumberWithDifferentNameMatchesByNumber() async throws {
        let result = try await locate(old: "Chapter 2##第2章 旧的名字", new: "Chapter 3##第2章 完全不同")
        XCTAssertEqual(result.titles, ["Chapter 1", "Chapter 2", "第2章 完全不同"])
        XCTAssertEqual(result.located, 2)
    }

    func testDuplicateTitlesFallBackToTheOldIndex() async throws {
        // Every replacement title is "Chapter 1"; no title or number decides, so upstream keeps index 1.
        let result = try await locate(old: nil, new: "Chapter [0-9]+##Chapter 1")
        XCTAssertEqual(result.titles, ["Chapter 1", "Chapter 1", "Chapter 1"])
        XCTAssertEqual(result.located, 1)
    }

    func testNoTitleOrNumberMatchFallsBackToTheOldIndex() async throws {
        let result = try await locate(old: "Chapter 2##第五章 甲", new: "Chapter ([0-9]+)##乙丙$1")
        XCTAssertEqual(result.titles, ["乙丙1", "乙丙2", "乙丙3"])
        XCTAssertEqual(result.located, 1)
    }
}
