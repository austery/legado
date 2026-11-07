import Foundation
import CryptoKit
import ReaderEngine
import SwiftUI

enum ReaderRoute { case shelf, search, sources, discovery, details, contents, reading, sourceSwitch }
enum ReaderSearchScope: String, CaseIterable { case all, selected }

@MainActor
final class ReaderModel: ObservableObject {
    enum ReplyStage { case operation, detail, contents, sourceSwitch, cachedSearch }
    typealias ReplyDelivery = (ReplyStage, EngineReply, @escaping (EngineReply) -> Void) -> Void
    private let deliverReply: ReplyDelivery

    /// Internal delivery seam; normal app requests apply their real reply immediately.
    init(deliverReply: @escaping ReplyDelivery = { _, reply, apply in apply(reply) }) {
        self.deliverReply = deliverReply
    }

    @Published var cachedSearchPresented = false
    @Published var cachedSearchQuery = "" {
        didSet {
            if !cachedSearchQuery.utf16.elementsEqual(oldValue.utf16) { resetCachedSearch() }
        }
    }
    @Published private(set) var cachedSearchResults: CachedChapterResults?
    @Published private(set) var cachedSearchNotice: String?
    @Published private(set) var cachedSearchBusy = false
    @Published private(set) var cachedSearchSelection: CachedSearchSelection?
    private var cachedSearchRequest: EngineRequest?
    private var cachedSearchGeneration = UUID()

    func showCachedSearch() {
        guard isShelved, !busy, route == .reading else { return }
        resetCachedSearch()
        cachedSearchQuery = ""
        cachedSearchPresented = true
    }

    private func resetCachedSearch() {
        cachedSearchRequest?.cancel(); cachedSearchRequest = nil
        cachedSearchGeneration = UUID()
        cachedSearchBusy = false; cachedSearchResults = nil; cachedSearchNotice = nil
    }

    func closeCachedSearch() {
        resetCachedSearch()
        cachedSearchPresented = false
    }

    func cancelCachedSearch() {
        resetCachedSearch()
        cachedSearchNotice = "Search cancelled."
    }

    func searchCachedChapters() {
        guard let book, isShelved, !busy else { return }
        resetCachedSearch()
        guard !cachedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let stamp = cachedSearchGeneration
        let context = generation
        cachedSearchBusy = true
        cachedSearchRequest = engine.searchCachedChapters(sourceId: book.sourceId, bookId: book.id, query: cachedSearchQuery) { [weak self] reply in
            guard let self else { return }
            self.deliverReply(.cachedSearch, reply) { [weak self] reply in
                guard let self, self.generation == context, self.cachedSearchGeneration == stamp,
                      self.cachedSearchPresented else { return }
                self.cachedSearchBusy = false; self.cachedSearchRequest = nil
                if let result = reply as? CachedChapterResults { self.cachedSearchResults = result }
                if let failure = reply as? EngineFailure { self.cachedSearchNotice = failure.message }
            }
        }
    }

    func openCachedSearchHit(_ hit: CachedChapterHit) {
        guard !busy, !cachedSearchBusy, let book,
              book.id == hit.bookId, book.sourceId == hit.sourceId,
              cachedSearchResults?.hits.contains(where: { $0 === hit }) == true else { return }
        let previous = content
        closeCachedSearch()
        perform(retry: { [weak self] in self?.showCachedSearch() }, failure: { [weak self] failure in
            guard let self else { return }
            self.cachedSearchPresented = true
            self.cachedSearchNotice = failure.message
            self.message = nil; self.retryAction = nil
            if let previous, previous.reading?.canSave == true { self.recoverDisplayedReading(previous, allowPrefetch: false) }
        }, start: { self.engine.openCachedSearchHit(hit: hit, completion: $0) }) { [weak self] reply in
            guard let self, let result = reply as? ContentReply, let reading = result.reading else { return }
            self.acceptContent(result, allowPrefetch: false)
            self.cachedSearchSelection = CachedSearchSelection(token: reading.token, query: hit.query,
                range: NSRange(location: Int(hit.utf16Offset), length: Int(hit.utf16Length)))
        }
    }

