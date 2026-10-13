import XCTest
import ReaderEngine
@testable import NativeReader

/// Opt-in phases run in separate test-host processes; normal suites skip both.
@MainActor
final class ShelfProcessRestartTests: XCTestCase {
    private struct Manifest: Codable {
        let processID: Int32
        let sourceID: String
        let bookID: String
        let chapters: [String]
    }
    private let key = "SPEC003.disposableSimulator.restartManifest"

    private func settle(_ model: ReaderModel) async throws {
        let deadline = Date().addingTimeInterval(20)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.message)
    }

    func testPrepare() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPEC003_RESTART_PHASE"] == "prepare")
        let model = ReaderModel()
        model.start(); try await settle(model)
        let run = UUID().uuidString
        let base = "http://127.0.0.1:18769/runs/\(run)"
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: base + "/sources.json")))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "class.name@text", with: "class.name@text##$## " + run)
            .replacingOccurrences(of: "tag.h1@text", with: "tag.h1@text##$## " + run)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(run + ".json")
        try Data(json.utf8).write(to: file)
        model.importFile(file); try await settle(model)
        model.sourceID = base; model.query = "Path"; model.search(); try await settle(model)
        model.select(try XCTUnwrap(model.results.first)); try await settle(model)
        model.addCurrentBook(); try await settle(model)
        let book = try XCTUnwrap(model.book)
        let manifest = Manifest(processID: getpid(), sourceID: book.sourceId, bookID: book.id, chapters: model.chapters.map(\.id))
        model.read(try XCTUnwrap(model.chapters.first)); try await settle(model)
        XCTAssertTrue(model.content?.text.contains("C1-LAST") == true)
        try Data(json.replacingOccurrences(of: "\"enabled\": true", with: "\"enabled\": false").utf8).write(to: file)
        model.importFile(file); try await settle(model)
        UserDefaults.standard.set(try JSONEncoder().encode(manifest), forKey: key)
        XCTAssertTrue(UserDefaults.standard.synchronize())
        print("SPEC003 prepare PID=\(getpid()) book=\(book.id)")
    }

    func testVerify() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPEC003_RESTART_PHASE"] == "verify")
        let manifest = try JSONDecoder().decode(Manifest.self, from: XCTUnwrap(UserDefaults.standard.data(forKey: key)))
        XCTAssertNotEqual(getpid(), manifest.processID, "Verification requires a new app process")
        let model = ReaderModel()
        model.start(); try await settle(model)
        XCTAssertEqual(model.route, .shelf)
        XCTAssertFalse(model.sources.contains { $0.id == manifest.sourceID })
        let entry = try XCTUnwrap(model.shelf.first { $0.book.id == manifest.bookID && $0.book.sourceId == manifest.sourceID })
        model.openShelfBook(entry); try await settle(model)
        XCTAssertEqual(model.chapters.map(\.id), manifest.chapters)
        XCTAssertNil(model.content)
        model.read(try XCTUnwrap(model.chapters.first)); try await settle(model)
        XCTAssertTrue(model.content?.fromCache == true)
        XCTAssertTrue(model.content?.text.contains("C1-LAST") == true)
        print("SPEC003 verify PID=\(getpid()) previousPID=\(manifest.processID) book=\(manifest.bookID)")
    }
}
