import Foundation
import ReaderEngine

/// Native browser state shares ReaderModel's engine so discovered books keep exact registry identity.
@MainActor
final class DiscoveryModel: ObservableObject {
    @Published var sourceQuery = ""
    @Published var sourceGroup: String?
    var returnBookID: String?
    @Published private(set) var sources: [ManagedSource] = []
    @Published private(set) var sourcesLoading = false
    @Published private(set) var sourceFailure: String?
    @Published private(set) var selectedSourceID: String?
    @Published private(set) var update: DiscoveryUpdate?
    @Published private(set) var commandPending = false
    @Published private(set) var retired = false
    @Published private(set) var failure: String?
    private let engine: ReaderEngine
    private var subscription: EngineRequest?
    private var commandRequest: EngineRequest?
    private var sourceRequest: EngineRequest?
    private var generation = UUID()
    private var sourceGeneration = UUID()
    private var sessionID: String?

    init(engine: ReaderEngine) { self.engine = engine }
    var loading: Bool {
        !retired && (update == nil && selectedSourceID != nil || update?.phase == .loadingCategories || update?.phase == .loadingBooks)
    }
    var cancelled: Bool { retired || update?.phase == .cancelled }
    var books: [BookSnapshot] { update?.books ?? [] }
    var categories: [DiscoveryCategorySnapshot] { update?.categories ?? [] }
    var options: [DiscoveryOptionSnapshot] { update?.options ?? [] }
    var hasNextPage: Bool { !cancelled && !commandPending && update?.hasNextPage == true }
    var canRetry: Bool { !cancelled && !loading && !commandPending && update?.failure != nil }
    var sourceName: String { sources.first { $0.id == selectedSourceID }?.name ?? update?.sourceName ?? "Discover" }
    var categoryName: String { categories.first { $0.id == update?.categoryId }?.name ?? "Categories" }
    static func unavailableReason(_ source: ManagedSource) -> String? {
        if !source.enabled { return "Source is disabled" }
        if !source.hasDiscovery { return "No discovery categories" }
        if !source.discoveryEnabled { return "Hidden from Discover" }
        return nil
    }
    func reloadSources() {
        sourceRequest?.cancel()
        let token = UUID(); sourceGeneration = token
        sourcesLoading = true; sourceFailure = nil
        sourceRequest = engine.listManagedSources { [weak self] reply in
            guard let self, self.sourceGeneration == token else { return }
            self.sourcesLoading = false; self.sourceRequest = nil
            if let result = reply as? ManagedSourcesReply { self.sources = result.sources }
            else if let error = reply as? EngineFailure { self.sourceFailure = error.message }
        }
    }
    func openSource(_ id: String) {
        retire()
        let token = UUID(); generation = token
        selectedSourceID = id; update = nil; retired = false; failure = nil; returnBookID = nil
        subscription = engine.startDiscovery(sourceId: id) { [weak self] reply in
            guard let self, self.generation == token else { return }
            if let update = reply as? DiscoveryUpdate {
                guard self.sessionID == nil || self.sessionID == update.sessionId else { return }
                self.sessionID = update.sessionId; self.update = update
                self.failure = update.failure.map { "\($0.code.name): \($0.message)" }
                if update.phase == .cancelled { self.retire() }
            } else if let error = reply as? EngineFailure {
                self.failure = "\(error.code.name): \(error.message)"
                self.retire()
            }
        }
    }
    func showSources() {
        retire(); selectedSourceID = nil; update = nil; failure = nil
        reloadSources()
    }
    func selectCategory(_ id: String) {
        command { self.engine.selectDiscoveryCategory(sessionId: $0, categoryId: id, completion: $1) }
    }
    func selectOption(_ option: DiscoveryOptionSnapshot, choice: DiscoveryChoiceSnapshot) {
        var selected = option.multiSelect ? Set(option.choices.filter(\.selected).map(\.value)) : []
        if option.multiSelect && selected.contains(choice.value) { selected.remove(choice.value) }
        else { selected.insert(choice.value) }
        command { self.engine.selectDiscoveryOption(sessionId: $0, name: option.name, values: Array(selected), completion: $1) }
    }
    func loadMore() { command { self.engine.loadMoreDiscovery(sessionId: $0, completion: $1) } }
    func retry() { command { self.engine.retryDiscovery(sessionId: $0, completion: $1) } }
    func refresh() {
        if sessionID == nil { if let id = selectedSourceID { openSource(id) }; return }
        command { self.engine.refreshDiscovery(sessionId: $0, completion: $1) }
    }
    func stop() { command { self.engine.cancelDiscovery(sessionId: $0, completion: $1) } }
    func retire() {
        generation = UUID()
        subscription?.cancel(); subscription = nil
        commandRequest?.cancel(); commandRequest = nil
        sessionID = nil; commandPending = false
        if selectedSourceID != nil { retired = true }
    }
    private func command(_ start: (String, @escaping (EngineReply) -> Void) -> EngineRequest) {
        guard let sessionID, !commandPending else { return }
        let token = generation
        commandPending = true
        commandRequest = start(sessionID) { [weak self] reply in
            guard let self, self.generation == token else { return }
            self.commandPending = false; self.commandRequest = nil
            if let error = reply as? EngineFailure { self.failure = "\(error.code.name): \(error.message)" }
        }
    }
}
