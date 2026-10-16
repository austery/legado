import SwiftUI
import ReaderEngine
import SQLite3

/// Compiled only in the independent synthetic UI host, never in NativeReader.
@main
struct FixtureReaderApp: App {
    @StateObject private var model = ReaderModel()
    @State private var prepared = false
    @State private var failure: String?
    @State private var rejectingSave = false
    @State private var heldChapter = false
    @State private var positionStatus = "preparing"
    private let tick = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                if prepared {
                    ReaderScreen(model: model)
                    HStack {
                        Text("SYNTHETIC UI HOST").font(.caption2)
                        Text("Fixture position").accessibilityIdentifier("fixture.position").accessibilityValue(positionStatus)
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
                let text = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows).compactMap { $0.rootViewController?.view }.lazy.compactMap(findText).first
                let chapter = model.chapterPosition.map(String.init) ?? "none"
                positionStatus = "chapter=\(chapter);anchor=\(text?.anchor ?? -1);source=\(model.content?.chapter.sourceId ?? "none");book=\(model.content?.chapter.bookId ?? "none");id=\(model.content?.chapter.id ?? "none")"
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
        model.start(); try await settle()
        if !model.shelf.isEmpty { model.showShelf(); try await settle(); return }
        let base = "http://127.0.0.1:18769/runs/ui-\(UUID().uuidString)"
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/sources.json")!)
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "id.content@text", with: "id.content@text##第##\\n第")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic.json")
        try Data(json.utf8).write(to: file)
        model.importFile(file); try await settle()
        model.searchScope = .selected; model.selectedSourceIDs = [base]; model.query = "Path"; model.search(); try await settle()
        guard let book = model.results.first else { throw NSError(domain: "FixtureSetup", code: 2) }
        model.select(book); try await settle()
        model.addCurrentBook(); try await settle()
        model.showShelf(); try await settle()
    }
    private func findText(_ view: UIView) -> AnchoredTextView? {
        if let text = view as? AnchoredTextView { return text }
        return view.subviews.lazy.compactMap(findText).first
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
