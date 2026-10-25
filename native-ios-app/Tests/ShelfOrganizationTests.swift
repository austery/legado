import XCTest
import ReaderEngine
import SQLite3
@testable import NativeReader

@MainActor
final class ShelfOrganizationTests: XCTestCase {
    private func settle(_ model: ReaderModel, allowingMessage: Bool = false) async throws {
        let deadline = Date().addingTimeInterval(20)
        while (model.busy || model.searchRunning || model.searchCommandPending) && Date() < deadline {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertFalse(model.busy || model.searchRunning || model.searchCommandPending)
        if !allowingMessage { XCTAssertNil(model.message) }
    }

    private func addBook(_ model: ReaderModel) async throws -> ShelfBookSnapshot {
        let suffix = UUID().uuidString
        let base = "http://127.0.0.1:18769/runs/\(suffix)"
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/sources.json")))
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "class.name@text", with: "class.name@text##$## " + suffix)
            .replacingOccurrences(of: "tag.h1@text", with: "tag.h1@text##$## " + suffix)
            .replacingOccurrences(of: "id.content@text", with: "id.content@text##第##\\n第")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suffix + ".json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        model.importFile(url); try await settle(model)
        model.confirmFixtureImport(); try await settle(model)
        model.searchScope = .selected; model.selectedSourceIDs = [base]; model.query = "Path"; model.search()
        try await settle(model)
        model.select(try XCTUnwrap(model.results.first)); try await settle(model)
        model.addCurrentBook(); try await settle(model)
        let id = try XCTUnwrap(model.book?.id)
        model.showShelf(); try await settle(model)
        return try XCTUnwrap(model.shelf.first { $0.book.id == id })
    }

