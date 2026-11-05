import XCTest
import ReaderEngine
import SQLite3

@MainActor
final class ShelfGroupEngineTests: XCTestCase {
    private func call(_ start: (@escaping (EngineReply) -> Void) -> EngineRequest) async -> EngineReply {
        await withCheckedContinuation { continuation in
            _ = start { continuation.resume(returning: $0) }
        }
    }

    private func shelf(_ engine: ReaderEngine) async throws -> ShelfReply {
        let reply = await call { engine.listShelf(completion: $0) }
        return try XCTUnwrap(reply as? ShelfReply, "\(reply)")
    }

    private func fixture(_ engine: ReaderEngine) async throws -> (BookSnapshot, ContentReply) {
        let ready = await call { engine.initialize(completion: $0) }
        XCTAssertTrue(ready is EngineReady)
        let base = "http://127.0.0.1:18769/runs/\(UUID().uuidString)"
        let suffix = UUID().uuidString
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/sources.json")))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "class.name@text", with: "class.name@text##$## " + suffix)
            .replacingOccurrences(of: "tag.h1@text", with: "tag.h1@text##$## " + suffix)
            .replacingOccurrences(of: "id.content@text", with: "id.content@text##C1-MIDDLE##\\nC1-MIDDLE")
        let imported = await call { engine.importSources(json: json, completion: $0) }
        XCTAssertTrue(imported is SourcesReply)
        let searched = await call { engine.search(sourceId: base, query: "Path", page: 1, completion: $0) }
        let book = try XCTUnwrap((searched as? SearchReply)?.books.first)
        let detail = await call { engine.loadBook(sourceId: base, bookId: book.id, completion: $0) }
        XCTAssertTrue(detail is BookReply)
        let toc = await call { engine.loadToc(sourceId: base, bookId: book.id, completion: $0) }
        let chapter = try XCTUnwrap((toc as? TocReply)?.chapters.first)
        let added = await call { engine.addToShelf(sourceId: base, bookId: book.id, completion: $0) }
        XCTAssertTrue(added is ShelfEntryReply)
        let loaded = await call { engine.loadChapter(sourceId: base, bookId: book.id, chapterId: chapter.id,
            cacheOnly: false, completion: $0) }
        return (book, try XCTUnwrap(loaded as? ContentReply))
    }

    private func fixtureSQL(_ statement: String) throws {
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("legado.db").path
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let database = try XCTUnwrap(connection)
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        XCTAssertEqual(sqlite3_exec(database, statement, nil, nil, nil), SQLITE_OK,
            String(cString: sqlite3_errmsg(database)))
    }

