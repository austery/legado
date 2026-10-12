import Foundation
import SwiftUI
import ReaderEngine

struct Check: Codable {
    let name: String
    let passed: Bool
    let detail: String
}

@MainActor
final class Harness: ObservableObject {
    @Published var checks: [Check] = []
    @Published var finished = false
    private let engine = ReaderEngine()
    private let sourceID = "http://127.0.0.1:18765"
    private let persistenceRun = ProcessInfo.processInfo.environment["PATH_C_PERSISTENCE"] == "1"

    private func record(_ name: String, _ passed: Bool, _ detail: String = "") {
        checks.append(Check(name: name, passed: passed, detail: detail))
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(checks).write(to: directory.appendingPathComponent("results.json"), options: .atomic)
        } catch {
            NSLog("Harness report write failed: %@", error.localizedDescription)
        }
    }

    private func call(_ start: (@escaping (EngineReply) -> Void) -> EngineRequest) async -> EngineReply {
        await withCheckedContinuation { continuation in
            var delivered = false
            _ = start { reply in
                self.record("callback-main-thread", Thread.isMainThread)
                guard !delivered else {
                    self.record("callback-exactly-once", false)
                    return
                }
                delivered = true
                continuation.resume(returning: reply)
            }
        }
    }

    private func describe(_ reply: EngineReply) -> String {
        if let failure = reply as? EngineFailure { return "\(failure.code.name): \(failure.message)" }
        if let search = reply as? SearchReply { return "Search: \(search.books.map { $0.title })" }
        return String(describing: type(of: reply))
    }

    private func expectFailure(_ name: String, _ reply: EngineReply, _ code: EngineErrorCode) {
        record(name, (reply as? EngineFailure)?.code == code, describe(reply))
    }

    func run() async {
        defer { record("suite-complete", true); finished = true }
        let ready = await call { engine.initialize(completion: $0) }
        record("initialize", ready is EngineReady, describe(ready))
        guard ready is EngineReady else { finished = true; return }
        if persistenceRun {
            await chain(sourceID, query: "Path", controlled: true)
            let cachedJS = await call { engine.search(sourceId: "http://127.0.0.1:18767/js-read", query: "Path", page: 1, completion: $0) }
            record("restart-js-cache", (cachedJS as? SearchReply)?.books.first?.title == "JS-CACHE-OK", describe(cachedJS))
            engine.close()
            finished = true
            return
        }
        let repeated = await call { engine.initialize(completion: $0) }
        record("initialize-repeated", repeated is EngineReady, describe(repeated))
        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: sourceID + "/sources.json")!)
            let imported = await call { engine.importSources(json: String(decoding: data, as: UTF8.self), completion: $0) }
            record("import", (imported as? SourcesReply)?.sources.count == 1, describe(imported))
        } catch {
            record("fixture-available", false, error.localizedDescription)
            finished = true
            return
        }
        let malformed = await call { engine.importSources(json: "[{", completion: $0) }
        expectFailure("malformed-import", malformed, .invalidInput)
        let invalidBatch = """
        [{"bookSourceUrl":"\(sourceID)","bookSourceName":"Must not replace valid source"},{"bookSourceUrl":"","bookSourceName":"Invalid"}]
        """
        let invalid = await call { engine.importSources(json: invalidBatch, completion: $0) }
        expectFailure("invalid-batch-import", invalid, .invalidInput)
        let duplicates = """
        [{"bookSourceUrl":"path-c:duplicate","bookSourceName":"First"},{"bookSourceUrl":"path-c:duplicate","bookSourceName":"Last"}]
        """
        let duplicate = await call { engine.importSources(json: duplicates, completion: $0) }
        record("duplicate-id-last-wins", (duplicate as? SourcesReply)?.sources.count == 1 && (duplicate as? SourcesReply)?.sources.first?.name == "Last", describe(duplicate))
        await chain(sourceID, query: "Path", controlled: true)
        let empty = await call { engine.search(sourceId: sourceID, query: "missing", page: 1, completion: $0) }
        record("empty-search", (empty as? SearchReply)?.books.isEmpty == true, describe(empty))
        let failure = await call { engine.search(sourceId: sourceID, query: "http-error", page: 1, completion: $0) }
        expectFailure("http-error", failure, .network)
        let cancelled: EngineReply = await withCheckedContinuation { continuation in
            var delivered = false
            let request = engine.search(sourceId: sourceID, query: "slow", page: 1) { reply in
                guard !delivered else { self.record("cancel-callback-exactly-once", false); return }
                delivered = true
                continuation.resume(returning: reply)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                request.cancel()
            }
        }
        expectFailure("cancel-active-search", cancelled, .cancelled)
        let immediate: EngineReply = await withCheckedContinuation { continuation in
            let request = engine.search(sourceId: sourceID, query: "slow", page: 1) { reply in
                continuation.resume(returning: reply)
            }
            request.cancel()
        }
        expectFailure("cancel-before-dispatch", immediate, .cancelled)
        let recovered = await call { engine.search(sourceId: sourceID, query: "Path", page: 1, completion: $0) }
        record("search-after-cancel", (recovered as? SearchReply)?.books.count == 1, describe(recovered))
        await probeFailures()
        let another = ReaderEngine()
        let anotherReady = await call { another.initialize(completion: $0) }
        record("second-session-initialize", anotherReady is EngineReady, describe(anotherReady))
        let persisted = await call { another.search(sourceId: sourceID, query: "Path", page: 1, completion: $0) }
        record("second-session-stored-source", (persisted as? SearchReply)?.books.count == 1, describe(persisted))
        another.close()
        engine.close()
        let closed = await call { engine.search(sourceId: sourceID, query: "Path", page: 1, completion: $0) }
        expectFailure("request-after-close", closed, .cancelled)
        finished = true
    }

    private func probeFailures() async {
        let base = "http://127.0.0.1:18767"
        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/engine-sources.json")!)
            let imported = await call { engine.importSources(json: String(decoding: data, as: UTF8.self), completion: $0) }
            record("probe-import", (imported as? SourcesReply)?.sources.count == 9, describe(imported))
        } catch { record("probe-fixture", false, error.localizedDescription); return }
        for suffix in ["js-write", "js-read"] {
            let reply = await call { engine.search(sourceId: base + "/" + suffix, query: "Path", page: 1, completion: $0) }
            record(suffix, (reply as? SearchReply)?.books.first?.title == "JS-CACHE-OK", describe(reply))
        }
        let cases: [(String, EngineErrorCode)] = [("interaction", .interactionRequired), ("webview", .unsupported), ("rule-error", .rule)]
        for (suffix, expected) in cases {
            let reply = await call { engine.search(sourceId: base + "/" + suffix, query: "Path", page: 1, completion: $0) }
            expectFailure(suffix, reply, expected)
        }
        let timeout = await call { engine.search(sourceId: base + "/js-read", query: "timeout", page: 1, completion: $0) }
        expectFailure("transport-timeout", timeout, .timeout)
        let id = base + "/page-error"
        let search = await call { engine.search(sourceId: id, query: "Path", page: 1, completion: $0) }
        guard let book = (search as? SearchReply)?.books.first else { record("page-error-search", false, describe(search)); return }
        _ = await call { engine.loadBook(sourceId: id, bookId: book.id, completion: $0) }
        let toc = await call { engine.loadToc(sourceId: id, bookId: book.id, completion: $0) }
        guard let chapter = (toc as? TocReply)?.chapters.first else { record("page-error-toc", false, describe(toc)); return }
        let failed = await call { engine.loadChapter(sourceId: id, bookId: book.id, chapterId: chapter.id, cacheOnly: false, completion: $0) }
        expectFailure("pagination-http-error", failed, .network)
        let uncached = await call { engine.loadChapter(sourceId: id, bookId: book.id, chapterId: chapter.id, cacheOnly: true, completion: $0) }
        expectFailure("failed-content-not-cached", uncached, .notFound)
        for suffix in ["toc-error", "content-interaction", "cookie"] {
            let probeId = base + "/" + suffix
            let search = await call { engine.search(sourceId: probeId, query: "Path", page: 1, completion: $0) }
            guard let book = (search as? SearchReply)?.books.first else { record(suffix + "-search", false, describe(search)); continue }
            let detail = await call { engine.loadBook(sourceId: probeId, bookId: book.id, completion: $0) }
            if suffix == "cookie" {
                record("http-cookie-roundtrip", (detail as? BookReply)?.book.intro.contains("Cookie was received") == true, describe(detail))
                continue
            }
            let toc = await call { engine.loadToc(sourceId: probeId, bookId: book.id, completion: $0) }
            if suffix == "toc-error" { expectFailure("toc-pagination-http-error", toc, .network); continue }
            guard let chapter = (toc as? TocReply)?.chapters.first else { record(suffix + "-toc", false, describe(toc)); continue }
            let content = await call { engine.loadChapter(sourceId: probeId, bookId: book.id, chapterId: chapter.id, cacheOnly: false, completion: $0) }
            expectFailure("content-interaction", content, .interactionRequired)
            let cache = await call { engine.loadChapter(sourceId: probeId, bookId: book.id, chapterId: chapter.id, cacheOnly: true, completion: $0) }
            expectFailure("interaction-not-cached", cache, .notFound)
        }
    }

    private func chain(_ id: String, query: String, controlled: Bool) async {
        let searched = await call { engine.search(sourceId: id, query: query, page: 1, completion: $0) }
        guard let book = (searched as? SearchReply)?.books.first else {
            record("search", false, describe(searched)); return
        }
        record("search-preserves-valid-import", book.sourceId == id, book.title)
        let detail = await call { engine.loadBook(sourceId: id, bookId: book.id, completion: $0) }
        record("detail", detail is BookReply, describe(detail))
        let toc = await call { engine.loadToc(sourceId: id, bookId: book.id, completion: $0) }
        guard let chapters = (toc as? TocReply)?.chapters, let chapter = chapters.first else {
            record("toc", false, describe(toc)); return
        }
        record("toc", !controlled || chapters.count == 3, "\(chapters.count) chapters")
        let content = await call { engine.loadChapter(sourceId: id, bookId: book.id, chapterId: chapter.id, cacheOnly: false, completion: $0) }
        guard let content = content as? ContentReply else { record("content", false, describe(content)); return }
        let text = content.text
        if persistenceRun { record("restart-chapter-cache", content.fromCache) }
        let markers = ["C1-FIRST", "C1-MIDDLE", "C1-LAST"]
        let ranges = markers.compactMap { text.range(of: $0) }
        let complete = ranges.count == 3 && zip(ranges, ranges.dropFirst()).allSatisfy { $0.lowerBound < $1.lowerBound }
            && markers.allSatisfy { text.components(separatedBy: $0).count == 2 }
        record("content-pagination", !controlled || complete, "\(text.count) characters")
        let cached = await call { engine.loadChapter(sourceId: id, bookId: book.id, chapterId: chapter.id, cacheOnly: true, completion: $0) }
        record("cache-equality", (cached as? ContentReply)?.text == text && (cached as? ContentReply)?.fromCache == true, describe(cached))
    }
}

@main
struct HarnessApp: App {
    @StateObject private var harness = Harness()
    var body: some Scene {
        WindowGroup {
            List {
                Text(harness.finished ? "Finished" : "Running engine checks")
                ForEach(Array(harness.checks.enumerated()), id: \.offset) { item in
                    Text("\(item.element.passed ? "PASS" : "FAIL") \(item.element.name) \(item.element.detail)")
                }
            }.task { await harness.run() }
        }
    }
}