    func testStaleEditsAndLostAcknowledgementRefreshWithoutDuplicateCreation() async throws {
        var discardNextShelfReply = false
        var discarded = false
        let model = ReaderModel(deliverReply: { _, reply, apply in
            if discardNextShelfReply, reply is ShelfReply {
                discardNextShelfReply = false; discarded = true
                return
            }
            apply(reply)
        })
        model.start(); try await settle(model)
        let name = "Acknowledgement " + UUID().uuidString
        discardNextShelfReply = true
        model.createShelfGroup(name)
        let deadline = Date().addingTimeInterval(20)
        while !discarded && Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertTrue(discarded)
        XCTAssertTrue(model.busy, "The committed reply was deliberately not applied")
        model.cancel(); model.refreshShelf(); try await settle(model)
        XCTAssertEqual(model.shelfGroups.filter { $0.name == name }.count, 1)
        XCTAssertFalse(model.canRetry, "Refreshing committed state must not retain a create retry")
        model.retry()
        XCTAssertEqual(model.shelfGroups.filter { $0.name == name }.count, 1)
        let original = try XCTUnwrap(model.shelfGroups.first { $0.name == name })
        let oldToken = model.shelfToken
        let other = ReaderEngine(); defer { other.close() }
        let ready = await withCheckedContinuation { continuation in
            _ = other.initialize { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(ready is EngineReady)
        let changed = await withCheckedContinuation { continuation in
            _ = other.renameShelfGroup(groupId: original.id, name: name + " updated", expectedToken: oldToken) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(changed is ShelfReply)
        var accepted: Bool?
        model.renameShelfGroup(original, name: "Stale overwrite", expectedToken: oldToken) { accepted = $0 }
        try await settle(model, allowingMessage: true)
        XCTAssertEqual(accepted, false)
        XCTAssertNotNil(model.message)
        XCTAssertEqual(model.shelfGroups.first { $0.id == original.id }?.name, name + " updated")
        XCTAssertNotEqual(model.shelfToken, oldToken)
        model.refreshShelf(); try await settle(model)
        model.deleteShelfGroup(try XCTUnwrap(model.shelfGroups.first { $0.id == original.id }))
        try await settle(model)
    }

    private func copyDatabase(from source: URL, to destination: URL) throws {
        var sourceConnection: OpaquePointer?
        var destinationConnection: OpaquePointer?
        guard sqlite3_open_v2(source.path, &sourceConnection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let sourceConnection else {
            if let sourceConnection { sqlite3_close(sourceConnection) }
            throw NSError(domain: "SyntheticSnapshot", code: 1)
        }
        defer { sqlite3_close(sourceConnection) }
        guard sqlite3_open_v2(destination.path, &destinationConnection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let destinationConnection else {
            if let destinationConnection { sqlite3_close(destinationConnection) }
            throw NSError(domain: "SyntheticSnapshot", code: 2)
        }
        defer { sqlite3_close(destinationConnection) }
        sqlite3_busy_timeout(destinationConnection, 5_000)
        guard let backup = sqlite3_backup_init(destinationConnection, "main", sourceConnection, "main") else {
            throw NSError(domain: "SyntheticSnapshot", code: 3)
        }
        let copied = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard copied == SQLITE_DONE, finished == SQLITE_OK else {
            throw NSError(domain: "SyntheticSnapshot", code: Int(copied), userInfo: [
                NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(destinationConnection))
            ])
        }
    }

    func testSyntheticSnapshotRestoresGroupsMembershipAndSavedReadingPosition() async throws {
        let model = ReaderModel()
        model.start(); try await settle(model)
        let entry = try await addBook(model)
        model.openShelfBook(entry); try await settle(model)
        model.read(model.chapters[1]); try await settle(model)
        let content = try XCTUnwrap(model.content)
        let token = try XCTUnwrap(content.reading?.token)
        let body = content.text as NSString
        let marker = body.range(of: "第80段")
        guard marker.location != NSNotFound else { XCTFail("Expected the controlled chapter paragraph"); return }
        let offset = body.paragraphRange(for: marker).location
        XCTAssertGreaterThan(offset, 0)
        model.readingDisplayed(token, offset); model.readingScrolled(token, offset)
        model.showShelf(); try await settle(model)
        let name = "Snapshot " + UUID().uuidString
        model.createShelfGroup(name); try await settle(model)
        let group = try XCTUnwrap(model.shelfGroups.first { $0.name == name })
        model.changeShelfGroups([entry], add: [group.id], remove: []); try await settle(model)
        let before = model.shelfToken
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let database = documents.appendingPathComponent("legado.db")
        let snapshot = documents.appendingPathComponent("synthetic-shelf-" + UUID().uuidString + ".db")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: snapshot.path + suffix)
            }
        }
        try copyDatabase(from: database, to: snapshot)
        XCTAssertGreaterThan((try snapshot.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0, 0)
        // Change progress as well as organization so restoration must recover both.
        model.read(model.chapters[0]); try await settle(model)
        let changedToken = try XCTUnwrap(model.content?.reading?.token)
        model.readingDisplayed(changedToken, 0); model.readingScrolled(changedToken, 0)
        model.showShelf(); try await settle(model)
        model.deleteShelfGroup(group); try await settle(model)
        model.removeShelfBooks([entry]); try await settle(model)
        XCTAssertFalse(model.shelf.contains { $0.book.id == entry.book.id })
        XCTAssertFalse(model.shelfGroups.contains { $0.id == group.id })
        try copyDatabase(from: snapshot, to: database)
        model.refreshShelf(); try await settle(model)
        XCTAssertEqual(model.shelfToken, before)
        XCTAssertEqual(model.shelfGroups.first { $0.id == group.id }?.name, name)
        let restored = try XCTUnwrap(model.shelf.first { $0.book.id == entry.book.id })
        XCTAssertEqual(restored.groupIds, [group.id])
        XCTAssertEqual(restored.book.sourceId, entry.book.sourceId)
        model.openShelfBook(restored); try await settle(model)
        XCTAssertEqual(model.content?.chapter.index, 1)
        XCTAssertEqual(model.content?.reading?.paragraphUtf16Offset, Int32(offset))
        XCTAssertTrue(model.content?.fromCache == true)
        print("BOOKSHELF_SNAPSHOT_RESTORE: groups, membership, source and chapter/paragraph restored from an actual SQLite backup")
        model.showShelf(); try await settle(model)
        model.deleteShelfGroup(group); try await settle(model)
    }

    func testOneBookAppearsInTwoGroupsAndReturnsUngroupedWithoutChangingItsReadingIdentity() async throws {
        let model = ReaderModel()
        model.start(); try await settle(model)
        let entry = try await addBook(model)
        let suffix = UUID().uuidString
        model.createShelfGroup("Later " + suffix); try await settle(model)
        model.createShelfGroup("Fiction " + suffix); try await settle(model)
        let first = try XCTUnwrap(model.shelfGroups.first { $0.name == "Later " + suffix })
        let second = try XCTUnwrap(model.shelfGroups.first { $0.name == "Fiction " + suffix })
        model.changeShelfGroups([entry], add: [first.id, second.id], remove: []); try await settle(model)
        XCTAssertFalse(model.visibleShelfBooks.contains { $0.book.id == entry.book.id })
        model.openShelfGroup(first.id)
        XCTAssertEqual(model.visibleShelfBooks.map(\.book.id), [entry.book.id])
        model.changeShelfGroups([entry], add: [], remove: [first.id]); try await settle(model)
        XCTAssertTrue(model.visibleShelfBooks.isEmpty)
        model.openShelfGroup(second.id)
        let grouped = try XCTUnwrap(model.visibleShelfBooks.first)
        XCTAssertEqual(grouped.book.sourceId, entry.book.sourceId)
        model.openShelfBook(grouped); try await settle(model)
        model.showShelf(); try await settle(model)
        XCTAssertEqual(model.shelfGroupID, second.id)
        model.deleteShelfGroup(second); try await settle(model)
        XCTAssertNil(model.shelfGroupID)
        XCTAssertTrue(model.visibleShelfBooks.contains { $0.book.id == entry.book.id })
        model.deleteShelfGroup(first); try await settle(model)
    }

    func testGroupsCanBeCreatedRenamedAndDeletedWithoutSourceAccess() async throws {
        let model = ReaderModel()
        model.start(); try await settle(model)
        let name = "Shelf " + UUID().uuidString
        model.createShelfGroup(name); try await settle(model)
        let group = try XCTUnwrap(model.shelfGroups.first { $0.name == name })
        XCTAssertEqual(group.bookCount, 0)
        model.openShelfGroup(group.id)
        XCTAssertEqual(model.shelfGroupID, group.id)
        XCTAssertTrue(model.visibleShelfBooks.isEmpty)
        model.renameShelfGroup(group, name: name + " renamed"); try await settle(model)
        XCTAssertEqual(model.currentShelfGroup?.name, name + " renamed")
        model.deleteShelfGroup(group); try await settle(model)
        XCTAssertNil(model.shelfGroupID)
        XCTAssertFalse(model.shelfGroups.contains { $0.id == group.id })
    }
}
