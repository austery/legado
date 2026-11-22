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
    private func source(_ engine: ReaderEngine, _ base: String, suffix: String, chapterName: String?,
                        emptyContent: Bool = false, detailAuthor: String? = nil) async throws {
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/sources.json")))
        var json = try XCTUnwrap(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "class.name@text", with: "class.name@text##$## " + suffix)
            .replacingOccurrences(of: "tag.h1@text", with: "tag.h1@text##$## " + suffix)
        if emptyContent { json = json.replacingOccurrences(of: "\"content\": \"id.content@text\"", with: "\"content\": \"\"") }
        if let chapterName {
            json = json.replacingOccurrences(of: "\"chapterName\": \"text\"", with: "\"chapterName\": \"text##\(chapterName)\"")
        }
        if let detailAuthor {
            var rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
            var detail = try XCTUnwrap(rules.first?["ruleBookInfo"] as? [String: Any])
            detail["author"] = "class.author@text##Fixture Author##" + detailAuthor
            rules[0]["ruleBookInfo"] = detail
            json = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
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
        let result = try await locate(old: "Chapter 2##第2章 白眉针", new: "Chapter 3##第2章：  白眉 针！")
        XCTAssertEqual(result.titles, ["Chapter 1", "Chapter 2", "第2章：  白眉 针！"])
        XCTAssertEqual(result.located, 2)
    }

    func testSameChapterNumberWithDifferentNameMatchesByNumber() async throws {
        let result = try await locate(old: "Chapter 2##第2章 旧的名字", new: "Chapter 3##第2章 完全不同")
        XCTAssertEqual(result.titles, ["Chapter 1", "Chapter 2", "第2章 完全不同"])
        XCTAssertEqual(result.located, 2)
    }

    func testSimilarTitlesBelowTheThresholdFallBackToTheOldIndex() async throws {
        // Every replacement title is "Chapter 1"; similarity 7/9 is below 0.96, so upstream keeps index 1.
        let result = try await locate(old: nil, new: "Chapter [0-9]+##Chapter 1")
        XCTAssertEqual(result.titles, ["Chapter 1", "Chapter 1", "Chapter 1"])
        XCTAssertEqual(result.located, 1)
    }

    func testSeveralExactMatchesTakeTheFirstInTheWindow() async throws {
        // Old index 1 is "Chapter 2"; every replacement title becomes "Chapter 2", so upstream takes index 0.
        let result = try await locate(old: nil, new: "Chapter [13]##Chapter 2")
        XCTAssertEqual(result.titles, ["Chapter 2", "Chapter 2", "Chapter 2"])
        XCTAssertEqual(result.located, 0)
    }

    func testEmptyContentRuleIsRejectedInsteadOfCommittingTheChapterLink() async throws {
        let engine = ReaderEngine()
        defer { engine.close() }
        _ = await call { engine.initialize(completion: $0) }
        let suffix = UUID().uuidString
        let old = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        let new = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        try await source(engine, old, suffix: suffix, chapterName: nil)
        try await source(engine, new, suffix: suffix, chapterName: nil, emptyContent: true)
        let (oldBook, oldChapters) = try await catalog(engine, old)
        _ = await call { engine.addToShelf(sourceId: old, bookId: oldBook.id, completion: $0) }
        let (candidate, _) = try await catalog(engine, new)
        let prepared = await call { engine.prepareLocatedSourceSwitch(oldSourceId: old, oldBookId: oldBook.id,
            sourceId: new, bookId: candidate.id, readingChapterId: oldChapters[1].id, completion: $0) }
        let failure = try XCTUnwrap(prepared as? EngineFailure, "\(prepared)")
        XCTAssertTrue(failure.message.contains("link instead of chapter text"), failure.message)
    }

    func testNoTitleOrNumberMatchFallsBackToTheOldIndex() async throws {
        let result = try await locate(old: "Chapter 2##第五章 甲", new: "Chapter ([0-9]+)##乙丙$1")
        XCTAssertEqual(result.titles, ["乙丙1", "乙丙2", "乙丙3"])
        XCTAssertEqual(result.located, 1)
    }

    func testSourceSwitchChecksTheExactDetailAuthorAfterAnAuthorLabel() async throws {
        let engine = ReaderEngine()
        defer { engine.close() }
        _ = await call { engine.initialize(completion: $0) }
        let suffix = UUID().uuidString
        let original = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        try await source(engine, original, suffix: suffix, chapterName: nil)
        let (oldBook, oldChapters) = try await catalog(engine, original)
        let added = await call { engine.addToShelf(sourceId: original, bookId: oldBook.id, completion: $0) }
        XCTAssertTrue(added is ShelfEntryReply)

        let cases = [("作 者：Fixture Author", true), ("作者： Fixture Author", true),
                     ("作\u{00A0}者: Fixture Author", true), ("作者：Another Author", false),
                     ("作者：", false), ("作者 Fixture Author", false),
                     ("作者：Fixture 著 Author", false), ("作者：：Fixture Author", false)]
        for (author, accepted) in cases {
            let replacement = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
            try await source(engine, replacement, suffix: suffix, chapterName: nil, detailAuthor: author)
            let (listing, _) = try await catalog(engine, replacement)
            XCTAssertEqual(listing.author, oldBook.author)
            let detail = await call { engine.loadBook(sourceId: replacement, bookId: listing.id, completion: $0) }
            XCTAssertEqual((detail as? BookReply)?.book.author, author)

            let prepared = await call { engine.prepareLocatedSourceSwitch(oldSourceId: original, oldBookId: oldBook.id,
                sourceId: replacement, bookId: listing.id, readingChapterId: oldChapters[1].id, completion: $0) }
            if accepted {
                let plan = try XCTUnwrap(prepared as? SourceSwitchPrepared, (prepared as? EngineFailure)?.message ?? author)
                XCTAssertEqual(plan.chapter.index, 1, author)
                XCTAssertEqual(plan.replacementBook.title, oldBook.title)
                XCTAssertEqual(plan.replacementBook.author, oldBook.author)
            } else {
                XCTAssertEqual((prepared as? EngineFailure)?.message, "Select another listing with the same known title and author", author)
            }
        }
    }
}
