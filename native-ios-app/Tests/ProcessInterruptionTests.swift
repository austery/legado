import XCTest
import ReaderEngine
import CryptoKit
import SQLite3
import Darwin

/// Explicit external termination gates, enabled only by the disposable-simulator driver.
@MainActor
final class ProcessInterruptionTests: XCTestCase {
    private enum GateFailure: Error { case invalid(String) }
    private func requireGate(_ condition: Bool, _ message: String) throws {
        guard condition else { throw GateFailure.invalid(message) }
    }
    private struct Manifest: Codable {
        let processID: Int32
        let phase: String
        let sourceID: String
        let bookID: String
        let oldChapterID: String
        let newChapterID: String
        let oldHash: String
        let newHash: String
        let oldRevision: Int64
        let newOffset: Int32
        let oldCachePath: String
        let newCachePath: String
        let group: GroupDeletion?
    }
    private struct GroupDeletion: Codable {
        let removedID: String
        let retainedID: String
        let groupIDsBefore: [String]
        let token: String
    }
    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var run: String { ProcessInfo.processInfo.environment["SPEC003_INTERRUPT_RUN"] ?? "" }
    private func file(_ suffix: String) -> URL { documents.appendingPathComponent("spec003-interrupt-\(run).\(suffix)") }
    private func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func call(_ start: (@escaping (EngineReply) -> Void) -> EngineRequest) async -> EngineReply {
        await withCheckedContinuation { continuation in _ = start { continuation.resume(returning: $0) } }
    }
    private func organization(_ start: (@escaping (EngineReply) -> Void) -> EngineRequest) async throws -> ShelfReply {
        let reply = await call(start)
        return try XCTUnwrap(reply as? ShelfReply)
    }
    private func write(_ start: (@escaping (EngineReply) -> Void) -> Void) async -> EngineReply {
        await withCheckedContinuation { continuation in start { continuation.resume(returning: $0) } }
    }
    private func cacheURL(_ book: BookSnapshot, _ chapter: ChapterSnapshot) -> URL {
        func shortHash(_ value: String) -> String {
            let full = Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
            return String(full.dropFirst(8).prefix(16))
        }
        return documents.appendingPathComponent("book_cache")
            .appendingPathComponent(String(book.title.prefix(9)) + shortHash(book.id))
            .appendingPathComponent(String(format: "%05d", chapter.index) + "-" + shortHash(chapter.title) + ".nb")
    }
    private func openSQL(readOnly: Bool = false) throws -> OpaquePointer {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(documents.appendingPathComponent("legado.db").path, &database,
            readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE, nil)
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw GateFailure.invalid("Unable to open the existing fixture database")
        }
        return database
    }
    private func revision(_ bookID: String) throws -> Int64 {
        let database = try openSQL(readOnly: true)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        try requireGate(sqlite3_prepare_v2(database, "SELECT revision FROM native_reading_resume WHERE bookUrl = ?", -1, &statement, nil) == SQLITE_OK, "Unable to prepare the fixture revision query")
        defer { sqlite3_finalize(statement) }
        let query = try XCTUnwrap(statement)
        return try bookID.withCString { pointer in
            try requireGate(sqlite3_bind_text(query, 1, pointer, -1, nil) == SQLITE_OK, "Unable to bind the exact fixture book")
            try requireGate(sqlite3_step(query) == SQLITE_ROW, "Expected an existing fixture resume row")
            return sqlite3_column_int64(query, 0)
        }
    }

    private func storedInteger(_ query: String, binding: String) throws -> Int64 {
        let database = try openSQL(readOnly: true)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        try requireGate(sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
                        "Unable to prepare group boundary observation")
        defer { sqlite3_finalize(statement) }
        let prepared = try XCTUnwrap(statement)
        return try binding.withCString { pointer in
            try requireGate(sqlite3_bind_text(prepared, 1, pointer, -1, nil) == SQLITE_OK, "Unable to bind group boundary identity")
            try requireGate(sqlite3_step(prepared) == SQLITE_ROW, "Group boundary observation returned no record")
            return sqlite3_column_int64(prepared, 0)
        }
    }
    private func groupMask(_ bookID: String) throws -> Int64 {
        try storedInteger("SELECT `group` FROM books WHERE bookUrl = ?", binding: bookID)
    }
    private func groupExists(_ id: String) throws -> Bool {
        try storedInteger("SELECT count(*) FROM book_groups WHERE groupId = ?", binding: id) == 1
    }

    func testPrepareInterruption() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPEC003_INTERRUPT_MODE"] == "prepare")
        _ = try XCTUnwrap(UUID(uuidString: run))
        let phase = try XCTUnwrap(ProcessInfo.processInfo.environment["SPEC003_INTERRUPT_CASE"])
        try requireGate(["before-file", "after-file", "before-db", "after-db", "group-before-db", "group-after-db"].contains(phase), "Unknown interruption boundary")
        let isGroupDeletion = phase.hasPrefix("group-")
        let engine = ReaderEngine()
        let ready = await call { engine.initialize(completion: $0) }
        XCTAssertTrue(ready is EngineReady)
        let base = "http://127.0.0.1:18771/runs/\(run)"
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/sources.json")))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "class.name@text", with: "class.name@text##$## " + run)
            .replacingOccurrences(of: "tag.h1@text", with: "tag.h1@text##$## " + run)
            .replacingOccurrences(of: "id.content@text", with: "id.content@text##MIDDLE##\\nMIDDLE")
        let imported = await call { engine.importSources(json: json, completion: $0) }
        XCTAssertTrue(imported is SourcesReply)
        let search = await call { engine.search(sourceId: base, query: "Path", page: 1, completion: $0) }
        let book = try XCTUnwrap((search as? SearchReply)?.books.first)
        _ = await call { engine.loadBook(sourceId: base, bookId: book.id, completion: $0) }
        let tocReply = await call { engine.loadToc(sourceId: base, bookId: book.id, completion: $0) }
        let chapters = try XCTUnwrap(tocReply as? TocReply).chapters
        _ = await call { engine.addToShelf(sourceId: base, bookId: book.id, completion: $0) }
        let oldReply = await call { engine.loadChapter(sourceId: base, bookId: book.id, chapterId: chapters[0].id, cacheOnly: false, completion: $0) }
        let old = try XCTUnwrap(oldReply as? ContentReply)
        let firstToken = try XCTUnwrap(old.reading?.token)
        let oldSavedReply = await write { engine.finishReading(token: firstToken, eventSequence: 1, utf16Offset: 0, completion: $0) }
        let oldSaved = try XCTUnwrap(oldSavedReply as? ReadingSaved)
        let oldPath = cacheURL(book, old.chapter)
        var group: GroupDeletion?
        if isGroupDeletion {
            var shelf = try await organization { engine.listShelf(completion: $0) }
            shelf = try await organization { engine.createShelfGroup(name: "Remove \(run)", expectedToken: shelf.token, completion: $0) }
            let removed = try XCTUnwrap(shelf.groups.first { $0.name == "Remove \(run)" })
            shelf = try await organization { engine.createShelfGroup(name: "Keep \(run)", expectedToken: shelf.token, completion: $0) }
            let retained = try XCTUnwrap(shelf.groups.first { $0.name == "Keep \(run)" })
            let target = ShelfBookTarget(sourceId: base, bookId: book.id)
            shelf = try await organization { engine.changeShelfGroups(targets: [target], addGroupIds: [removed.id, retained.id],
                removeGroupIds: [], expectedToken: shelf.token, completion: $0) }
            XCTAssertEqual(Set(try XCTUnwrap(shelf.books.first { $0.book.id == book.id }).groupIds), Set([removed.id, retained.id]))
            group = GroupDeletion(removedID: removed.id, retainedID: retained.id, groupIDsBefore: shelf.groups.map(\.id), token: shelf.token)
        }
        var next: ContentReply?
        if phase == "after-file" {
            // Force the real engine's network repair branch; the existing saved fingerprint is untouched.
            try Data("Synthetic stale cache".utf8).write(to: oldPath, options: .atomic)
            let changed = json.replacingOccurrences(of: "id.content@text##MIDDLE##\\nMIDDLE", with: "id.content@text##MIDDLE##\\nMIDDLE-CHANGED")
            _ = await call { engine.importSources(json: changed, completion: $0) }
            _ = await call { engine.openShelfBook(sourceId: base, bookId: book.id, completion: $0) }
            next = await call { engine.loadChapter(sourceId: base, bookId: book.id, chapterId: old.chapter.id, cacheOnly: false, completion: $0) } as? ContentReply
        } else if phase != "before-file" && !isGroupDeletion {
            next = await call { engine.loadChapter(sourceId: base, bookId: book.id, chapterId: chapters[1].id, cacheOnly: false, completion: $0) } as? ContentReply
        }
        if phase != "before-file" && !isGroupDeletion { _ = try XCTUnwrap(next) }
        let newOffset = next.map { Int32(($0.text as NSString).paragraphRange(for: ($0.text as NSString).range(of: "MIDDLE")).location) } ?? 0
        if next != nil { try requireGate(newOffset > 0, "Expected a nonzero fixture paragraph boundary") }
        let manifest = Manifest(processID: getpid(), phase: phase, sourceID: base, bookID: book.id,
            oldChapterID: old.chapter.id, newChapterID: next?.chapter.id ?? chapters[1].id,
            oldHash: hash(old.text), newHash: next.map { hash($0.text) } ?? "", oldRevision: oldSaved.revision,
            newOffset: newOffset, oldCachePath: String(oldPath.path.dropFirst(documents.path.count + 1)),
            newCachePath: String(cacheURL(book, next?.chapter ?? chapters[1]).path.dropFirst(documents.path.count + 1)), group: group)
        try JSONEncoder().encode(manifest).write(to: file("json"), options: .atomic)
        if let group {
            let retainedMask = try XCTUnwrap(Int64(group.retainedID))
            let originalMask = retainedMask | (try XCTUnwrap(Int64(group.removedID)))
            if phase == "group-before-db" {
                let lock = try openSQL()
                defer { sqlite3_exec(lock, "ROLLBACK", nil, nil, nil); sqlite3_close(lock) }
                try requireGate(sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK, "Fixture writer lock was not acquired")
                engine.deleteShelfGroup(groupId: group.removedID, expectedToken: group.token) { _ in
                    try? Data("Unexpected group acknowledgement".utf8).write(to: self.file("ack"), options: .atomic)
                }
                try await Task.sleep(nanoseconds: 300_000_000)
                try requireGate(try groupExists(group.removedID) && groupMask(book.id) == originalMask,
                                "Group deletion committed before the locked boundary")
                try requireGate(!FileManager.default.fileExists(atPath: file("ack").path), "Group callback arrived before the locked boundary")
                try Data("Group writer locked before commit".utf8).write(to: file("ready"), options: .atomic)
                try await waitForExternalTermination()
            } else {
                engine.deleteShelfGroup(groupId: group.removedID, expectedToken: group.token) { _ in
                    try? Data("Group acknowledgement delivered".utf8).write(to: self.file("ack"), options: .atomic)
                }
                let deadline = Date().addingTimeInterval(20)
                while try (groupExists(group.removedID) || groupMask(book.id) != retainedMask) && Date() < deadline { usleep(20_000) }
                try requireGate(try !groupExists(group.removedID) && groupMask(book.id) == retainedMask,
                                "Complete group deletion was not observed before the deadline")
                try requireGate(!FileManager.default.fileExists(atPath: file("ack").path), "Group callback arrived before the committed boundary")
                try Data("Group deletion committed before callback".utf8).write(to: file("ready"), options: .atomic)
                while Date() < deadline { usleep(100_000) }
                XCTFail("Driver did not terminate the committed group process")
            }
            return
        } else if phase == "before-file" {
            _ = engine.loadChapter(sourceId: base, bookId: book.id, chapterId: chapters[1].id, cacheOnly: false) { _ in
                try? Data("Unexpected callback".utf8).write(to: self.file("ack"), options: .atomic)
            }
        } else if phase == "before-db" {
            let lock = try openSQL()
            defer { sqlite3_exec(lock, "ROLLBACK", nil, nil, nil); sqlite3_close(lock) }
            try requireGate(sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK, "Fixture writer lock was not acquired")
            let token = try XCTUnwrap(next?.reading?.token)
            engine.saveReadingPosition(token: token, eventSequence: 1, utf16Offset: newOffset) { _ in
                try? Data("Unexpected callback".utf8).write(to: self.file("ack"), options: .atomic)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            try requireGate(try revision(book.id) == oldSaved.revision, "Progress committed before the locked boundary")
            try requireGate(!FileManager.default.fileExists(atPath: file("ack").path), "Callback arrived before the locked boundary")
            try Data("Writer lock held before commit".utf8).write(to: file("ready"), options: .atomic)
            try await waitForExternalTermination()
            return
        } else if phase == "after-db" {
            let token = try XCTUnwrap(next?.reading?.token)
            engine.saveReadingPosition(token: token, eventSequence: 1, utf16Offset: newOffset) { _ in
                try? Data("Acknowledgement delivered".utf8).write(to: self.file("ack"), options: .atomic)
            }
            // Keep MainActor occupied: the actual Room transaction runs off-main, while its acknowledgement cannot execute.
            let deadline = Date().addingTimeInterval(20)
            while try revision(book.id) != oldSaved.revision + 1 && Date() < deadline { usleep(20_000) }
            try requireGate(try revision(book.id) == oldSaved.revision + 1, "Commit was not observed before the deadline")
            try requireGate(!FileManager.default.fileExists(atPath: file("ack").path), "Callback arrived before the committed boundary")
            try Data("Commit observed before callback".utf8).write(to: file("ready"), options: .atomic)
            while Date() < deadline { usleep(100_000) }
            XCTFail("Driver did not terminate the committed process")
            return
        }
        try Data("Boundary ready".utf8).write(to: file("ready"), options: .atomic)
        try await waitForExternalTermination()
    }

    private func waitForExternalTermination() async throws {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        XCTFail("Driver did not terminate the prepared process")
    }

    func testVerifyInterruption() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPEC003_INTERRUPT_MODE"] == "verify")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: file("json")))
        XCTAssertNotEqual(getpid(), manifest.processID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("ack").path), "Commit acknowledgement must not have been delivered")
        let engine = ReaderEngine()
        defer { engine.close() }
        let ready = await call { engine.initialize(completion: $0) }
        XCTAssertTrue(ready is EngineReady)
        if let group = manifest.group {
            let shelf = try await organization { engine.listShelf(completion: $0) }
            let committed = manifest.phase == "group-after-db"
            let expectedGroups = Set(group.groupIDsBefore).subtracting(committed ? [group.removedID] : [])
            XCTAssertEqual(Set(shelf.groups.map(\.id)), expectedGroups)
            let entry = try XCTUnwrap(shelf.books.first { $0.book.id == manifest.bookID && $0.book.sourceId == manifest.sourceID })
            XCTAssertEqual(Set(entry.groupIds), committed ? Set([group.retainedID]) : Set([group.removedID, group.retainedID]))
            XCTAssertEqual(try revision(manifest.bookID), manifest.oldRevision)
        }
        let reply = await call { engine.openReading(sourceId: manifest.sourceID, bookId: manifest.bookID, cacheOnly: true, completion: $0) }
        if manifest.phase == "after-file" {
            XCTAssertEqual((reply as? EngineFailure)?.code, .cacheUnavailable)
            XCTAssertEqual(try revision(manifest.bookID), manifest.oldRevision)
            XCTAssertNotEqual(manifest.oldHash, manifest.newHash)
            XCTAssertEqual(hash(try String(contentsOf: documents.appendingPathComponent(manifest.newCachePath), encoding: .utf8)), manifest.newHash)
        } else {
            let body = try XCTUnwrap(reply as? ContentReply)
            let committed = manifest.phase == "after-db"
            XCTAssertEqual(body.chapter.id, committed ? manifest.newChapterID : manifest.oldChapterID)
            XCTAssertEqual(body.reading?.revision, manifest.oldRevision + (committed ? 1 : 0))
            XCTAssertEqual(body.reading?.paragraphUtf16Offset, committed ? manifest.newOffset : 0)
            XCTAssertEqual(hash(body.text), committed ? manifest.newHash : manifest.oldHash)
            if manifest.phase == "before-file" { XCTAssertFalse(FileManager.default.fileExists(atPath: documents.appendingPathComponent(manifest.newCachePath).path)) }
            if manifest.phase == "before-db" {
                XCTAssertEqual(hash(try String(contentsOf: documents.appendingPathComponent(manifest.newCachePath), encoding: .utf8)), manifest.newHash,
                    "A completed chapter file may survive while the interrupted database write retains old progress")
            }
        }
        let result = ["phase": manifest.phase, "oldPID": String(manifest.processID), "newPID": String(getpid()),
            "oldHash": manifest.oldHash, "newHash": manifest.newHash, "verified": "true"]
        try JSONEncoder().encode(result).write(to: file("verified.json"), options: .atomic)
    }
}