    func testSharedShelfSortPreservesGroupsAndReadingPosition() async throws {
        let engine = ReaderEngine()
        defer { engine.close() }
        let (first, _) = try await fixture(engine)
        let (second, _) = try await fixture(engine)
        let (third, content) = try await fixture(engine)
        let books = [first, second, third]
        let ids = books.map(\.id)
        let reading = try XCTUnwrap(content.reading)
        let offset = (content.text as NSString).range(of: "C1-MIDDLE").location
        XCTAssertNotEqual(offset, NSNotFound)
        XCTAssertGreaterThan(offset, 0)
        let savedReply: EngineReply = await withCheckedContinuation { continuation in
            engine.saveReadingPosition(token: reading.token, eventSequence: 1,
                utf16Offset: Int32(offset)) { continuation.resume(returning: $0) }
        }
        let saved = try XCTUnwrap(savedReply as? ReadingSaved)
        var state = try await shelf(engine)
        let originalMode = state.sortMode
        do {
            let titles = ["北京", "广州", "上海"]
            let authors = ["张", "王", "李"]
            let readTimes = [30, 10, 20], updateTimes = [10, 40, 20], orders = [1, 2, 0]
            for index in books.indices {
                let escapedID = ids[index].replacingOccurrences(of: "'", with: "''")
                try fixtureSQL("UPDATE books SET name='\(titles[index])', author='\(authors[index])', durChapterTime=\(readTimes[index]), latestChapterTime=\(updateTimes[index]), `order`=\(orders[index]) WHERE bookUrl='\(escapedID)'")
            }
            let suffix = UUID().uuidString
            let created = await call { engine.createShelfGroup(name: "Sorted " + suffix,
                expectedToken: state.token, completion: $0) }
            state = try XCTUnwrap(created as? ShelfReply)
            let overridden = try XCTUnwrap(state.groups.first { $0.name == "Sorted " + suffix })
            let inheritedReply = await call { engine.createShelfGroup(name: "Inherited " + suffix,
                expectedToken: state.token, completion: $0) }
            state = try XCTUnwrap(inheritedReply as? ShelfReply)
            let inherited = try XCTUnwrap(state.groups.first { $0.name == "Inherited " + suffix })
            let targets = books.map { ShelfBookTarget(sourceId: $0.sourceId, bookId: $0.id) }
            let membership = await call { engine.changeShelfGroups(targets: targets,
                addGroupIds: [overridden.id, inherited.id], removeGroupIds: [],
                expectedToken: state.token, completion: $0) }
            state = try XCTUnwrap(membership as? ShelfReply)
            let groupID = try XCTUnwrap(Int64(overridden.id))
            try fixtureSQL("UPDATE book_groups SET bookSort=2 WHERE groupId=\(groupID)")
            let expected = [[0, 2, 1], [1, 2, 0], [0, 1, 2], [2, 0, 1], [1, 0, 2], [2, 1, 0]]
            for mode in expected.indices {
                let changed = await call { engine.setShelfSort(mode: Int32(mode), completion: $0) }
                let reply = try XCTUnwrap(changed as? ShelfReply)
                let orderedIDs = expected[mode].map { ids[$0] }
                XCTAssertEqual(reply.sortMode, Int32(mode))
                XCTAssertEqual(reply.token, state.token)
                XCTAssertEqual(reply.books.map { $0.book.id }.filter { ids.contains($0) }, orderedIDs)
                let fixed = try XCTUnwrap(reply.groups.first { $0.id == overridden.id })
                let following = try XCTUnwrap(reply.groups.first { $0.id == inherited.id })
                XCTAssertFalse(fixed.inheritsSort)
                XCTAssertEqual(fixed.orderedBookIds, ids)
                XCTAssertTrue(following.inheritsSort)
                XCTAssertEqual(following.orderedBookIds, orderedIDs)
            }
            let invalid = await call { engine.setShelfSort(mode: 99, completion: $0) }
            XCTAssertEqual((invalid as? EngineFailure)?.code, .invalidInput)
            let unchanged = try await shelf(engine)
            XCTAssertEqual(unchanged.sortMode, 5)
            XCTAssertEqual(unchanged.token, state.token)
            let reopened = await call { engine.openReading(sourceId: third.sourceId,
                bookId: third.id, cacheOnly: true, completion: $0) }
            XCTAssertEqual((reopened as? ContentReply)?.reading?.paragraphUtf16Offset, saved.paragraphUtf16Offset)
            let removed = await call { engine.removeFromShelf(sourceId: third.sourceId,
                bookId: third.id, completion: $0) }
            XCTAssertTrue(removed is ShelfRemoved)
            let remaining = try await shelf(engine)
            XCTAssertFalse(remaining.books.contains { $0.book.id == third.id })
            XCTAssertTrue(remaining.groups.allSatisfy { !$0.orderedBookIds.contains(third.id) })
            for group in [overridden, inherited] {
                state = try await shelf(engine)
                _ = await call { engine.deleteShelfGroup(groupId: group.id, expectedToken: state.token, completion: $0) }
            }
        } catch {
            _ = await call { engine.setShelfSort(mode: originalMode, completion: $0) }
            throw error
        }
        _ = await call { engine.setShelfSort(mode: originalMode, completion: $0) }
    }