    @Published var bookmarksPresented = false
    @Published private(set) var bookmarks: [BookmarkSnapshot] = []
    @Published private(set) var bookmarkNotice: String?
    @Published private(set) var bookmarkBusy = false
    @Published private(set) var canRetryBookmark = false
    private var bookmarkOffset: Int?
    @Published private var bookmarkPositionAvailable = false
    private var bookmarkRequest: EngineRequest?
    private var bookmarkGeneration = UUID()
    private var bookmarkRetry: (() -> Void)?

    var canSaveBookmark: Bool {
        isShelved && !busy && !bookmarkBusy && bookmarkPositionAvailable && activeReadingToken != nil && content?.reading?.canSave == true
    }

    func showBookmarks() {
        guard isShelved, !busy else { return }
        bookmarks = []
        bookmarksPresented = true
        refreshBookmarks()
    }

    func closeBookmarks() {
        bookmarksPresented = false
        bookmarkRequest?.cancel()
        bookmarkRequest = nil
        bookmarkGeneration = UUID()
        bookmarkBusy = false
    }

    func refreshBookmarks() {
        guard let book, isShelved else { return }
        bookmarkRequest?.cancel()
        let stamp = UUID(); bookmarkGeneration = stamp
        let context = generation
        bookmarkBusy = true; bookmarkNotice = nil; canRetryBookmark = false
        bookmarkRequest = engine.listBookmarks(sourceId: book.sourceId, bookId: book.id) { [weak self] reply in
            guard let self, self.generation == context, self.bookmarkGeneration == stamp else { return }
            self.bookmarkBusy = false; self.bookmarkRequest = nil
            if let result = reply as? BookmarksReply { self.bookmarks = result.bookmarks }
            if let failure = reply as? EngineFailure {
                self.bookmarkNotice = failure.message
                self.bookmarkRetry = { [weak self] in self?.showBookmarks() }
                self.canRetryBookmark = true
            }
        }
    }

    func saveCurrentBookmark() {
        guard canSaveBookmark, let token = activeReadingToken, let offset = bookmarkOffset else { return }
        saveBookmark(token: token, offset: offset)
    }

    private func saveBookmark(token: String, offset: Int) {
        guard activeReadingToken == token, route == .reading else {
            bookmarkNotice = "Reading session changed. Save the current paragraph again."
            canRetryBookmark = false
            return
        }
        let context = generation
        bookmarkBusy = true; bookmarkNotice = nil; canRetryBookmark = false
        engine.saveBookmark(token: token, utf16Offset: Int32(offset)) { [weak self] reply in
            guard let self, self.generation == context, self.activeReadingToken == token else { return }
            self.bookmarkBusy = false
            if reply is BookmarkSaved { self.bookmarkNotice = "Bookmark saved."; self.bookmarkRetry = nil }
            if let failure = reply as? EngineFailure {
                self.bookmarkNotice = failure.message
                self.bookmarkRetry = { [weak self] in self?.saveBookmark(token: token, offset: offset) }
                self.canRetryBookmark = true
            }
        }
    }

    func retryBookmark() { bookmarkRetry?() }

    func deleteBookmark(_ bookmark: BookmarkSnapshot) {
        guard let book, !bookmarkBusy else { return }
        let context = generation
        let stamp = UUID(); bookmarkGeneration = stamp
        bookmarkBusy = true; bookmarkNotice = nil; canRetryBookmark = false
        bookmarkRequest = engine.deleteBookmark(sourceId: book.sourceId, bookId: book.id, bookmarkId: bookmark.id) { [weak self] reply in
            guard let self, self.generation == context, self.bookmarkGeneration == stamp else { return }
            self.bookmarkBusy = false; self.bookmarkRequest = nil
            if let result = reply as? BookmarksReply { self.bookmarks = result.bookmarks }
            if let failure = reply as? EngineFailure {
                self.bookmarkNotice = failure.message
                self.bookmarkRetry = { [weak self] in
                    guard let self else { return }
                    self.bookmarksPresented = true
                    self.deleteBookmark(bookmark)
                }
                self.canRetryBookmark = true
            }
        }
    }

