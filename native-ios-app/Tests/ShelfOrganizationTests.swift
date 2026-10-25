import XCTest
import ReaderEngine
@testable import NativeReader

@MainActor
final class ShelfOrganizationTests: XCTestCase {
    private func settle(_ model: ReaderModel) async throws {
        let deadline = Date().addingTimeInterval(20)
        while (model.busy || model.searchRunning || model.searchCommandPending) && Date() < deadline {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertFalse(model.busy || model.searchRunning || model.searchCommandPending)
        XCTAssertNil(model.message)
    }

    private func addBook(_ model: ReaderModel) async throws -> ShelfBookSnapshot {
        let suffix = UUID().uuidString
        let base = "http://127.0.0.1:18769/runs/\(suffix)"
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/sources.json")))
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "class.name@text", with: "class.name@text##$## " + suffix)
            .replacingOccurrences(of: "tag.h1@text", with: "tag.h1@text##$## " + suffix)
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