    func testGroupLifecycleAndShelfReadmissionPreserveOneReadingRecord() async throws {
        let engine = ReaderEngine()
        defer { engine.close() }
        let (book, content) = try await fixture(engine)
        let reading = try XCTUnwrap(content.reading)
        let offset = (content.text as NSString).range(of: "C1-MIDDLE").location
        XCTAssertNotEqual(offset, NSNotFound)
        XCTAssertGreaterThan(offset, 0)
        let savedReply: EngineReply = await withCheckedContinuation { continuation in
            engine.finishReading(token: reading.token, eventSequence: 1, utf16Offset: Int32(offset)) {
                continuation.resume(returning: $0)
            }
        }
        let saved = try XCTUnwrap(savedReply as? ReadingSaved)
        var state = try await shelf(engine)
        let suffix = UUID().uuidString
        let firstReply = await call { engine.createShelfGroup(name: "Growing " + suffix,
            expectedToken: state.token, completion: $0) }
        state = try XCTUnwrap(firstReply as? ShelfReply)
        let first = try XCTUnwrap(state.groups.first { $0.name == "Growing " + suffix })
        let secondReply = await call { engine.createShelfGroup(name: "Reading " + suffix,
            expectedToken: state.token, completion: $0) }
        state = try XCTUnwrap(secondReply as? ShelfReply)
        let second = try XCTUnwrap(state.groups.first { $0.name == "Reading " + suffix })
        let target = ShelfBookTarget(sourceId: book.sourceId, bookId: book.id)
        let changed = await call { engine.changeShelfGroups(targets: [target], addGroupIds: [first.id, second.id],
            removeGroupIds: [], expectedToken: state.token, completion: $0) }
        state = try XCTUnwrap(changed as? ShelfReply)
        XCTAssertEqual(Set(try XCTUnwrap(state.books.first { $0.book.id == book.id }).groupIds), Set([first.id, second.id]))
        XCTAssertEqual(state.groups.first { $0.id == first.id }?.bookCount, 1)
        XCTAssertEqual(state.groups.first { $0.id == second.id }?.bookCount, 1)
        let duplicate = await call { engine.addToShelf(sourceId: book.sourceId, bookId: book.id, completion: $0) }
        XCTAssertEqual(Set(try XCTUnwrap(duplicate as? ShelfEntryReply).entry.groupIds), Set([first.id, second.id]))
        let tokenBeforeRename = state.token
        let renamed = await call { engine.renameShelfGroup(groupId: first.id, name: "Later " + suffix,
            expectedToken: state.token, completion: $0) }
        state = try XCTUnwrap(renamed as? ShelfReply)
        let stale = await call { engine.deleteShelfGroup(groupId: first.id, expectedToken: tokenBeforeRename, completion: $0) }
        XCTAssertEqual((stale as? EngineFailure)?.code, .staleUpdate)
        let removedMembership = await call { engine.changeShelfGroups(targets: [target], addGroupIds: [],
            removeGroupIds: [first.id], expectedToken: state.token, completion: $0) }
        state = try XCTUnwrap(removedMembership as? ShelfReply)
        XCTAssertEqual(state.books.first { $0.book.id == book.id }?.groupIds, [second.id])
        let deleted = await call { engine.deleteShelfGroup(groupId: second.id, expectedToken: state.token, completion: $0) }
        state = try XCTUnwrap(deleted as? ShelfReply)
        XCTAssertEqual(state.books.first { $0.book.id == book.id }?.groupIds, [])
        let regrouped = await call { engine.changeShelfGroups(targets: [target], addGroupIds: [first.id],
            removeGroupIds: [], expectedToken: state.token, completion: $0) }
        state = try XCTUnwrap(regrouped as? ShelfReply)
        let removed = await call { engine.removeShelfBooks(targets: [target], expectedToken: state.token, completion: $0) }
        state = try XCTUnwrap(removed as? ShelfReply)
        XCTAssertFalse(state.books.contains { $0.book.id == book.id })
        let readmitted = await call { engine.addToShelf(sourceId: book.sourceId, bookId: book.id, completion: $0) }
        XCTAssertEqual(try XCTUnwrap(readmitted as? ShelfEntryReply).entry.groupIds, [])
        let reopened = await call { engine.openReading(sourceId: book.sourceId, bookId: book.id, cacheOnly: true, completion: $0) }
        let restored = try XCTUnwrap(reopened as? ContentReply)
        XCTAssertEqual(restored.reading?.paragraphUtf16Offset, saved.paragraphUtf16Offset)
        XCTAssertTrue(restored.fromCache)
        state = try await shelf(engine)
        let cleanup = await call { engine.deleteShelfGroup(groupId: first.id, expectedToken: state.token, completion: $0) }
        XCTAssertTrue(cleanup is ShelfReply)
    }

    func testInvalidBatchTargetsAndGroupIdentifiersLeaveCommittedShelfUnchanged() async throws {
        let engine = ReaderEngine()
        defer { engine.close() }
        let (book, _) = try await fixture(engine)
        let initial = try await shelf(engine)
        let blank = await call { engine.createShelfGroup(name: "  ", expectedToken: initial.token, completion: $0) }
        XCTAssertEqual((blank as? EngineFailure)?.code, .invalidInput)
        let invalidGroup = await call { engine.deleteShelfGroup(groupId: "-9223372036854775808",
            expectedToken: initial.token, completion: $0) }
        XCTAssertEqual((invalidGroup as? EngineFailure)?.code, .invalidInput)
        let targets = [ShelfBookTarget(sourceId: book.sourceId, bookId: book.id),
            ShelfBookTarget(sourceId: "wrong-source", bookId: book.id)]
        let failed = await call { engine.removeShelfBooks(targets: targets, expectedToken: initial.token, completion: $0) }
        XCTAssertEqual((failed as? EngineFailure)?.code, .identityConflict)
        let after = try await shelf(engine)
        XCTAssertEqual(after.token, initial.token)
        XCTAssertTrue(after.books.contains { $0.book.id == book.id })
    }
}
