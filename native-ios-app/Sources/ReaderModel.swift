import Foundation
import ReaderEngine
import SwiftUI

enum ReaderRoute { case search, contents, reading }

@MainActor
final class ReaderModel: ObservableObject {
    @Published var sources: [SourceSnapshot] = []
    @Published var sourceID = ""
    @Published var query = ""
    @Published var results: [BookSnapshot] = []
    @Published var book: BookSnapshot?
    @Published var chapters: [ChapterSnapshot] = []
    @Published var content: ContentReply?
    @Published var route: ReaderRoute = .search
    @Published var busy = false
    @Published var message: String?
    @Published var importNotice: String?
    @Published var hasSearched = false
    @Published var hasNextPage = false
    private let engine = ReaderEngine()
    private var request: EngineRequest?
    private var generation = UUID()
    @Published private(set) var initialized = false
    private var loadedQuery = ""
    private var loadedSourceID = ""
    private var page: Int32 = 0
    private var retryAction: (() -> Void)?
    var canRetry: Bool { retryAction != nil }

    deinit { engine.close() }

    func sourceChanged() {
        cancel(); results = []; hasSearched = false; hasNextPage = false
    }

    func start() {
        guard !initialized else { return }
        perform(retry: { [weak self] in self?.start() }, start: { engine.initialize(completion: $0) }) { [weak self] reply in
            guard let self, reply is EngineReady else { return }
            self.initialized = true
            self.refreshSources()
        }
    }

    func refreshSources() {
        perform(retry: { [weak self] in self?.refreshSources() }, start: { engine.listSources(completion: $0) }) { [weak self] reply in
            guard let self, let reply = reply as? SourcesReply else { return }
            self.sources = reply.sources
            if !self.sources.contains(where: { $0.id == self.sourceID }) { self.sourceID = self.sources.first?.id ?? "" }
        }
    }

    func importFile(_ url: URL) {
        guard initialized else { return }
        cancel()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { importJSON(try String(contentsOf: url, encoding: .utf8)) }
        catch { reportFileError(error.localizedDescription) }
    }

    func reportFileError(_ detail: String) {
        cancel()
        message = "Unable to import file: \(detail)"
    }

    private func importJSON(_ json: String) {
        importNotice = nil
        perform(retry: { [weak self] in self?.importJSON(json) }, start: { engine.importSources(json: json, completion: $0) }) { [weak self] reply in
            guard let self, let reply = reply as? SourcesReply else { return }
            self.importNotice = "Imported \(reply.sources.count) sources."
            self.results = []; self.chapters = []; self.book = nil; self.content = nil
            self.hasSearched = false; self.hasNextPage = false; self.route = .search
            self.refreshSources()
        }
    }

    func search(more: Bool = false) {
        let text = more ? loadedQuery : query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = more ? loadedSourceID : sourceID
        guard !text.isEmpty, !source.isEmpty else { return }
        let nextPage: Int32 = more ? page + 1 : 1
        if !more { results = []; hasNextPage = false; hasSearched = false }
        route = .search
        perform(retry: { [weak self] in self?.search(more: more) }, start: {
            engine.search(sourceId: source, query: text, page: nextPage, completion: $0)
        }) { [weak self] reply in
            guard let self, let reply = reply as? SearchReply else { return }
            let existing = more ? self.results : []
            var identities = Set(existing.map { $0.sourceId + "\u{0}" + $0.id })
            self.results = existing + reply.books.filter { identities.insert($0.sourceId + "\u{0}" + $0.id).inserted }
            self.page = nextPage; self.loadedQuery = text; self.loadedSourceID = source
            self.hasNextPage = reply.hasNextPage; self.hasSearched = true
        }
    }

    func select(_ selected: BookSnapshot) {
        perform(retry: { [weak self] in self?.select(selected) }, start: {
            engine.loadBook(sourceId: selected.sourceId, bookId: selected.id, completion: $0)
        }) { [weak self] reply in
            guard let self, let reply = reply as? BookReply else { return }
            self.loadContents(reply.book)
        }
    }

    private func loadContents(_ selected: BookSnapshot) {
        perform(retry: { [weak self] in self?.loadContents(selected) }, start: {
            engine.loadToc(sourceId: selected.sourceId, bookId: selected.id, completion: $0)
        }) { [weak self] reply in
            guard let self, let reply = reply as? TocReply else { return }
            self.book = selected; self.chapters = reply.chapters
            self.content = nil; self.route = .contents
        }
    }

    func read(_ chapter: ChapterSnapshot) {
        perform(retry: { [weak self] in self?.read(chapter) }, start: {
            engine.loadChapter(sourceId: chapter.sourceId, bookId: chapter.bookId, chapterId: chapter.id, cacheOnly: false, completion: $0)
        }) { [weak self] reply in
            guard let self, let reply = reply as? ContentReply else { return }
            self.content = reply; self.route = .reading
        }
    }

    var chapterPosition: Int? {
        guard let content else { return nil }
        return chapters.firstIndex { $0.id == content.chapter.id && $0.bookId == content.chapter.bookId && $0.sourceId == content.chapter.sourceId }
    }

    func moveChapter(_ delta: Int) {
        guard let index = chapterPosition, chapters.indices.contains(index + delta) else { return }
        read(chapters[index + delta])
    }

    func navigate(_ target: ReaderRoute) { cancel(); route = target }
    func retry() { retryAction?() }
    func cancel() {
        generation = UUID(); request?.cancel(); request = nil
        busy = false; message = nil; retryAction = nil
    }

    private func perform(retry: @escaping () -> Void, start: (@escaping (EngineReply) -> Void) -> EngineRequest, success: @escaping (EngineReply) -> Void) {
        cancel()
        let token = generation
        busy = true; retryAction = retry
        request = start { [weak self] reply in
            guard let self, self.generation == token else { return }
            self.busy = false; self.request = nil
            if let failure = reply as? EngineFailure {
                if failure.code != .cancelled { self.message = "\(failure.code.name): \(failure.message)" }
                return
            }
            self.retryAction = nil
            success(reply)
        }
    }
}
