import SwiftUI
import ReaderEngine
import SQLite3

/// Compiled only in the independent synthetic UI host, never in NativeReader.
@main
struct FixtureReaderApp: App {
    @StateObject private var model = ReaderModel(deliverReply: { stage, reply, apply in
        if stage == .sourceSwitch, reply is ShelfEntryReply,
           ProcessInfo.processInfo.environment["READER_UI_DROP_SWITCH_ACK"] == "1" {
            UserDefaults.standard.set(true, forKey: "fixture.switchCommitted")
            return
        }
        if ProcessInfo.processInfo.environment["READER_UI_SCENARIO"] == "sources" {
            let entry: String?
            if let result = reply as? ManagedSourcesReply {
                entry = "list:" + result.sources.map { $0.groups.joined(separator: ",") }.joined(separator: "|")
            } else if let error = reply as? EngineFailure { entry = "error:" + error.code.name }
            else { entry = nil }
            if let entry {
                let previous = UserDefaults.standard.string(forKey: "fixture.sourceReplies") ?? ""
                UserDefaults.standard.set(String((previous + ";" + entry).suffix(2048)), forKey: "fixture.sourceReplies")
            }
        }
        apply(reply)
    })
    @State private var searchFixtureBase: String?
    @State private var prepared = false
    @State private var failure: String?
    @State private var rejectingSave = false
    @State private var heldChapter = false
    @State private var positionStatus = "preparing"
    @State private var storedStatus = "preparing"
    @State private var switchCommitted = false
    private var scenario: String { ProcessInfo.processInfo.environment["READER_UI_SCENARIO"] ?? "shelf" }
    private let tick = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                if prepared {
                    ReaderScreen(model: model)
                    HStack {
                        Text("SYNTHETIC UI HOST").font(.caption2)
                        Text("Fixture position").accessibilityIdentifier("fixture.position").accessibilityValue(positionStatus)
                        Text("Stored record").accessibilityIdentifier("fixture.stored").accessibilityValue(storedStatus)
                        Text("Switch committed").accessibilityIdentifier("fixture.switchCommit").accessibilityValue(switchCommitted ? "true" : "false")
                        if scenario == "sources" {
                            Text("Source replies").accessibilityIdentifier("fixture.sourceReplies")
                                .accessibilityValue(UserDefaults.standard.string(forKey: "fixture.sourceReplies") ?? "none")
                        }
                        if scenario == "search-invalidation" {
                            Button("Disable from another engine") {
                                Task { @MainActor in
                                    guard let base = searchFixtureBase else { return }
                                    let other = ReaderEngine(); defer { other.close() }
                                    let ready = await withCheckedContinuation { continuation in
                                        _ = other.initialize { continuation.resume(returning: $0) }
                                    }
                                    guard ready is EngineReady else { failure = "Other engine failed to initialize"; return }
                                    let changed = await withCheckedContinuation { continuation in
                                        _ = other.setSourcesEnabled(ids: [base], enabled: false) {
                                            continuation.resume(returning: $0)
                                        }
                                    }
                                    guard changed is ManagedSourcesReply else { failure = "Source mutation failed"; return }
                                    _ = try? await URLSession.shared.data(from: URL(string: base + "/control/release/search")!)
                                }
                            }.accessibilityIdentifier("fixture.invalidateSearch")
                        }
                        Spacer()
                        Button(heldChapter ? "Release chapter" : "Hold chapter") {
                            Task { @MainActor in
                                guard let base = model.book?.sourceId,
                                      let url = URL(string: base + "/control/" + (heldChapter ? "release" : "hold") + "/chapter") else { return }
                                do {
                                    _ = try await URLSession.shared.data(from: url)
                                    heldChapter.toggle()
                                } catch { failure = error.localizedDescription }
                            }
                        }.accessibilityIdentifier("fixture.hold")
                        Button(rejectingSave ? "Allow saves" : "Reject saves") {
                            do {
                                try sql(rejectingSave ? "DROP TRIGGER IF EXISTS ui_save_rejection" : "CREATE TRIGGER ui_save_rejection BEFORE UPDATE ON native_reading_resume BEGIN SELECT RAISE(ABORT, 'Synthetic save rejection'); END")
                                rejectingSave.toggle()
                            } catch { failure = error.localizedDescription }
                        }.accessibilityIdentifier("fixture.saveFailure")
                    }.padding(8)
                } else { ProgressView("Preparing synthetic shelf…") }
                if let failure { Text(failure).accessibilityIdentifier("fixture.failure") }
            }.onReceive(tick) { _ in
                switchCommitted = UserDefaults.standard.bool(forKey: "fixture.switchCommitted")
                let text = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows).compactMap { $0.rootViewController?.view }.lazy.compactMap(findText).first
                let chapter = model.chapterPosition.map(String.init) ?? "none"
                storedStatus = (try? storedRecord()) ?? "query-failed"
                positionStatus = "dragging=\(text?.isDragging ?? false);decelerating=\(text?.isDecelerating ?? false);canSave=\(model.content?.reading.map { $0.canSave ? "true" : "false" } ?? "nil");chapter=\(chapter);anchor=\(text?.anchor ?? -1);source=\(model.content?.chapter.sourceId ?? "none");book=\(model.content?.chapter.bookId ?? "none");id=\(model.content?.chapter.id ?? "none")"
                if let progress = model.cacheProgress {
                    positionStatus += ";cached=\(progress.completed);cacheRunning=\(progress.running);"
                }
            }.task {
                guard !prepared else { return }
                do { try await prepare(); prepared = true }
                catch { failure = error.localizedDescription }
            }
        }
    }

    @MainActor private func settle() async throws {
        let deadline = Date().addingTimeInterval(20)
        while (model.busy || model.searchRunning || model.searchCommandPending) && Date() < deadline {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        if model.busy || model.searchRunning || model.searchCommandPending || model.message != nil {
            throw NSError(domain: "FixtureSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: model.message ?? "Setup timeout"])
        }
    }
    @MainActor private func prepare() async throws {
        if ProcessInfo.processInfo.environment["READER_UI_RESET"] == "1" {
            UserDefaults.standard.removeObject(forKey: ReadingPreferences.storageKey)
            UserDefaults.standard.removeObject(forKey: ReadingPreferences.prefetchKey)
            UserDefaults.standard.removeObject(forKey: "fixture.switchCommitted")
            UserDefaults.standard.removeObject(forKey: "fixture.sourceReplies")
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            for name in ["legado.db", "legado.db-wal", "legado.db-shm"] {
                let url = documents.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        }
        model.start(); try await settle()
        if scenario == "shelf", !model.shelf.isEmpty { model.showShelf(); try await settle(); return }
        if scenario == "sources", ProcessInfo.processInfo.environment["READER_UI_RESET"] != "1" {
            model.navigate(.sources); try await settle(); return
        }
        let base = "http://127.0.0.1:18769/runs/ui-\(UUID().uuidString)"
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/sources.json")!)
        var json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "id.content@text", with: "id.content@text##第##\\n第")
        if scenario == "offline" {
            json = json.replacingOccurrences(of: "class.toc@href", with: "class.toc@href##/toc/1##/toc/offline")
        }
        if scenario == "sources" {
            let second = json.replacingOccurrences(of: base, with: base + "/second")
            json = "[" + String(json.dropFirst().dropLast()) + "," + String(second.dropFirst().dropLast()) + "]"
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic.json")
        try Data(json.utf8).write(to: file)
        model.importFile(file); try await settle()
        if scenario == "sources" { model.navigate(.sources); try await settle(); return }
        model.confirmSourceImport(); try await settle()
        if scenario == "search-invalidation" {
            searchFixtureBase = base
            _ = try await URLSession.shared.data(from: URL(string: base + "/control/hold/search")!)
            model.searchScope = .selected; model.selectedSourceIDs = [base]; model.query = "Path"; model.search()
            let (entered, _) = try await URLSession.shared.data(from: URL(string: base + "/control/entered/search")!)
            guard String(decoding: entered, as: UTF8.self) == "entered" else {
                throw NSError(domain: "FixtureSetup", code: 5)
            }
            return
        }
        model.searchScope = .selected; model.selectedSourceIDs = [base]; model.query = "Path"; model.search(); try await settle()
        guard let book = model.results.first else { throw NSError(domain: "FixtureSetup", code: 2) }
        model.select(book); try await settle()
        if scenario == "preview" {
            model.read(model.chapters[1]); try await settle()
        } else {
            model.addCurrentBook(); try await settle()
            if scenario == "readonly" {
                model.read(model.chapters[0]); try await settle()
                guard let reading = model.content?.reading else { throw NSError(domain: "FixtureSetup", code: 3) }
                model.readingDisplayed(reading.token, 0)
                model.navigate(.contents); try await settle()
                // An unsupported stored format makes the real engine return canSave=false.
                // This modifies only this independent host's synthetic book.
                try sql("UPDATE native_reading_resume SET textVersion = 'ui-unsupported' WHERE bookUrl = '" + model.book!.id.replacingOccurrences(of: "'", with: "''") + "'")
                model.read(model.chapters[1]); try await settle()
                guard model.content?.reading?.canSave == false else { throw NSError(domain: "FixtureSetup", code: 4) }
            } else {
                if scenario == "catalog" {
                    let alternate = base + "-alternate"
                    let (alternateData, _) = try await URLSession.shared.data(from: URL(string: alternate + "/sources.json")!)
                    try alternateData.write(to: file)
                    model.importFile(file); try await settle(); model.confirmSourceImport(); try await settle()
                    model.searchScope = .all
                }
                model.showShelf(); try await settle()
            }
        }
    }
    private func findText(_ view: UIView) -> AnchoredTextView? {
        if let text = view as? AnchoredTextView { return text }
        return view.subviews.lazy.compactMap(findText).first
    }
    private func storedRecord() throws -> String {
        guard let book = model.book else { return "none" }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("legado.db")
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw NSError(domain: "FixtureSQL", code: 3) }
        defer { sqlite3_close(db) }
        let id = book.id.replacingOccurrences(of: "'", with: "''")
        // Include the whole resume row and shared book projection, not only its chapter.
        let query = "SELECT r.*, b.durChapterIndex, b.durChapterTitle, b.durChapterPos, b.durChapterTime FROM native_reading_resume r JOIN books b ON b.bookUrl = r.bookUrl WHERE r.bookUrl = '" + id + "'"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "FixtureSQL", code: 4) }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            var count: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM books WHERE bookUrl = '" + id + "'", -1, &count, nil) == SQLITE_OK else { throw NSError(domain: "FixtureSQL", code: 5) }
            defer { sqlite3_finalize(count) }
            guard sqlite3_step(count) == SQLITE_ROW else { throw NSError(domain: "FixtureSQL", code: 6) }
            return "resume=none;books=\(sqlite3_column_int(count, 0))"
        }
        guard result == SQLITE_ROW else { throw NSError(domain: "FixtureSQL", code: 7) }
        return (0..<sqlite3_column_count(statement)).map { column in
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "NULL"
        }.joined(separator: "|")
    }
    private func sql(_ statement: String) throws {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("legado.db")
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { throw NSError(domain: "FixtureSQL", code: 1) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "FixtureSQL", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }
}