    func openBookmark(_ bookmark: BookmarkSnapshot) {
        guard let book, !busy, !bookmarkBusy, bookmark.availableInCurrentSource else { return }
        let previous = content
        closeBookmarks()
        bookmarkNotice = nil
        perform(retry: { [weak self] in self?.openBookmark(bookmark) }, failure: { [weak self] failure in
            self?.bookmarkNotice = failure.message
            self?.bookmarkRetry = { [weak self] in self?.openBookmark(bookmark) }
            self?.canRetryBookmark = true
            if let previous, previous.reading?.canSave == true { self?.recoverDisplayedReading(previous) }
        }, start: {
            self.engine.openBookmark(sourceId: book.sourceId, bookId: book.id, bookmarkId: bookmark.id, completion: $0)
        }) { [weak self] reply in
            guard let self, let result = reply as? ContentReply else { return }
            self.acceptContent(result)
            self.closeBookmarks()
        }
    }

    @Published var shelf: [ShelfBookSnapshot] = []
    @Published private(set) var shelfGroups: [ShelfGroupSnapshot] = []
    @Published private(set) var shelfToken = ""
    @Published private(set) var shelfSort: ShelfSort = .recentRead
    @Published private(set) var shelfGroupID: String?
    var currentShelfGroup: ShelfGroupSnapshot? { shelfGroups.first { $0.id == shelfGroupID } }
    var visibleShelfBooks: [ShelfBookSnapshot] {
        if let group = currentShelfGroup {
            let booksByID = Dictionary(uniqueKeysWithValues: shelf.map { ($0.book.id, $0) })
            return group.orderedBookIds.compactMap { booksByID[$0] }
        }
        return shelf.filter { $0.groupIds.isEmpty }
    }
    func openShelfGroup(_ id: String?) {
        guard id == nil || shelfGroups.contains(where: { $0.id == id }) else { return }
        shelfGroupID = id
    }
    @Published private(set) var offlineStatus: OfflineStatus?
    @Published private(set) var cacheProgress: CacheProgress?
    @Published private(set) var cacheNotice: String?
    @Published var cacheClearPlan: CacheClearPrepared?
    private var cacheRequest: EngineRequest?
    private var cacheGeneration = UUID()
    private var statusGeneration = UUID()
    private var foregroundActive = true
    private var prefetchEnabled = false
    var isShelved: Bool {
        guard let book else { return false }
        return shelf.contains { $0.book.id == book.id && $0.book.sourceId == book.sourceId }
    }
    func offlineLabel(_ chapter: ChapterSnapshot) -> String {
        guard !chapter.isVolume, isShelved else { return "" }
        guard let state = offlineStatus?.chapters.first(where: { $0.chapterId == chapter.id }) else { return "Checking…" }
        switch state.availability {
        case .available: return "Available offline"
        case .missing: return "Not cached"
        default: return "Unavailable after validation"
        }
    }
    func refreshOfflineStatus() {
        guard isShelved, let book else { offlineStatus = nil; return }
        let generation = UUID(); statusGeneration = generation
        engine.offlineStatus(sourceId: book.sourceId, bookId: book.id) { [weak self] reply in
            guard let self, self.statusGeneration == generation,
                  self.book?.id == book.id, self.book?.sourceId == book.sourceId else { return }
            self.offlineStatus = reply as? OfflineStatus
            if let failure = reply as? EngineFailure { self.cacheNotice = failure.message }
        }
    }
    func cacheNextChapters(prefetch: Bool = false) {
        guard isShelved, let book, foregroundActive, !busy,
              !prefetch || (prefetchEnabled && content != nil) else { return }
        cancelCaching()
        cacheNotice = nil
        let generation = UUID(); cacheGeneration = generation
        cacheRequest = engine.cacheNextChapters(sourceId: book.sourceId, bookId: book.id,
            afterChapterId: content?.chapter.id, prefetch: prefetch) { [weak self] reply in
            guard let self, self.cacheGeneration == generation,
                  self.book?.id == book.id, self.book?.sourceId == book.sourceId else { return }
            if let progress = reply as? CacheProgress {
                self.cacheProgress = progress
                if !progress.running { self.cacheRequest = nil; self.refreshOfflineStatus() }
            } else if let failure = reply as? EngineFailure {
                self.cacheNotice = failure.message; self.cacheRequest = nil
                self.refreshOfflineStatus()
            }
        }
    }
    func cancelCaching() {
        cacheRequest?.cancel(); cacheRequest = nil
        engine.cancelCaching()
    }
    func setPrefetchEnabled(_ enabled: Bool) {
        prefetchEnabled = enabled
        if enabled { cacheNextChapters(prefetch: true) } else { cancelCaching() }
    }
    func setForegroundActive(_ active: Bool) {
        foregroundActive = active
        if !active { cancelCaching() }
    }
    func prepareCacheClear() {
        guard isShelved, let book else { return }
        cancelCaching()
        engine.prepareCacheClear(sourceId: book.sourceId, bookId: book.id) { [weak self] reply in
            guard let self, self.book?.id == book.id, self.book?.sourceId == book.sourceId else { return }
            self.cacheClearPlan = reply as? CacheClearPrepared
            if let failure = reply as? EngineFailure { self.cacheNotice = failure.message }
        }
    }
    func confirmCacheClear() {
        guard let plan = cacheClearPlan else { return }
        cacheClearPlan = nil
        engine.clearOptionalCache(token: plan.token) { [weak self] reply in
            if let result = reply as? CacheCleared {
                self?.cacheNotice = "Removed \(result.deleted) chapters. \(result.failed) could not be removed."
            } else if let failure = reply as? EngineFailure { self?.cacheNotice = failure.message }
            self?.refreshOfflineStatus()
        }
    }
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
                    self.engine.recoverSourceSwitch(token: prepared.token) { [weak self] recovered in
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
    @Published var managedSources: [ManagedSource] = []
    @Published var managedSelection: Set<String> = []
    private var sourceImportJSON: String?
    @Published var sourceImportPreview: SourceImportPreview?
    @Published var sourceImportSelection: Set<String> = []
    @Published var importKeepName = true
    @Published var importKeepGroups = true
    @Published var importKeepEnabled = true
    @Published var sourceExportJSON: String?
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
    lazy var discovery = DiscoveryModel(engine: engine)
    @Published private(set) var detailReturnRoute: ReaderRoute = .search
    private var preservingDiscoveryContext: Bool {
        detailReturnRoute == .discovery && !discovery.loading &&
            (route == .discovery || route == .details || route == .contents || route == .reading)
    }
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

    func refreshSources(thenShelf: Bool = false, thenManaged: Bool = false) {
        perform(retry: { [weak self] in self?.refreshSources(thenShelf: thenShelf, thenManaged: thenManaged) }, start: { self.engine.listSources(completion: $0) }) { [weak self] reply in
            guard let self, let reply = reply as? SourcesReply else { return }
            self.sources = reply.sources
            self.selectedSourceIDs.formIntersection(self.sources.map(\.id))
            if thenShelf { self.refreshShelf() }
            else if thenManaged { self.refreshManagedSources() }
        }
    }

    func checkNewChapters(_ entry: ShelfBookSnapshot) {
        perform(preservingReading: true, retry: { [weak self] in self?.checkNewChapters(entry) }, start: {
            self.engine.checkNewChapters(sourceId: entry.book.sourceId, bookId: entry.book.id, completion: $0)
        }) { [weak self] reply in
            guard let self, let result = reply as? ChapterUpdateReply else { return }
            let notice = result.added == 0 ? "No new chapters" :
                (result.added == 1 ? "Added 1 new chapter" : "Added \(result.added) new chapters")
            self.acceptShelfOrganization(result.shelf)
            if self.book?.id == entry.book.id && self.book?.sourceId == entry.book.sourceId {
                self.chapters = result.chapters
            }
            self.message = notice
        }
    }

    func refreshShelf(preservingMessage: String? = nil, preservingReading: Bool = false) {
        perform(preservingReading: preservingReading, retry: { [weak self] in self?.refreshShelf(preservingMessage: preservingMessage, preservingReading: preservingReading) }, start: { self.engine.listShelf(completion: $0) }) { [weak self] reply in
            guard let self, let reply = reply as? ShelfReply else { return }
            self.acceptShelfOrganization(reply)
            if let preservingMessage { self.message = preservingMessage }
        }
    }

    private func acceptShelfOrganization(_ reply: ShelfReply) {
        shelf = reply.books; shelfGroups = reply.groups; shelfToken = reply.token
        shelfSort = ShelfSort(rawValue: reply.sortMode) ?? .recentRead
        if let shelfGroupID, !shelfGroups.contains(where: { $0.id == shelfGroupID }) { self.shelfGroupID = nil }
    }

    func setShelfSort(_ mode: ShelfSort) {
        perform(retry: { [weak self] in self?.setShelfSort(mode) },
            start: { self.engine.setShelfSort(mode: mode.rawValue, completion: $0) }) { [weak self] reply in
            guard let reply = reply as? ShelfReply else { return }
            self?.acceptShelfOrganization(reply)
        }
    }

    func createShelfGroup(_ name: String, expectedToken: String? = nil, completion: @escaping (Bool) -> Void = { _ in }) {
        mutateShelf(expectedToken: expectedToken, completion: completion) { token, reply in
            self.engine.createShelfGroup(name: name, expectedToken: token, completion: reply)
        }
    }

    func renameShelfGroup(_ group: ShelfGroupSnapshot, name: String, expectedToken: String? = nil,
                          completion: @escaping (Bool) -> Void = { _ in }) {
        mutateShelf(expectedToken: expectedToken, completion: completion) { token, reply in
            self.engine.renameShelfGroup(groupId: group.id, name: name, expectedToken: token, completion: reply)
        }
    }

    func deleteShelfGroup(_ group: ShelfGroupSnapshot, expectedToken: String? = nil,
                          completion: @escaping (Bool) -> Void = { _ in }) {
        mutateShelf(expectedToken: expectedToken, completion: completion) { token, reply in
            self.engine.deleteShelfGroup(groupId: group.id, expectedToken: token, completion: reply)
        }
    }

    func changeShelfGroups(_ entries: [ShelfBookSnapshot], add: [String], remove: [String],
                           expectedToken: String? = nil, completion: @escaping (Bool) -> Void = { _ in }) {
        let targets = entries.map { ShelfBookTarget(sourceId: $0.book.sourceId, bookId: $0.book.id) }
        mutateShelf(expectedToken: expectedToken, completion: completion) { token, reply in
            self.engine.changeShelfGroups(targets: targets, addGroupIds: add, removeGroupIds: remove,
                                          expectedToken: token, completion: reply)
        }
    }

    func removeShelfBooks(_ entries: [ShelfBookSnapshot], expectedToken: String? = nil,
                          completion: @escaping (Bool) -> Void = { _ in }) {
        let targets = entries.map { ShelfBookTarget(sourceId: $0.book.sourceId, bookId: $0.book.id) }
        mutateShelf(expectedToken: expectedToken, completion: completion) { token, reply in
            self.engine.removeShelfBooks(targets: targets, expectedToken: token, completion: reply)
        }
    }

    private func mutateShelf(expectedToken: String?, completion: @escaping (Bool) -> Void,
                             start: @escaping (String, @escaping (EngineReply) -> Void) -> EngineRequest) {
        guard !busy else { completion(false); return }
        let token = expectedToken ?? shelfToken
        perform(retry: { [weak self] in self?.refreshShelf() }, failure: { [weak self] failure in
            self?.message = failure.message
            completion(false)
            if failure.code == .staleUpdate { self?.refreshShelf(preservingMessage: failure.message) }
        }, start: { start(token, $0) }) { [weak self] reply in
            guard let self, let state = reply as? ShelfReply else { completion(false); return }
            self.shelfNotice = nil
            self.acceptShelfOrganization(state)
            completion(true)
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
        detailReturnRoute = .search
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
        offlineStatus = nil; cacheProgress = nil; cacheNotice = nil; cacheClearPlan = nil
        // Never carry a candidate source's text into a reused shelf identity.
        content = nil; route = .details
        refreshOfflineStatus()
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
        sourceImportJSON = json
        importNotice = nil
        perform(retry: { [weak self] in self?.importJSON(json) }, start: {
            self.engine.previewSourceImport(json: json, completion: $0)
        }) { [weak self] reply in
            guard let self, let preview = reply as? SourceImportPreview else { return }
            self.sourceImportSelection = Set(preview.items.filter(\.selectedByDefault).map { $0.source.id })
            self.importKeepName = true; self.importKeepGroups = true; self.importKeepEnabled = true
            self.sourceImportPreview = preview
        }
    }

    func refreshSourceImportPreview() {
        guard let json = sourceImportJSON else { return }
        importJSON(json)
    }

    func cancelSourceImport() {
        sourceImportJSON = nil
        sourceImportPreview = nil
        sourceImportSelection = []
        engine.cancelSourceImport { _ in }
    }

    func confirmSourceImport() {
        guard let preview = sourceImportPreview, !sourceImportSelection.isEmpty else { return }
        let ids = Array(sourceImportSelection)
        perform(retry: { [weak self] in self?.confirmSourceImport() }, start: {
            self.engine.commitSourceImport(token: preview.token, ids: ids,
                keepName: self.importKeepName, keepGroups: self.importKeepGroups,
                keepEnabled: self.importKeepEnabled, completion: $0)
        }) { [weak self] reply in
            guard let self, let committed = reply as? SourceImportCommitted else { return }
            self.sourceImportPreview = nil; self.sourceImportSelection = []
            self.importNotice = "Imported \(committed.count) sources."
            self.chapters = []; self.book = nil; self.content = nil; self.route = .sources
            self.clearSearch()
            self.refreshSources(thenManaged: true)
        }
    }

    func refreshManagedSources() {
        guard initialized else { return }
        perform(preservingReading: true, retry: { [weak self] in self?.refreshManagedSources() }, start: {
            self.engine.listManagedSources(completion: $0)
        }) { [weak self] reply in self?.acceptManagedSources(reply) }
    }

    private func acceptManagedSources(_ reply: EngineReply) {
        guard let result = reply as? ManagedSourcesReply else { return }
        managedSources = result.sources
        managedSelection.formIntersection(result.sources.map(\.id))
    }

    func setSourcesEnabled(_ ids: [String], enabled: Bool) {
        perform(retry: { [weak self] in self?.setSourcesEnabled(ids, enabled: enabled) }, start: {
            self.engine.setSourcesEnabled(ids: ids, enabled: enabled, completion: $0)
        }) { [weak self] reply in
            guard let self else { return }
            self.acceptManagedSources(reply)
            self.retireSearch(); self.clearSearch(); self.refreshSources(thenManaged: true)
        }
    }

    /// Shelf books whose current source is in `ids`; they stay on the shelf after deletion.
    func shelfBookCount(forSources ids: Set<String>) -> Int {
        shelf.filter { ids.contains($0.book.sourceId) }.count
    }

    func deleteSources(_ ids: [String]) {
        perform(retry: { [weak self] in self?.deleteSources(ids) }, failure: { [weak self] _ in
            // Cleanup after commit can fail with the rows already gone; show the stored list
            // without `perform`, which would clear the failure message.
            _ = self?.engine.listManagedSources { reply in self?.acceptManagedSources(reply) }
        }, start: {
            self.engine.deleteSources(ids: ids, completion: $0)
        }) { [weak self] reply in
            guard let self, reply is ManagedSourcesReply else { return }
            self.acceptManagedSources(reply)
            self.importNotice = "Deleted \(ids.count) source\(ids.count == 1 ? "" : "s")."
            // Managed sources came with the reply; refresh search scope, then shelf source names.
            self.retireSearch(); self.clearSearch(); self.refreshSources(thenShelf: true)
            self.discovery.reloadSources()
        }
    }

    func setSourceDiscoveryEnabled(_ id: String, enabled: Bool) {
        perform(retry: { [weak self] in self?.setSourceDiscoveryEnabled(id, enabled: enabled) }, start: {
            self.engine.setSourceDiscoveryEnabled(ids: [id], enabled: enabled, completion: $0)
        }) { [weak self] reply in
            self?.acceptManagedSources(reply)
            self?.discovery.reloadSources()
        }
    }

    func changeSourceGroup(_ ids: [String], group: String, add: Bool, onCommitted: (() -> Void)? = nil) {
        perform(retry: { [weak self] in self?.changeSourceGroup(ids, group: group, add: add, onCommitted: onCommitted) }, start: {
            self.engine.changeSourceGroup(ids: ids, group: group, add: add, completion: $0)
        }) { [weak self] reply in
            self?.acceptManagedSources(reply)
            onCommitted?()
        }
    }

    func exportSources(_ ids: [String]) {
        perform(preservingReading: true, retry: { [weak self] in self?.exportSources(ids) }, start: {
            self.engine.exportSources(ids: ids, completion: $0)
        }) { [weak self] reply in
            guard let result = reply as? SourceExportReply else { return }
            self?.sourceExportJSON = result.json
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
        if route == .discovery { detailReturnRoute = .discovery }
        else if route == .search { detailReturnRoute = .search }
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

    private func recoverDisplayedReading(_ previous: ContentReply, allowPrefetch: Bool = true) {
        let token = generation
        busy = true
        request = engine.openReading(sourceId: previous.chapter.sourceId, bookId: previous.chapter.bookId, cacheOnly: true) { [weak self] reply in
            guard let self, self.generation == token else { return }
            self.busy = false; self.request = nil
            if let restored = reply as? ContentReply {
                self.acceptContent(restored, allowPrefetch: allowPrefetch)
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

    private func acceptContent(_ reply: ContentReply, allowPrefetch: Bool = true) {
        cachedSearchSelection = nil
        bookmarkOffset = nil
        bookmarkPositionAvailable = false
        bookmarkBusy = false
        content = reply; route = .reading
        saveNotice = reply.storageNotice.isEmpty ? nil : reply.storageNotice
        activeReadingToken = reply.reading?.token
        resumeNotice = reply.reading?.restoreNotice.isEmpty == false ? reply.reading?.restoreNotice : nil
        refreshOfflineStatus()
        // Deliver content first; automatic work is bounded and never restores a prior batch.
        if allowPrefetch { Task { [weak self] in self?.cacheNextChapters(prefetch: true) } }
    }

    var readingRestoration: ReadingRestoration? {
        guard let reading = content?.reading else { return nil }
        return ReadingRestoration(identity: reading.token, utf16Offset: Int(reading.paragraphUtf16Offset))
    }

    func readingDisplayed(_ token: String, _ offset: Int) {
        guard route == .reading, activeReadingToken == token, content?.reading?.canSave == true else { return }
        bookmarkOffset = offset
        if !bookmarkPositionAvailable { bookmarkPositionAvailable = true }
        positionSaver.displayed(token: token, offset: offset)
    }

    func readingScrolled(_ token: String, _ offset: Int) {
        guard route == .reading, activeReadingToken == token, content?.reading?.canSave == true else { return }
        bookmarkOffset = offset
        if !bookmarkPositionAvailable { bookmarkPositionAvailable = true }
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
        let preserve = (target == .discovery || target == .contents || target == .details || target == .reading) && preservingDiscoveryContext
        cancel(preservingDiscovery: preserve)
        if target == .shelf || target == .search || target == .sources { detailReturnRoute = .search }
        let token = generation
        busy = true
        finishReading { [weak self] in
            guard let self, self.generation == token else { return }
            self.route = target; self.busy = false
            action?()
        }
    }
    func retry() { retryAction?() }
    func cancel(preservingDiscovery: Bool = false) {
        guard !committingSwitch else { return }
        if !preservingDiscovery { discovery.retire() }
        retireSearch()
        closeCachedSearch()
        generation = UUID(); request?.cancel(); request = nil
        bookmarkRequest?.cancel(); bookmarkRequest = nil
        bookmarkGeneration = UUID(); bookmarkBusy = false
        bookmarkRetry = nil; canRetryBookmark = false; bookmarkNotice = nil
        busy = false; message = nil; retryAction = nil
    }

    private func perform(stage: ReplyStage = .operation, preservingReading: Bool = false, retry: @escaping () -> Void, failure: ((EngineFailure) -> Void)? = nil, start: @escaping (@escaping (EngineReply) -> Void) -> EngineRequest, success: @escaping (EngineReply) -> Void) {
        cancel(preservingDiscovery: preservingDiscoveryContext)
        let token = generation
        busy = true; retryAction = retry
        let beginRequest: () -> Void = { [weak self] in
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
        if preservingReading { beginRequest() }
        else { finishReading(then: beginRequest) }
    }
}
