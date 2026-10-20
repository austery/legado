import Foundation
import CryptoKit
import ReaderEngine
import SwiftUI

enum ReaderRoute { case shelf, search, sources, details, contents, reading, sourceSwitch }
enum ReaderSearchScope: String, CaseIterable { case all, selected }

@MainActor
final class ReaderModel: ObservableObject {
    enum ReplyStage { case operation, detail, contents, sourceSwitch }
    typealias ReplyDelivery = (ReplyStage, EngineReply, @escaping (EngineReply) -> Void) -> Void
    private let deliverReply: ReplyDelivery

    /// Internal delivery seam; normal app requests apply their real reply immediately.
    init(deliverReply: @escaping ReplyDelivery = { _, reply, apply in apply(reply) }) {
        self.deliverReply = deliverReply
    }

    @Published var shelf: [ShelfBookSnapshot] = []
    @Published var shelfNotice: String?
    @Published private(set) var switchingFrom: BookSnapshot?
    @Published private(set) var switchCandidate: BookSnapshot?
    @Published private(set) var switchChapters: [ChapterSnapshot] = []
    @Published private(set) var preparedSwitch: SourceSwitchPrepared?
    @Published private(set) var committingSwitch = false
    private var switchChapterTitle = ""
    var canChangeSource: Bool {
        guard let book else { return false }
        return shelf.contains { $0.book.id == book.id && $0.book.sourceId == book.sourceId } &&
            !book.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !book.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var recommendedSwitchChapter: ChapterSnapshot? {
        guard !switchChapterTitle.isEmpty else { return nil }
        let matches = switchChapters.filter {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == switchChapterTitle
        }
        return matches.count == 1 ? matches[0] : nil
    }
    func eligibleSwitchCandidate(_ candidate: BookSnapshot) -> Bool {
        guard let original = switchingFrom else { return true }
        return candidate.id != original.id &&
            candidate.title.trimmingCharacters(in: .whitespacesAndNewlines) == original.title.trimmingCharacters(in: .whitespacesAndNewlines) &&
            candidate.author.trimmingCharacters(in: .whitespacesAndNewlines) == original.author.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func beginSourceSwitch() {
        guard canChangeSource, let original = book else { return }
        navigate(.search) { [weak self] in
            guard let self else { return }
            self.switchingFrom = original
            self.switchChapterTitle = (self.content?.chapter.title ??
                self.shelf.first { $0.book.id == original.id && $0.book.sourceId == original.sourceId }?.lastChapter ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.switchCandidate = nil; self.switchChapters = []; self.preparedSwitch = nil
            self.query = original.title
            self.search()
        }
    }
    func cancelSourceSwitch() {
        guard !committingSwitch else { return }
        cancel()
        engine.cancelSourceSwitch { _ in }
        switchingFrom = nil; switchCandidate = nil; switchChapters = []; preparedSwitch = nil
        if content != nil { returnToCurrentReading() } else { route = .details }
    }
    func prepareSourceSwitch(_ chapter: ChapterSnapshot) {
        guard let original = switchingFrom, let candidate = switchCandidate else { return }
        preparedSwitch = nil
        perform(retry: { [weak self] in self?.prepareSourceSwitch(chapter) }, start: {
            self.engine.prepareSourceSwitch(oldSourceId: original.sourceId, oldBookId: original.id,
                sourceId: candidate.sourceId, bookId: candidate.id, chapterId: chapter.id, completion: $0)
        }) { [weak self] reply in
            self?.preparedSwitch = reply as? SourceSwitchPrepared
        }
    }
    func confirmSourceSwitch() {
        guard let prepared = preparedSwitch, !committingSwitch else { return }
        cancel()
        committingSwitch = true; busy = true
        // Confirmation cannot be cancelled. An ambiguous acknowledgment is resolved from Room.
        request = engine.commitSourceSwitch(token: prepared.token) { [weak self] reply in
            guard let self else { return }
            self.deliverReply(.sourceSwitch, reply) { [weak self] reply in
                guard let self else { return }
                self.request = nil
                self.preparedSwitch = nil
                if let entry = reply as? ShelfEntryReply {
                    self.committingSwitch = false; self.busy = false
                    self.finishSourceSwitch(entry)
                } else {
                    let failure = (reply as? EngineFailure)?.message ?? "Switch was not acknowledged."
                    self.engine.openShelfBook(sourceId: prepared.replacementBook.sourceId,
                        bookId: prepared.replacementBook.id) { [weak self] recovered in
                        guard let self else { return }
                        self.committingSwitch = false; self.busy = false
                        if let entry = recovered as? ShelfEntryReply { self.finishSourceSwitch(entry) }
                        else { self.message = failure + " Prepare the chapter again to retry." }
                    }
                }
            }
        }
    }
    private func finishSourceSwitch(_ entry: ShelfEntryReply) {
        switchingFrom = nil; switchCandidate = nil; switchChapters = []; preparedSwitch = nil
        shelf.removeAll { $0.book.title == entry.entry.book.title && $0.book.author == entry.entry.book.author }
        shelf.append(entry.entry)
        acceptShelfEntry(entry)
        resumeCurrentBook()
    }
    @Published var resumeNotice: String?
    @Published var saveNotice: String?
    private var activeReadingToken: String?
    private lazy var positionSaver: ReadingSaveCoordinator = {
        let saver = ReadingSaveCoordinator { [weak self] sample, finishing, completion in
            guard let self, let offset = Int32(exactly: sample.offset) else {
                completion(.failed("Reading position is outside the supported range.")); return
            }
            let received: (EngineReply) -> Void = { reply in
                if let failure = reply as? EngineFailure { completion(.failed(failure.message)) }
                else if reply is ReadingSaved {
                    self.saveNotice = nil
                    completion(.saved)
                }
                else { completion(.failed("Reading position was not acknowledged.")) }
            }
            if finishing {
                self.engine.finishReading(token: sample.token, eventSequence: sample.sequence, utf16Offset: offset, completion: received)
            } else {
                self.engine.saveReadingPosition(token: sample.token, eventSequence: sample.sequence, utf16Offset: offset, completion: received)
            }
        }
        saver.onFailure = { [weak self] message in
            self?.saveNotice = "Position not saved: \(message)"
            self?.busy = false
        }
        return saver
    }()
    @Published var sources: [SourceSnapshot] = []
    @Published var searchScope: ReaderSearchScope = .all {
        didSet { if searchScope != oldValue { sourceChanged() } }
    }
    @Published var selectedSourceIDs: Set<String> = [] {
        didSet { if selectedSourceIDs != oldValue { sourceChanged() } }
    }
    @Published var query = "" {
        didSet { if query != oldValue { retireSearch() } }
    }
    @Published private(set) var searchWorks: [SearchWorkSnapshot] = []
    @Published private(set) var searchSources: [SearchSourceSnapshot] = []
    @Published private(set) var searchRunning = false
    @Published private(set) var searchIncomplete = false
    @Published private(set) var searchCommandPending = false
    @Published private(set) var searchSessionID: String?
    var results: [BookSnapshot] { searchWorks.flatMap { $0.candidates.map(\.book) } }
    @Published var book: BookSnapshot?
    @Published var chapters: [ChapterSnapshot] = []
    @Published var content: ContentReply?
    @Published var route: ReaderRoute = .shelf
    @Published var busy = false
    @Published var message: String?
    @Published var importNotice: String?
    @Published private(set) var importDetails: String?
    @Published var hasSearched = false
    var hasNextPage: Bool {
        searchSessionID != nil && !searchRunning && !searchCommandPending &&
            searchSources.contains { $0.hasNextPage && ($0.status == .success || $0.status == .empty) }
    }
    var canSearch: Bool {
        initialized && !busy && !sources.isEmpty && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (searchScope == .all || !selectedSourceIDs.isEmpty)
    }
    var searchIsEmpty: Bool { hasSearched && !searchRunning && !searchIncomplete && searchWorks.isEmpty }
    var searchProgress: String {
        let finished = searchSources.filter { $0.status != .pending && $0.status != .running }.count
        let failed = searchSources.filter { $0.status == .failed }.count
        let state = searchRunning ? "Searching" : searchIncomplete ? "Incomplete search" : "Search complete"
        return "\(state) · \(finished)/\(searchSources.count) sources" + (failed > 0 ? " · \(failed) failed" : "")
    }
    private var searchRequest: EngineRequest?
    private var searchCommandRequest: EngineRequest?
    private var searchGeneration = UUID()
    private let engine = ReaderEngine()
    private var request: EngineRequest?
    private var generation = UUID()
    @Published private(set) var initialized = false
    private var retryAction: (() -> Void)?
    var canRetry: Bool { retryAction != nil }

    deinit { engine.close() }

    func sourceChanged() {
        cancel(); clearSearch()
    }

    func start() {
        guard !initialized else { return }
        perform(retry: { [weak self] in self?.start() }, start: { self.engine.initialize(completion: $0) }) { [weak self] reply in
            guard let self, reply is EngineReady else { return }
            self.initialized = true
            self.refreshSources(thenShelf: true)
        }
    }

    func refreshSources(thenShelf: Bool = false) {
        perform(retry: { [weak self] in self?.refreshSources(thenShelf: thenShelf) }, start: { self.engine.listSources(completion: $0) }) { [weak self] reply in
            guard let self, let reply = reply as? SourcesReply else { return }
            self.sources = reply.sources
            self.selectedSourceIDs.formIntersection(self.sources.map(\.id))
            if thenShelf { self.refreshShelf() }
        }
    }

    func refreshShelf() {
        perform(retry: { [weak self] in self?.refreshShelf() }, start: { self.engine.listShelf(completion: $0) }) { [weak self] reply in
            guard let self, let reply = reply as? ShelfReply else { return }
            self.shelf = reply.books
        }
    }

    func showShelf() {
        let confirmsSavedPosition = positionSaver.hasPosition
        navigate(.shelf) { [weak self] in
            guard let self else { return }
            if confirmsSavedPosition { self.shelfNotice = "Reading position saved." }
            self.refreshShelf()
        }
    }

    func addCurrentBook() {
        guard let book, !chapters.isEmpty else { return }
        let selected = book
        perform(retry: { [weak self] in self?.addCurrentBook() }, start: {
            self.engine.addToShelf(sourceId: selected.sourceId, bookId: selected.id, completion: $0)
        }) { [weak self] reply in
            guard let self, let reply = reply as? ShelfEntryReply else { return }
            self.acceptShelfEntry(reply)
            self.shelfNotice = reply.entry.book.id == selected.id && reply.entry.book.sourceId == selected.sourceId
                ? "Added to shelf." : "Already on shelf. Kept the original source and saved chapters."
        }
    }

    func openShelfBook(_ entry: ShelfBookSnapshot) {
        perform(retry: { [weak self] in self?.openShelfBook(entry) }, start: {
            self.engine.openShelfBook(sourceId: entry.book.sourceId, bookId: entry.book.id, completion: $0)
        }) { [weak self] reply in
            guard let self, let reply = reply as? ShelfEntryReply else { return }
            self.acceptShelfEntry(reply)
            self.shelfNotice = nil
            self.resumeCurrentBook()
        }
    }

    func removeShelfBook(_ entry: ShelfBookSnapshot) {
        perform(retry: { [weak self] in self?.removeShelfBook(entry) }, start: {
            self.engine.removeFromShelf(sourceId: entry.book.sourceId, bookId: entry.book.id, completion: $0)
        }) { [weak self] reply in
            guard let self, reply is ShelfRemoved else { return }
            self.refreshShelf()
        }
    }

    private func acceptShelfEntry(_ reply: ShelfEntryReply) {
        shelf.removeAll { $0.book.id == reply.entry.book.id && $0.book.sourceId == reply.entry.book.sourceId }
        shelf.append(reply.entry)
        book = reply.entry.book; chapters = reply.chapters
        // Never carry a candidate source's text into a reused shelf identity.
        content = nil; route = .details
    }

    static func authorLabel(_ author: String) -> String {
        author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown author" : author
    }

    func importFile(_ url: URL) {
        guard initialized else { return }
        cancel()
        importDetails = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let json = try String(contentsOf: url, encoding: .utf8)
            let bytes = Data(json.utf8)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            importDetails = "\(url.lastPathComponent)\nDecoded UTF-8: \(bytes.count) bytes\nSHA-256: \(digest)\nApp: \(version) (\(build))"
            importJSON(json)
        }
        catch { reportFileError(error.localizedDescription) }
    }

    func reportFileError(_ detail: String) {
        cancel()
        importDetails = nil
        message = "Unable to import file: \(detail)"
    }

    private func importJSON(_ json: String) {
        importNotice = nil
        perform(retry: { [weak self] in self?.importJSON(json) }, start: { self.engine.importSources(json: json, completion: $0) }) { [weak self] reply in
            guard let self, let reply = reply as? SourcesReply else { return }
            self.importNotice = "Imported \(reply.sources.count) sources."
            self.clearSearch(); self.chapters = []; self.book = nil; self.content = nil
            self.route = .sources
            self.refreshSources()
        }
    }

    private func clearSearch() {
        searchWorks = []; searchSources = []; hasSearched = false; searchIncomplete = false
    }

    private func retireSearch() {
        searchGeneration = UUID()
        searchRequest?.cancel(); searchRequest = nil
        searchCommandRequest?.cancel(); searchCommandRequest = nil
        if searchRunning { searchIncomplete = true }
        searchRunning = false; searchCommandPending = false; searchSessionID = nil
    }

    func search() {
        guard canSearch else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceIDs = searchScope == .all ? [] : selectedSourceIDs.sorted()
        cancel(); clearSearch()
        let token = generation
        let searchToken = searchGeneration
        busy = true
        finishReading { [weak self] in
            guard let self, self.generation == token, self.searchGeneration == searchToken else { return }
            self.route = .search; self.busy = false; self.searchRunning = true; self.hasSearched = true
            self.searchRequest = self.engine.startSearch(query: text, sourceIds: sourceIDs) { [weak self] reply in
                guard let self, self.searchGeneration == searchToken else { return }
                if let error = reply as? EngineFailure {
                    self.searchRunning = false; self.searchIncomplete = true; self.searchRequest = nil
                    if error.code != .cancelled { self.message = "\(error.code.name): \(error.message)" }
                    return
                }
                guard let update = reply as? SearchUpdate,
                      self.searchSessionID == nil || self.searchSessionID == update.sessionId else { return }
                self.searchSessionID = update.sessionId
                self.searchWorks = update.works; self.searchSources = update.sources
                self.searchRunning = update.phase == .searching
                self.searchIncomplete = update.phase == .cancelled || update.sources.contains { $0.status == .failed || $0.status == .cancelled }
                let failures = update.sources.compactMap { source -> String? in
                    guard let failure = source.failure else { return nil }
                    return "\(source.name): \(failure.code.name): \(failure.message)"
                }
                self.message = failures.isEmpty ? nil : failures.joined(separator: "\n")
                if update.phase == .cancelled { self.retireSearch() }
                // IDLE retains the subscription for pagination, retry and restart updates.
            }
        }
    }

    func loadMoreSearch() {
        guard hasNextPage else { return }
        searchCommand { self.engine.loadMoreSearch(searchSessionId: $0, completion: $1) }
    }

    func retrySearchSource(_ sourceID: String) {
        searchCommand { self.engine.retrySearchSource(searchSessionId: $0, sourceId: sourceID, completion: $1) }
    }

    func restartSearchSource(_ sourceID: String) {
        searchCommand { self.engine.restartSearchSource(searchSessionId: $0, sourceId: sourceID, completion: $1) }
    }

    func stopSearch() {
        guard searchRunning else { return }
        searchIncomplete = true
        guard searchSessionID != nil else { retireSearch(); return }
        searchCommand(stopping: true) { self.engine.cancelSearch(searchSessionId: $0, completion: $1) }
    }

    private func searchCommand(stopping: Bool = false, start: (String, @escaping (EngineReply) -> Void) -> EngineRequest) {
        guard let sessionID = searchSessionID, !searchCommandPending, !busy else { return }
        let token = searchGeneration
        searchCommandPending = true
        searchCommandRequest = start(sessionID) { [weak self] reply in
            guard let self, self.searchGeneration == token, self.searchSessionID == sessionID else { return }
            self.searchCommandPending = false; self.searchCommandRequest = nil
            if let failure = reply as? EngineFailure, failure.code != .cancelled {
                self.message = "\(failure.code.name): \(failure.message)"
            }
            if stopping { self.retireSearch(); self.searchIncomplete = true }
        }
    }

    func select(_ selected: BookSnapshot) {
        guard eligibleSwitchCandidate(selected) else { return }
        perform(stage: .detail, retry: { [weak self] in self?.select(selected) }, start: {
            self.engine.loadBook(sourceId: selected.sourceId, bookId: selected.id, completion: $0)
        }) { [weak self] reply in
            guard let self, let reply = reply as? BookReply else { return }
            self.loadContents(reply.book)
        }
    }

    private func loadContents(_ selected: BookSnapshot) {
        perform(stage: .contents, retry: { [weak self] in self?.loadContents(selected) }, start: {
            self.engine.loadToc(sourceId: selected.sourceId, bookId: selected.id, completion: $0)
        }) { [weak self] reply in
            guard let self, let reply = reply as? TocReply else { return }
            if self.switchingFrom != nil {
                self.switchCandidate = selected; self.switchChapters = reply.chapters.filter { !$0.isVolume }
                self.preparedSwitch = nil; self.route = .sourceSwitch
                return
            }
            self.shelfNotice = nil
            self.book = selected; self.chapters = reply.chapters
            self.content = nil; self.route = .details
        }
    }

    func read(_ chapter: ChapterSnapshot) {
        let previous = content
        perform(retry: { [weak self] in self?.read(chapter) }, failure: { [weak self] _ in
            guard let previous, previous.reading?.canSave == true else { return }
            self?.recoverDisplayedReading(previous)
        }, start: {
            self.engine.loadChapter(sourceId: chapter.sourceId, bookId: chapter.bookId, chapterId: chapter.id, cacheOnly: false, completion: $0)
        }) { [weak self] reply in
            guard let self, let reply = reply as? ContentReply else { return }
            self.acceptContent(reply)
        }
    }

    private func recoverDisplayedReading(_ previous: ContentReply) {
        let token = generation
        busy = true
        request = engine.openReading(sourceId: previous.chapter.sourceId, bookId: previous.chapter.bookId, cacheOnly: true) { [weak self] reply in
            guard let self, self.generation == token else { return }
            self.busy = false; self.request = nil
            if let restored = reply as? ContentReply {
                self.acceptContent(restored)
            } else {
                self.resumeNotice = "Previous text remains visible, but its saved position could not be reopened. Retry before continuing."
            }
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

    /// Directory return uses the retained view for session-only text. Reopening
    /// a persistent position would require shelf membership or select an older chapter.
    func returnToCurrentReading() {
        guard !busy, let content else { return }
        if content.reading?.canSave == true {
            resumeCurrentBook()
        } else {
            navigate(.reading)
        }
    }

    func resumeCurrentBook() {
        guard let book else { return }
        perform(retry: { [weak self] in self?.resumeCurrentBook() }, start: {
            self.engine.openReading(sourceId: book.sourceId, bookId: book.id, cacheOnly: false, completion: $0)
        }) { [weak self] reply in
            guard let reply = reply as? ContentReply else { return }
            self?.acceptContent(reply)
        }
    }

    private func acceptContent(_ reply: ContentReply) {
        content = reply; route = .reading
        saveNotice = reply.storageNotice.isEmpty ? nil : reply.storageNotice
        activeReadingToken = reply.reading?.token
        resumeNotice = reply.reading?.restoreNotice.isEmpty == false ? reply.reading?.restoreNotice : nil
    }

    var readingRestoration: ReadingRestoration? {
        guard let reading = content?.reading else { return nil }
        return ReadingRestoration(identity: reading.token, utf16Offset: Int(reading.paragraphUtf16Offset))
    }

    func readingDisplayed(_ token: String, _ offset: Int) {
        guard route == .reading, activeReadingToken == token, content?.reading?.canSave == true else { return }
        positionSaver.displayed(token: token, offset: offset)
    }

    func readingScrolled(_ token: String, _ offset: Int) {
        guard route == .reading, activeReadingToken == token, content?.reading?.canSave == true else { return }
        positionSaver.sample(token: token, offset: offset)
    }

    var canRetryPosition: Bool { positionSaver.hasPosition && content?.reading?.canSave == true }

    func flushReadingPosition() { positionSaver.flush() }

    /// Called only after the user confirms losing the unsaved position.
    func discardPositionAndReturnToShelf() {
        cancel()
        let readingToken = activeReadingToken
        activeReadingToken = nil
        positionSaver.discard()
        content = nil
        saveNotice = nil
        resumeNotice = nil
        route = .shelf
        if let readingToken {
            engine.abandonReading(token: readingToken) { [weak self] reply in
                if let failure = reply as? EngineFailure { self?.shelfNotice = failure.message }
            }
        }
        refreshShelf()
    }

    func cancelLoading() {
        let previous = content
        let needsRecovery = previous?.reading?.canSave == true && route == .reading
        cancel()
        if needsRecovery, let previous {
            finishReading { [weak self] in self?.recoverDisplayedReading(previous) }
        }
    }

    private func finishReading(then action: @escaping () -> Void) {
        guard let token = activeReadingToken else { action(); return }
        let finished = { [weak self] in
            self?.activeReadingToken = nil
            action()
        }
        if positionSaver.hasPosition {
            positionSaver.finish(then: finished)
        } else {
            self.engine.abandonReading(token: token) { [weak self] reply in
                if let failure = reply as? EngineFailure {
                    self?.resumeNotice = failure.message; self?.busy = false
                } else { finished() }
            }
        }
    }

    func navigate(_ target: ReaderRoute, then action: (() -> Void)? = nil) {
        cancel()
        let token = generation
        busy = true
        finishReading { [weak self] in
            guard let self, self.generation == token else { return }
            self.route = target; self.busy = false
            action?()
        }
    }
    func retry() { retryAction?() }
    func cancel() {
        guard !committingSwitch else { return }
        retireSearch()
        generation = UUID(); request?.cancel(); request = nil
        busy = false; message = nil; retryAction = nil
    }

    private func perform(stage: ReplyStage = .operation, retry: @escaping () -> Void, failure: ((EngineFailure) -> Void)? = nil, start: @escaping (@escaping (EngineReply) -> Void) -> EngineRequest, success: @escaping (EngineReply) -> Void) {
        cancel()
        let token = generation
        busy = true; retryAction = retry
        finishReading { [weak self] in
            guard let self, self.generation == token else { return }
            self.request = start { [weak self] reply in
                guard let self else { return }
                self.deliverReply(stage, reply) { [weak self] reply in
                    guard let self, self.generation == token else { return }
                    self.busy = false; self.request = nil
                    if let error = reply as? EngineFailure {
                        if error.code != .cancelled {
                            self.message = "\(error.code.name): \(error.message)"
                            failure?(error)
                        }
                        return
                    }
                    self.retryAction = nil
                    success(reply)
                }
            }
        }
    }
}
