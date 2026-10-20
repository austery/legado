import XCTest
import ReaderEngine
import CryptoKit

/// Runs inside the existing isolated two-process harness, whose reading server stops before verification.
@MainActor
enum OfflineRestartJourney {
    private struct Manifest: Codable {
        let processID: Int32
        let source: String
        let book: String
        let bodies: [String: String]
    }
    private static let key = "SPEC006.disposableSimulator.offlineManifest"
    private static func call(_ start: (@escaping (EngineReply) -> Void) -> EngineRequest) async -> EngineReply {
        await withCheckedContinuation { continuation in _ = start { continuation.resume(returning: $0) } }
    }
    private static func hash(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func prepare() async throws {
        let engine = ReaderEngine(); defer { engine.close() }
        _ = await call { engine.initialize(completion: $0) }
        let run = UUID().uuidString
        let base = "http://127.0.0.1:18769/runs/\(run)"
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/sources.json")))
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "class.name@text", with: "class.name@text##$## " + run)
            .replacingOccurrences(of: "tag.h1@text", with: "tag.h1@text##$## " + run)
            .replacingOccurrences(of: "class.toc@href", with: "class.toc@href##/toc/1##/toc/offline")
        _ = await call { engine.importSources(json: json, completion: $0) }
        let search = await call { engine.search(sourceId: base, query: "Path", page: 1, completion: $0) }
        let book = try XCTUnwrap((search as? SearchReply)?.books.first)
        _ = await call { engine.loadBook(sourceId: base, bookId: book.id, completion: $0) }
        let toc = await call { engine.loadToc(sourceId: base, bookId: book.id, completion: $0) }
        let first = try XCTUnwrap((toc as? TocReply)?.chapters.first)
        _ = await call { engine.addToShelf(sourceId: base, bookId: book.id, completion: $0) }
        let opened = await call { engine.loadChapter(sourceId: base, bookId: book.id, chapterId: first.id, cacheOnly: false, completion: $0) }
        XCTAssertTrue(opened is ContentReply)
        let terminal: EngineReply = await withCheckedContinuation { continuation in
            _ = engine.cacheNextChapters(sourceId: base, bookId: book.id, afterChapterId: first.id, prefetch: false) { reply in
                if let progress = reply as? CacheProgress, progress.running { return }
                continuation.resume(returning: reply)
            }
        }
        XCTAssertEqual((terminal as? CacheProgress)?.completed, 20)
        let status = await call { engine.offlineStatus(sourceId: base, bookId: book.id, completion: $0) }
        let available = try XCTUnwrap(status as? OfflineStatus).chapters.filter { $0.availability == .available }
        XCTAssertEqual(available.count, 21)
        var bodies: [String: String] = [:]
        for chapter in available {
            let reply = await call { engine.loadChapter(sourceId: base, bookId: book.id, chapterId: chapter.chapterId, cacheOnly: true, completion: $0) }
            bodies[chapter.chapterId] = hash(try XCTUnwrap(reply as? ContentReply).text)
        }
        let manifest = Manifest(processID: getpid(), source: base, book: book.id, bodies: bodies)
        UserDefaults.standard.set(try JSONEncoder().encode(manifest), forKey: key)
        XCTAssertTrue(UserDefaults.standard.synchronize())
        print("SPEC006 prepared 21 verified offline chapters PID=\(getpid())")
    }
    static func verify() async throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: XCTUnwrap(UserDefaults.standard.data(forKey: key)))
        XCTAssertNotEqual(manifest.processID, getpid())
        let engine = ReaderEngine(); defer { engine.close() }
        _ = await call { engine.initialize(completion: $0) }
        _ = await call { engine.openShelfBook(sourceId: manifest.source, bookId: manifest.book, completion: $0) }
        let status = await call { engine.offlineStatus(sourceId: manifest.source, bookId: manifest.book, completion: $0) }
        let available = try XCTUnwrap(status as? OfflineStatus).chapters.filter { $0.availability == .available }
        XCTAssertEqual(Set(available.map(\.chapterId)), Set(manifest.bodies.keys))
        for chapter in available {
            let reply = await call { engine.loadChapter(sourceId: manifest.source, bookId: manifest.book,
                chapterId: chapter.chapterId, cacheOnly: false, completion: $0) }
            let content = try XCTUnwrap(reply as? ContentReply)
            XCTAssertTrue(content.fromCache)
            XCTAssertEqual(hash(content.text), manifest.bodies[chapter.chapterId])
        }
        print("SPEC006 verified all 21 chapters with no fixture listener PID=\(getpid()) previousPID=\(manifest.processID)")
    }
}
