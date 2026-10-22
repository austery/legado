import XCTest
import ReaderEngine
import SQLite3

@MainActor
final class SourceManagementTests: XCTestCase {
    private func call(_ action: (@escaping (EngineReply) -> Void) -> EngineRequest) async -> EngineReply {
        await withCheckedContinuation { continuation in _ = action { continuation.resume(returning: $0) } }
    }
    private func engine() async throws -> ReaderEngine {
        let engine = ReaderEngine()
        let reply = await call { engine.initialize(completion: $0) }
        XCTAssertTrue(reply is EngineReady)
        return engine
    }
    private func source(_ id: String, name: String = "Original", updated: Int = 1,
                        enabled: Bool = true, group: String = "Local") -> String {
        """
        {"bookSourceUrl":"\(id)","bookSourceName":"\(name)","lastUpdateTime":\(updated),
         "enabled":\(enabled),"enabledExplore":false,"bookSourceGroup":"\(group)","customOrder":42,
         "header":"{\\"X-Test\\":\\"kept\\"}","searchUrl":"/search?key={{key}}","ruleSearch":{"bookList":"tag.article","name":"tag.a@text"},"enableDangerousApi":true}
        """
    }
    private func list(_ engine: ReaderEngine) async throws -> [ManagedSource] {
        let reply = await call { engine.listManagedSources(completion: $0) }
        return try XCTUnwrap(reply as? ManagedSourcesReply).sources
    }
    private func sql(_ statement: String) throws {
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("legado.db").path
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let db = try XCTUnwrap(connection); defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, statement, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    func testPreviewCancellationAndMalformedInputNeverWriteSources() async throws {
        let engine = try await engine(); defer { engine.close() }
        let id = "https://preview-\(UUID().uuidString).invalid"
        let preview = await call { engine.previewSourceImport(json: source(id), completion: $0) }
        XCTAssertTrue(preview is SourceImportPreview)
        let before = try await list(engine)
        XCTAssertFalse(before.contains { $0.id == id })
        _ = await call { engine.cancelSourceImport(completion: $0) }
        let invalid = await call { engine.previewSourceImport(json: "[{", completion: $0) }
        XCTAssertTrue(invalid is EngineFailure)
        let after = try await list(engine)
        XCTAssertFalse(after.contains { $0.id == id })
    }

    func testUpstreamDefaultsDuplicateWinnerRetentionAndExportRoundTrip() async throws {
        let engine = try await engine(); defer { engine.close() }
        let id = "https://retain-\(UUID().uuidString).invalid"
        _ = await call { engine.importSources(json: source(id, enabled: false), completion: $0) }
        let json = "[\(source(id, name: "First", updated: 2)),\(source(id, name: "Last", updated: 3, group: "Incoming"))]"
        let reply = await call { engine.previewSourceImport(json: json, completion: $0) }
        let preview = try XCTUnwrap(reply as? SourceImportPreview)
        let item = try XCTUnwrap(preview.items.first)
        XCTAssertEqual(item.kind, .newer); XCTAssertTrue(item.selectedByDefault)
        XCTAssertEqual(item.duplicateCount, 1); XCTAssertEqual(item.source.name, "Last")
        let committed = await call { engine.commitSourceImport(token: preview.token, ids: [id],
            keepName: true, keepGroups: true, keepEnabled: true, completion: $0) }
        XCTAssertTrue(committed is SourceImportCommitted)
        let sources = try await list(engine)
        let retained = try XCTUnwrap(sources.first { $0.id == id })
        XCTAssertEqual(retained.name, "Original"); XCTAssertEqual(retained.groups, ["Local"])
        XCTAssertFalse(retained.enabled); XCTAssertEqual(retained.updatedAt, 3)
        let exported = await call { engine.exportSources(ids: [id], completion: $0) }
        let text = try XCTUnwrap(exported as? SourceExportReply).json
        struct Exported: Decodable, Equatable {
            let bookSourceUrl: String
            let bookSourceName: String
            let bookSourceGroup: String?
            let enabled: Bool
            let header: String?
            let customOrder: Int
            let enabledExplore: Bool
            let enableDangerousApi: Bool?
            let searchUrl: String?
            let ruleSearch: String?
        }
        let object = try XCTUnwrap(JSONDecoder().decode([Exported].self, from: Data(text.utf8)).first)
        XCTAssertEqual(object.header, "{\"X-Test\":\"kept\"}")
        XCTAssertEqual(object.customOrder, 42)
        XCTAssertEqual(object.enabledExplore, false)
        XCTAssertNotEqual(object.enableDangerousApi, true)
        XCTAssertEqual(object.searchUrl, "/search?key={{key}}")
        let ruleJSON = try XCTUnwrap(object.ruleSearch)
        let rules = try JSONDecoder().decode([String: String].self, from: Data(ruleJSON.utf8))
        XCTAssertEqual(rules["bookList"], "tag.article")
        XCTAssertEqual(rules["name"], "tag.a@text")
        let roundTrip = await call { engine.previewSourceImport(json: text, completion: $0) }
        let imported = try XCTUnwrap(roundTrip as? SourceImportPreview)
        XCTAssertEqual(imported.items.first?.kind, .existing)
        XCTAssertFalse(try XCTUnwrap(imported.items.first).selectedByDefault)
        let restored = await call { engine.commitSourceImport(token: imported.token, ids: [id],
            keepName: false, keepGroups: false, keepEnabled: false, completion: $0) }
        XCTAssertTrue(restored is SourceImportCommitted)
        let reexported = await call { engine.exportSources(ids: [id], completion: $0) }
        let restoredJSON = try XCTUnwrap(reexported as? SourceExportReply).json
        let restoredObject = try XCTUnwrap(JSONDecoder().decode([Exported].self, from: Data(restoredJSON.utf8)).first)
        XCTAssertEqual(restoredObject, object)
    }

    func testReviewSelectedImportIgnoresUnselectedConflict() async throws {
        let first = try await engine(); let second = try await engine()
        defer { first.close(); second.close() }
        let prefix = "https://selection-\(UUID().uuidString).invalid"
        let a = prefix + "/a", b = prefix + "/b"
        _ = await call { first.importSources(json: "[\(source(a)),\(source(b))]", completion: $0) }
        let reply = await call { first.previewSourceImport(
            json: "[\(source(a, updated: 2)),\(source(b, updated: 2))]", completion: $0) }
        let preview = try XCTUnwrap(reply as? SourceImportPreview)
        _ = await call { second.setSourcesEnabled(ids: [b], enabled: false, completion: $0) }
        let result = await call { first.commitSourceImport(token: preview.token, ids: [a],
            keepName: true, keepGroups: true, keepEnabled: true, completion: $0) }
        XCTAssertEqual((result as? SourceImportCommitted)?.count, 1)
        let current = try await list(second)
        let selected = try XCTUnwrap(current.first { $0.id == a })
        let unselected = try XCTUnwrap(current.first { $0.id == b })
        XCTAssertEqual(selected.updatedAt, 2)
        XCTAssertTrue(selected.enabled)
        XCTAssertEqual(unselected.updatedAt, 1)
        XCTAssertFalse(unselected.enabled)
    }

    func testStaleConfirmationRejectsChangesFromAnotherEngine() async throws {
        let first = try await engine(); let second = try await engine()
        defer { first.close(); second.close() }
        let id = "https://stale-\(UUID().uuidString).invalid"
        _ = await call { first.importSources(json: source(id), completion: $0) }
        let reply = await call { first.previewSourceImport(json: source(id, updated: 2), completion: $0) }
        let preview = try XCTUnwrap(reply as? SourceImportPreview)
        _ = await call { second.setSourcesEnabled(ids: [id], enabled: false, completion: $0) }
        let result = await call { first.commitSourceImport(token: preview.token, ids: [id],
            keepName: false, keepGroups: false, keepEnabled: false, completion: $0) }
        XCTAssertEqual((result as? EngineFailure)?.code, .staleUpdate)
        let current = try await list(second)
        let unchanged = try XCTUnwrap(current.first { $0.id == id })
        XCTAssertFalse(unchanged.enabled); XCTAssertEqual(unchanged.updatedAt, 1)
    }

    func testImportPersistenceFailureRollsBackEverySelectedSource() async throws {
        let engine = try await engine(); defer { engine.close() }
        let prefix = "https://rollback-\(UUID().uuidString).invalid"
        let a = prefix + "/a", b = prefix + "/b"
        let reply = await call { engine.previewSourceImport(json: "[\(source(a)),\(source(b))]", completion: $0) }
        let preview = try XCTUnwrap(reply as? SourceImportPreview)
        try sql("CREATE TRIGGER source_import_failure BEFORE INSERT ON book_sources WHEN NEW.bookSourceUrl = '\(b)' BEGIN SELECT RAISE(ABORT, 'injected source import failure'); END")
        defer { try? sql("DROP TRIGGER source_import_failure") }
        let result = await call { engine.commitSourceImport(token: preview.token, ids: [a, b],
            keepName: true, keepGroups: true, keepEnabled: true, completion: $0) }
        XCTAssertTrue(result is EngineFailure)
        let current = try await list(engine)
        XCTAssertFalse(current.contains { $0.id == a || $0.id == b })
    }

    func testGroupAndEnableChangesPersistAcrossEngineSessions() async throws {
        let first = try await engine(); defer { first.close() }
        let id = "https://groups-\(UUID().uuidString).invalid"
        _ = await call { first.importSources(json: source(id, group: "Local；Legacy"), completion: $0) }
        for _ in 0..<2 { _ = await call { first.changeSourceGroup(ids: [id], group: "  Favorites  ", add: true, completion: $0) } }
        _ = await call { first.changeSourceGroup(ids: [id], group: "Local", add: false, completion: $0) }
        _ = await call { first.setSourcesEnabled(ids: [id], enabled: false, completion: $0) }
        let second = try await engine(); defer { second.close() }
        let persisted = try await list(second)
        let source = try XCTUnwrap(persisted.first { $0.id == id })
        XCTAssertEqual(source.groups, ["Legacy", "Favorites"]); XCTAssertFalse(source.enabled)
        let enabledReply = await call { second.listSources(completion: $0) }
        XCTAssertFalse(try XCTUnwrap(enabledReply as? SourcesReply).sources.contains { $0.id == id })
    }
}
