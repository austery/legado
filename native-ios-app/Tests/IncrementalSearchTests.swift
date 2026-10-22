import XCTest
import ReaderEngine
@testable import NativeReader

@MainActor
final class IncrementalSearchTests: XCTestCase {

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "Expected state did not arrive", file: file, line: line)
    }

    private struct Source: Encodable {
        let bookSourceUrl: String
        let bookSourceName: String
        let bookSourceType = 0
        let enabled = true
        let searchUrl: String
        let ruleSearch: [String: String] = ["nextPageUrl": "class.next@href", "bookList": "tag.article", "name": "class.book@text", "author": "class.author@text", "bookUrl": "class.book@href", "hasMoreRule": "result.indexOf('data-more=' + String.fromCharCode(34) + 'true') >= 0"]
        let ruleBookInfo: [String: String] = ["canReName": "true", "name": "tag.h1@text", "author": "class.author@text", "intro": "class.intro@text", "tocUrl": "class.toc@href"]
        let ruleToc: [String: String] = ["chapterList": "class.chapter", "chapterName": "text", "chapterUrl": "href"]
        let ruleContent = ["content": "class.content@html"]
    }

    private func setup(_ kinds: [String]) async throws -> (ReaderModel, String) {
        let model = ReaderModel()
        model.start()
        try await waitUntil { model.initialized && !model.busy }
        let fixture = try XCTUnwrap(ProcessInfo.processInfo.environment["SPEC004_FIXTURE_BASE"], "Start search_fixture_server.py and pass its loopback URL through SPEC004_FIXTURE_BASE")
        let base = fixture + "/native-ui-" + UUID().uuidString
        let sources = kinds.map { Source(bookSourceUrl: base + "/" + $0, bookSourceName: "Native search " + $0,
            searchUrl: base + "/search/" + $0 + "?key={{key}}&page={{page}}") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(sources).write(to: file)
        model.importFile(file)
        try await waitUntil { !model.busy }
        model.confirmFixtureImport()
        try await waitUntil { !model.busy }
        XCTAssertNil(model.message)
        let releaseURL = try XCTUnwrap(URL(string: base + "/release"))
        addTeardownBlock { _ = try? await URLSession.shared.data(from: releaseURL) }
        return (model, base)
    }

    private func release(_ base: String) async throws {
        _ = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/release")))
    }

    func testAnotherEngineDisablingHeldSourceRetiresLateSearchPublication() async throws {
        let (model, base) = try await setup(["fast", "slow"])
        defer { model.cancel() }
        model.searchScope = .selected; model.selectedSourceIDs = [base + "/fast", base + "/slow"]
        model.query = "work"; model.search()
        try await waitUntil { model.results.count == 1 && model.searchRunning }
        _ = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/entered/slow")))
        let retained = model.results.map(\.id)
        let engine = ReaderEngine(); defer { engine.close() }
        let initialized = await withCheckedContinuation { continuation in
            _ = engine.initialize { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(initialized is EngineReady)
        let changed = await withCheckedContinuation { continuation in
            _ = engine.setSourcesEnabled(ids: [base + "/slow"], enabled: false) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(changed is ManagedSourcesReply)
        try await waitUntil { !model.searchRunning }
        XCTAssertTrue(model.searchIncomplete)
        XCTAssertFalse(model.hasNextPage)
        XCTAssertFalse(model.searchCommandPending)
        XCTAssertEqual(model.results.map(\.id), retained)
        try await release(base)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.results.map(\.id), retained)
        XCTAssertFalse(model.results.contains { $0.sourceId == base + "/slow" })
    }

    func testDefaultAllSourcesShowsFastCandidatesAndAllowsExactSelectionWhilePeerIsHeld() async throws {
        let (model, base) = try await setup(["fast", "duplicate", "slow"])
        defer { model.cancel() }
        model.query = "work"
        model.search()
        try await waitUntil {
            model.results.filter { $0.sourceId == base + "/fast" || $0.sourceId == base + "/duplicate" }.count == 3
        }
        _ = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/entered/slow")))
        XCTAssertTrue(model.searchRunning)
        let work = try XCTUnwrap(model.searchWorks.first { $0.candidates.contains { $0.book.sourceId == base + "/duplicate" } })
        XCTAssertEqual(work.candidates.filter { $0.book.sourceId.hasPrefix(base + "/") }.count, 3)
        XCTAssertGreaterThanOrEqual(work.sourceCount, 2)
        XCTAssertFalse(model.busy, "A live search must not monopolize foreground loading")
        let candidate = try XCTUnwrap(model.results.first { $0.sourceId == base + "/duplicate" && $0.id.hasSuffix("/alternate") })
        model.select(candidate)
        try await waitUntil { !model.busy }
        XCTAssertEqual(model.book?.id, candidate.id)
        XCTAssertEqual(model.book?.sourceId, base + "/duplicate")
        XCTAssertEqual(model.book?.title, "Exact duplicate")
        XCTAssertEqual(model.chapters.first?.title, "duplicate chapter")
        try await release(base)
        model.cancel()
    }

    func testStopRetainsCompletedCandidatesAndRetiresLatePeerUpdates() async throws {
        let (model, base) = try await setup(["fast", "slow"])
        defer { model.cancel() }
        model.searchScope = .selected
        model.selectedSourceIDs = [base + "/fast", base + "/slow"]
        model.query = "work"; model.search()
        try await waitUntil { model.results.count == 1 && model.searchRunning }
        _ = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/entered/slow")))
        model.stopSearch()
        try await waitUntil { !model.searchRunning && !model.searchCommandPending }
        let retained = model.results.map(\.id)
        XCTAssertEqual(retained.count, 1)
        XCTAssertTrue(model.searchIncomplete)
        XCTAssertFalse(model.searchIsEmpty)
        XCTAssertFalse(model.hasNextPage)
        try await release(base)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.results.map(\.id), retained)
        XCTAssertTrue(model.searchIncomplete)
    }

    func testSelectedScopeEmptySelectionAndReplacementUseOnlyTheCurrentQuery() async throws {
        let (model, base) = try await setup(["fast", "slow", "failure"])
        defer { model.cancel() }
        model.searchScope = .selected
        model.query = "work"
        XCTAssertFalse(model.canSearch)
        model.search()
        XCTAssertFalse(model.hasSearched)
        XCTAssertTrue(model.searchSources.isEmpty)
        model.selectedSourceIDs = [base + "/fast", base + "/slow"]
        model.search()
        try await waitUntil { model.results.count == 1 && model.searchRunning }
        _ = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/entered/slow")))
        model.query = "replacement"
        XCTAssertFalse(model.searchRunning, "Editing a replacement must synchronously retire the old stream")
        model.selectedSourceIDs = [base + "/fast"]
        model.search()
        try await waitUntil { !model.searchRunning && !model.results.isEmpty }
        XCTAssertEqual(model.searchSources.map(\.sourceId), [base + "/fast"])
        XCTAssertEqual(model.results.map(\.title), ["Replacement work"])
        XCTAssertEqual(model.searchWorks.first?.sourceCount, 1)
        XCTAssertFalse(model.searchIncomplete)
        try await release(base)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.results.map(\.title), ["Replacement work"])
        XCTAssertEqual(model.searchSources.map(\.sourceId), [base + "/fast"])
    }

    func testPagingFailureRetryAndRestartRetainTheSameSubscriptionAndIndependentSourceState() async throws {
        let (model, base) = try await setup(["fast", "paged"])
        defer { model.cancel() }
        model.searchScope = .selected
        model.selectedSourceIDs = [base + "/fast", base + "/paged"]
        model.query = "Shared work Fixture author"; model.search()
        try await waitUntil { !model.searchRunning && model.results.count == 2 }
        let session = try XCTUnwrap(model.searchSessionID)
        XCTAssertEqual(model.searchWorks.count, 1)
        XCTAssertEqual(model.searchWorks.first?.sourceCount, 2)
        XCTAssertTrue(model.hasNextPage)
        model.loadMoreSearch()
        try await waitUntil { !model.searchRunning && !model.searchCommandPending && model.message != nil }
        XCTAssertEqual(model.searchSessionID, session)
        XCTAssertTrue(model.searchIncomplete)
        XCTAssertFalse(model.searchIsEmpty)
        XCTAssertTrue(model.message?.contains("HTTP 503") == true)
        XCTAssertEqual(model.results.count, 2, "A failed next page must retain earlier candidates")
        XCTAssertEqual(model.searchSources.first { $0.sourceId == base + "/fast" }?.page, 1)
        model.retrySearchSource(base + "/paged")
        try await waitUntil { !model.searchRunning && !model.searchCommandPending && model.results.count == 3 }
        XCTAssertEqual(model.searchSessionID, session)
        XCTAssertNil(model.message)
        XCTAssertFalse(model.searchIncomplete)
        XCTAssertEqual(model.searchWorks.count, 2)
        XCTAssertEqual(model.searchSources.first { $0.sourceId == base + "/paged" }?.page, 2)
        model.restartSearchSource(base + "/paged")
        try await waitUntil { !model.searchRunning && !model.searchCommandPending && model.results.count == 2 }
        XCTAssertEqual(model.searchSessionID, session)
        XCTAssertEqual(model.searchWorks.count, 1)
        XCTAssertEqual(model.searchWorks.first?.sourceCount, 2)
        XCTAssertFalse(model.results.contains { $0.title == "Second page work" })
        XCTAssertEqual(model.searchSources.first { $0.sourceId == base + "/fast" }?.page, 1)
        XCTAssertTrue(model.hasNextPage)
    }
    func testContinuationUrlSurvivesRetryAndIsClearedByRestart() async throws {
        let (model, base) = try await setup(["cursor"])
        defer { model.cancel() }
        model.searchScope = .selected
        model.selectedSourceIDs = [base + "/cursor"]
        model.query = "work"; model.search()
        try await waitUntil { !model.searchRunning && model.results.count == 1 }
        model.loadMoreSearch()
        try await waitUntil { !model.searchRunning && !model.searchCommandPending && model.message != nil }
        XCTAssertTrue(model.message?.contains("HTTP 503") == true)
        XCTAssertEqual(model.results.count, 1)
        model.retrySearchSource(base + "/cursor")
        try await waitUntil { !model.searchRunning && !model.searchCommandPending && model.results.count == 2 }
        XCTAssertNil(model.message)
        XCTAssertFalse(model.hasNextPage)
        model.restartSearchSource(base + "/cursor")
        try await waitUntil { !model.searchRunning && !model.searchCommandPending && model.results.count == 1 }
        XCTAssertEqual(model.results.first?.title, "Shared work")
        XCTAssertTrue(model.hasNextPage)
        model.loadMoreSearch()
        try await waitUntil { !model.searchRunning && !model.searchCommandPending && model.results.count == 2 }
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/stats")))
        let counts = try JSONDecoder().decode([String: Int].self, from: data)
        let namespace = try XCTUnwrap(URL(string: base)?.lastPathComponent)
        XCTAssertEqual(counts[namespace + "/search/cursor/1"], 2)
        XCTAssertEqual(counts[namespace + "/cursor/cursor/2"], 3)
        XCTAssertNil(counts[namespace + "/search/cursor/2"])
    }

}
