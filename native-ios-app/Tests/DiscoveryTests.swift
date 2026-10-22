import XCTest
import ReaderEngine
@testable import NativeReader

@MainActor
final class DiscoveryTests: XCTestCase {
    private func call(_ action: (@escaping (EngineReply) -> Void) -> EngineRequest) async -> EngineReply {
        await withCheckedContinuation { continuation in _ = action { continuation.resume(returning: $0) } }
    }
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "Expected discovery state did not arrive", file: file, line: line)
    }
    private func engine() async throws -> ReaderEngine {
        let engine = ReaderEngine()
        let reply1 = await call { engine.initialize(completion: $0) }
        XCTAssertTrue(reply1 is EngineReady)
        return engine
    }
    private func importSource(_ source: DiscoverySourceFixture, into engine: ReaderEngine) async throws {
        let json = try source.json()
        let reply = await call { engine.importSources(json: json, completion: $0) }
        XCTAssertTrue(reply is SourcesReply)
    }
    private func setup(_ category: String = "normal") async throws -> (ReaderEngine, DiscoveryModel, String, DiscoverySourceFixture) {
        let base = "http://127.0.0.1:18769/runs/discovery-" + UUID().uuidString
        let engine = try await engine()
        let fixture = DiscoverySourceFixture(base: base, categories: "Browse::" + base + "/discover/" + category + "?page={{page}}")
        try await importSource(fixture, into: engine)
        let browser = DiscoveryModel(engine: engine)
        browser.openSource(base)
        try await wait { browser.update?.phase == .categories }
        addTeardownBlock { engine.close() }
        return (engine, browser, base, fixture)
    }
    private func choose(_ browser: DiscoveryModel) async throws {
        browser.selectCategory(try XCTUnwrap(browser.categories.first { $0.kind == .category }).id)
        try await wait { browser.update?.phase == .idle && !browser.commandPending }
    }
    private func control(_ base: String, _ path: String) async throws {
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/control/" + path)))
        if path.hasPrefix("entered/") { XCTAssertEqual(String(decoding: data, as: UTF8.self), "entered") }
        if path.hasPrefix("completed/") { XCTAssertEqual(String(decoding: data, as: UTF8.self), "completed") }
    }

    func testDiscoveryUsesExploreRulesAndNormalPaginationStopsOnFinalNonemptyPage() async throws {
        let (_, browser, _, _) = try await setup()
        defer { browser.retire() }
        try await choose(browser)
        XCTAssertEqual(browser.books.map(\.title), ["Discovery first"])
        XCTAssertTrue(browser.hasNextPage)
        browser.loadMore()
        try await wait { browser.books.count == 2 && !browser.loading && !browser.commandPending }
        XCTAssertEqual(browser.books.map(\.title), ["Discovery first", "Discovery second"])
        XCTAssertFalse(browser.hasNextPage)
        XCTAssertNil(browser.failure)
    }

    func testContinuationFailureRetriesTheSameUrlAndPreservesFirstPage() async throws {
        let (_, browser, base, _) = try await setup("retry")
        defer { browser.retire() }
        try await choose(browser)
        let first = browser.books.map(\.id)
        browser.loadMore()
        try await wait { browser.canRetry }
        XCTAssertEqual(browser.books.map(\.id), first)
        XCTAssertEqual(browser.update?.failure?.code, .network)
        browser.retry()
        try await wait { browser.books.count == 2 && !browser.loading }
        XCTAssertFalse(browser.hasNextPage)
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/discover/stats")))
        let stats = try JSONDecoder().decode([String: Int].self, from: data)
        XCTAssertEqual(stats["/discover/cursor-retry?cursor=second"], 2)
        XCTAssertNil(stats["/discover/retry?page=2"])
    }

    func testDuplicateOnlyPagesStopAndEmptyCategoriesDifferFromFailures() async throws {
        let (_, browser, _, _) = try await setup("repeat")
        defer { browser.retire() }
        try await choose(browser); browser.loadMore()
        try await wait { !browser.loading && !browser.commandPending && !browser.hasNextPage }
        XCTAssertEqual(browser.books.count, 1)
        XCTAssertNil(browser.failure)
        let (_, empty, _, _) = try await setup("empty")
        defer { empty.retire() }
        try await choose(empty)
        XCTAssertTrue(empty.books.isEmpty)
        XCTAssertNil(empty.failure)
        XCTAssertFalse(empty.hasNextPage)
        let (_, failed, _, _) = try await setup("failure")
        defer { failed.retire() }
        try await choose(failed)
        XCTAssertTrue(failed.canRetry)
        let revision = failed.update?.revision
        failed.retry()
        try await wait { failed.canRetry && failed.update?.revision != revision }
        XCTAssertEqual(failed.update?.failure?.code, .network)
    }

    func testOptionsResetPagesAndKeepUpstreamSingleAndMultiSelectionSemantics() async throws {
        let (engine, browser, base, _) = try await setup()
        defer { browser.retire() }
        let rule = "Options::" + base + "/discover/options?order=<Order(Hot:hot,New:new)>&tags=<Tags(A:a,B:b)|,>&page={{page}}"
        let replacement = DiscoverySourceFixture(base: base, categories: rule)
        try await importSource(replacement, into: engine)
        browser.openSource(base)
        try await wait { browser.update?.phase == .categories }
        try await choose(browser)
        XCTAssertEqual(browser.books.map(\.title), ["hot"])
        let order = try XCTUnwrap(browser.options.first { $0.name == "Order" })
        browser.selectOption(order, choice: try XCTUnwrap(order.choices.first { $0.value == "new" }))
        try await wait { !browser.loading && browser.books.first?.title == "new" }
        let tags = try XCTUnwrap(browser.options.first { $0.name == "Tags" })
        browser.selectOption(tags, choice: try XCTUnwrap(tags.choices.first { $0.value == "b" }))
        try await wait { !browser.loading && browser.books.first?.title == "new b" }
        let updated = try XCTUnwrap(browser.options.first { $0.name == "Tags" })
        browser.selectOption(updated, choice: try XCTUnwrap(updated.choices.first { $0.value == "a" }))
        try await wait { !browser.loading && browser.books.first?.title == "new a,b" }
        XCTAssertFalse(browser.hasNextPage)
    }

    func testAnotherEngineDisableTerminatesHeldPageAndRetainsCompletedBooks() async throws {
        let (_, browser, base, _) = try await setup("held")
        defer { browser.retire() }
        try await choose(browser)
        let retained = browser.books.map(\.id)
        try await control(base, "hold/discovery")
        browser.loadMore()
        try await control(base, "entered/discovery")
        let other = try await self.engine(); defer { other.close() }
        let reply2 = await call { other.setSourcesEnabled(ids: [base], enabled: false, completion: $0) }
        XCTAssertTrue(reply2 is ManagedSourcesReply)
        try await wait { browser.cancelled && !browser.loading && !browser.commandPending }
        XCTAssertEqual(browser.books.map(\.id), retained)
        XCTAssertFalse(browser.hasNextPage)
        try await control(base, "release/discovery")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(browser.books.map(\.id), retained)
        XCTAssertFalse(browser.loading)
    }

    func testSameIdentityAndCategoryUrlImportInvalidatesHeldJsAndCategoryCache() async throws {
        let (engine, browser, base, _) = try await setup()
        defer { browser.retire() }
        let script = "@js:java.ajax('" + base + "/discover/categories');JSON.stringify([{title:categoryLabel,url:'" + base + "/discover/normal?page={{page}}'}])"
        var old = DiscoverySourceFixture(base: base, categories: script); old.jsLib = "var categoryLabel='Old categories';"
        try await importSource(old, into: engine)
        try await control(base, "hold/categories")
        browser.openSource(base)
        try await control(base, "entered/categories")
        let other = try await self.engine(); defer { other.close() }
        var new = old; new.jsLib = "var categoryLabel='New categories';"; new.lastUpdateTime = 2
        try await importSource(new, into: other)
        try await wait { browser.cancelled && !browser.loading }
        try await control(base, "release/categories")
        browser.openSource(base)
        try await wait { browser.categories.first?.name == "New categories" && !browser.loading }
        XCTAssertEqual(browser.categories.map(\.name), ["New categories"])
        XCTAssertNil(browser.failure)
    }

    func testCategoryReplacementAndStopRejectHeldLatePages() async throws {
        let (engine, browser, base, _) = try await setup("held")
        defer { browser.retire() }
        var source = DiscoverySourceFixture(base: base)
        source.exploreUrl = "Held::" + base + "/discover/held?page={{page}}&&Other::" + base + "/discover/options?order=new&page={{page}}"
        try await importSource(source, into: engine)
        browser.openSource(base); try await wait { browser.categories.count == 2 }
        try await choose(browser)
        try await control(base, "hold/discovery"); browser.loadMore(); try await control(base, "entered/discovery")
        browser.selectCategory(try XCTUnwrap(browser.categories.last).id)
        try await wait { browser.books.first?.title == "new" && !browser.loading }
        try await control(base, "release/discovery"); try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(browser.books.map(\.title), ["new"])
        browser.stop(); try await wait { browser.cancelled }
        XCTAssertEqual(browser.books.map(\.title), ["new"])
        XCTAssertFalse(browser.hasNextPage)
    }

    func testOptionReplacementWhilePageIsHeldCannotAppendTheOldSelection() async throws {
        let (engine, browser, base, _) = try await setup()
        defer { browser.retire() }
        let source = DiscoverySourceFixture(base: base, categories: "Options::" + base + "/discover/option-held?order=<Order(Hot:hot,New:new)>&page={{page}}")
        try await importSource(source, into: engine)
        browser.openSource(base); try await wait { browser.update?.phase == .categories }
        try await choose(browser)
        XCTAssertEqual(browser.books.map(\.title), ["hot"])
        try await control(base, "hold/discovery"); browser.loadMore(); try await control(base, "entered/discovery")
        let option = try XCTUnwrap(browser.options.first)
        browser.selectOption(option, choice: try XCTUnwrap(option.choices.first { $0.value == "new" }))
        try await wait { browser.books.first?.title == "new" && !browser.loading }
        try await control(base, "release/discovery"); try await control(base, "completed/discovery")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(browser.books.map(\.title), ["new"])
        XCTAssertFalse(browser.hasNextPage)
    }

    func testSourceReplacementRejectsOldHeldResultsAndKeepsExactNewIdentity() async throws {
        let (engine, browser, base, first) = try await setup("held")
        defer { browser.retire() }
        let secondID = base + "/second-source"
        let second = DiscoverySourceFixture(base: base, id: secondID, categories: "Other::" + base + "/discover/options?order=new&page={{page}}")
        let json = String(decoding: try JSONEncoder().encode([first, second]), as: UTF8.self)
        _ = await call { engine.importSources(json: json, completion: $0) }
        browser.openSource(base); try await wait { browser.update?.phase == .categories }; try await choose(browser)
        try await control(base, "hold/discovery"); browser.loadMore(); try await control(base, "entered/discovery")
        browser.openSource(secondID); try await wait { browser.update?.phase == .categories }; try await choose(browser)
        try await control(base, "release/discovery"); try await control(base, "completed/discovery")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(browser.books.map(\.title), ["new"])
        XCTAssertEqual(browser.books.map(\.sourceId), [secondID])
        XCTAssertFalse(browser.cancelled)
    }

    func testPlainJsonJsHeadingsUnsupportedActionsAndMalformedVersusEmpty() async throws {
        let (engine, browser, base, _) = try await setup()
        defer { browser.retire() }
        var source = DiscoverySourceFixture(base: base, categories: "TITLE:Browse&&BUTTON:Login::java.startBrowser('https://fixture.invalid')&&Popular::" + base + "/discover/normal?page={{page}}")
        try await importSource(source, into: engine)
        browser.openSource(base); try await wait { browser.categories.count == 3 }
        XCTAssertEqual(browser.categories.map(\.kind), [.heading, .unsupported, .category])
        browser.selectCategory(try XCTUnwrap(browser.categories.first { $0.kind == .unsupported }).id)
        try await wait { browser.failure != nil && !browser.commandPending }
        XCTAssertTrue(browser.failure?.contains("UNSUPPORTED") == true)
        for (rule, expected) in [("[]", "empty"), ("[\"invalid\"]", "error"), ("@js:JSON.stringify([{title:'JS category',url:'" + base + "/discover/normal?page={{page}}'}])", "js")] {
            source.exploreUrl = rule
            try await importSource(source, into: engine)
            browser.openSource(base); try await wait { !browser.loading }
            if expected == "empty" { XCTAssertTrue(browser.categories.isEmpty); XCTAssertNil(browser.failure) }
            else if expected == "error" { XCTAssertEqual(browser.update?.failure?.code, .rule); XCTAssertTrue(browser.canRetry) }
            else { XCTAssertEqual(browser.categories.first?.name, "JS category"); XCTAssertNil(browser.failure) }
        }
        source.exploreUrl = "[{\"title\":\"Action without URL\",\"type\":\"button\"}]"
        try await importSource(source, into: engine)
        browser.openSource(base); try await wait { !browser.loading }
        XCTAssertEqual(browser.categories.first?.kind, .unsupported)
        source.exploreUrl = "@js:java.startBrowser('https://fixture.invalid','Verify'); '[]'"
        try await importSource(source, into: engine)
        browser.openSource(base); try await wait { !browser.loading }
        XCTAssertEqual(browser.update?.failure?.code, .interactionRequired)
    }

    func testDynamicUrlOptionsRemainSelectableAfterFirstRequestFailure() async throws {
        let (engine, browser, base, _) = try await setup()
        defer { browser.retire() }
        var source = DiscoverySourceFixture(base: base, categories: "[{\"title\":\"Dynamic options\",\"url\":\"@js:listingRule\"}]")
        source.jsLib = "var listingRule='" + base + "/discover/dynamic-options?order=<Order(Broken:broken,Working:working)>';"
        try await importSource(source, into: engine)
        browser.openSource(base); try await wait { browser.update?.phase == .categories }
        try await choose(browser)
        XCTAssertEqual(browser.update?.failure?.code, .network)
        XCTAssertTrue(browser.books.isEmpty)
        let option = try XCTUnwrap(browser.options.first, "A failed first request must retain options exposed by URL resolution")
        XCTAssertEqual(option.name, "Order")
        let working = try XCTUnwrap(option.choices.first { $0.value == "working" })
        browser.selectOption(option, choice: working)
        try await wait { !browser.loading && !browser.commandPending }
        XCTAssertNil(browser.failure)
        XCTAssertEqual(browser.books.map(\.title), ["working"])
    }

    func testCategoryReplacementWhileDynamicUrlResolvesCannotRestoreOldOptions() async throws {
        let (engine, browser, base, _) = try await setup()
        defer { browser.retire() }
        var source = DiscoverySourceFixture(base: base, categories: "[{\"title\":\"Slow options\",\"url\":\"@js:java.ajax('" + base + "/discover/categories');listingRule\"},{\"title\":\"Plain\",\"url\":\"" + base + "/discover/normal?page={{page}}\"}]")
        source.jsLib = "var listingRule='" + base + "/discover/options?order=<Order(Hot:hot,New:new)>';"
        try await importSource(source, into: engine)
        try await control(base, "hold/categories")
        browser.openSource(base); try await wait { browser.categories.count == 2 }
        browser.selectCategory(try XCTUnwrap(browser.categories.first { $0.name == "Slow options" }).id)
        try await wait { browser.loading && !browser.commandPending }
        try await control(base, "entered/categories")
        browser.selectCategory(try XCTUnwrap(browser.categories.first { $0.name == "Plain" }).id)
        try await wait { !browser.loading && !browser.commandPending }
        XCTAssertEqual(browser.books.map(\.title), ["Discovery first"])
        XCTAssertTrue(browser.options.isEmpty)
        try await control(base, "release/categories")
        try await control(base, "completed/categories")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(browser.options.isEmpty, "An obsolete URL resolver must not restore its filters")
        XCTAssertEqual(browser.books.map(\.title), ["Discovery first"])
        XCTAssertNil(browser.failure)
    }

    func testDiscoveryVisibilityPersistsIndependentlyOfSourceEnable() async throws {
        let (engine, browser, base, _) = try await setup()
        defer { browser.retire() }
        _ = await call { engine.setSourceDiscoveryEnabled(ids: [base], enabled: false, completion: $0) }
        try await wait { browser.cancelled }
        let other = try await self.engine(); defer { other.close() }
        let reply = await call { other.listManagedSources(completion: $0) }
        let saved = try XCTUnwrap((reply as? ManagedSourcesReply)?.sources.first { $0.id == base })
        XCTAssertTrue(saved.enabled); XCTAssertFalse(saved.discoveryEnabled); XCTAssertTrue(saved.hasDiscovery)
        let enabled = await call { other.listSources(completion: $0) }
        XCTAssertTrue((enabled as? SourcesReply)?.sources.contains { $0.id == base } == true)
        browser.openSource(base); try await wait { !browser.loading }
        XCTAssertEqual(browser.update?.failure?.code, .unsupported)
    }

    func testDiscoveryBookUsesExistingDetailTrialShelfAndReturnNavigation() async throws {
        let model = ReaderModel(); defer { model.cancel() }
        model.start(); try await wait { model.initialized && !model.busy }
        let base = "http://127.0.0.1:18769/runs/discovery-journey-" + UUID().uuidString
        let source = DiscoverySourceFixture(base: base)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try source.json().write(to: file, atomically: true, encoding: .utf8)
        model.importFile(file); try await wait { !model.busy }
        model.confirmFixtureImport(); try await wait { !model.busy }
        model.navigate(.discovery); try await wait { model.route == .discovery && !model.busy }
        model.discovery.openSource(base); try await wait { model.discovery.update?.phase == .categories }
        try await choose(model.discovery)
        let candidate = try XCTUnwrap(model.discovery.books.first)
        model.select(candidate); try await wait { model.route == .details && !model.busy }
        XCTAssertEqual(model.book?.sourceId, base); XCTAssertEqual(model.book?.id, candidate.id)
        XCTAssertEqual(model.detailReturnRoute, .discovery)
        XCTAssertFalse(model.isShelved)
        model.read(try XCTUnwrap(model.chapters.first)); try await wait { model.route == .reading && !model.busy }
        XCTAssertNil(try XCTUnwrap(model.content).reading, "Unshelved trial must not create a progress-saving session")
        XCTAssertTrue(model.shelf.isEmpty, "Trial reading must not implicitly admit the book")
        model.navigate(.discovery); try await wait { model.route == .discovery && !model.busy }
        XCTAssertEqual(model.discovery.books.map(\.id), [candidate.id])
        XCTAssertTrue(model.discovery.hasNextPage)
        model.select(candidate); try await wait { model.route == .details && !model.busy }
        model.addCurrentBook(); try await wait { !model.busy }
        XCTAssertTrue(model.isShelved)
        model.read(try XCTUnwrap(model.chapters.first)); try await wait { model.route == .reading && !model.busy }
        XCTAssertEqual(model.content?.chapter.sourceId, base)
        model.navigate(.discovery); try await wait { model.route == .discovery && !model.busy }
        XCTAssertEqual(model.discovery.books.map(\.id), [candidate.id])
        XCTAssertNil(model.message)
    }
}
