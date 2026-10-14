import SwiftUI
import ReaderEngine
import UniformTypeIdentifiers

@main
struct NativeReaderApp: App {
    var body: some Scene { WindowGroup { ReaderScreen(model: ReaderModel()) } }
}

@MainActor
struct ReaderScreen: View {
    @StateObject private var model: ReaderModel
    init(model: ReaderModel) { _model = StateObject(wrappedValue: model) }
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmingDiscard = false
    @State private var importing = false
    @State private var settings = false
    @State private var menu = true
    @State private var style = ReadingStyle()
    @State private var expandedWorks: Set<String> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let message = model.message {
                    HStack {
                        Text(message).font(.callout)
                        Spacer()
                        if model.canRetry { Button("Retry") { model.retry() } }
                        Button("Dismiss") { model.message = nil }
                    }.padding().background(.regularMaterial)
                }
                if let notice = model.saveNotice ?? model.resumeNotice {
                    HStack {
                        Text(notice).font(.callout)
                        Spacer()
                        if model.saveNotice != nil && model.canRetryPosition { Button("Retry save") { model.flushReadingPosition() } }
                        if model.canRetryPosition {
                            Button("Return without saving") { confirmingDiscard = true }
                        }
                        Button("Dismiss") { model.resumeNotice = nil; model.saveNotice = nil }
                    }.padding().background(.regularMaterial)
                }
                if model.busy {
                    HStack { ProgressView(); Text("Loading…"); Spacer(); Button("Cancel") { model.cancelLoading() } }.padding()
                }
                ZStack {
                    if let content = model.content {
                        ReadingText(chapterKey: content.chapter.sourceId + "\u{0}" + content.chapter.bookId + "\u{0}" + content.chapter.id, text: content.text, style: style, restoration: model.readingRestoration, onDisplayed: model.readingDisplayed, onParagraphScroll: model.readingScrolled)
                            .opacity(model.route == .reading ? 1 : 0)
                            .allowsHitTesting(model.route == .reading)
                            .accessibilityHidden(model.route != .reading)
                    }
                    if model.route == .shelf { shelf }
                    if model.route == .search { search }
                    if model.route == .contents { contents }
                }
                if model.route == .reading {
                    if menu {
                        HStack {
                            Button("Previous") { model.moveChapter(-1) }.disabled(model.busy || (model.chapterPosition ?? 0) == 0)
                            Spacer()
                            Button("Contents") { model.navigate(.contents) }
                            Button("Typography") { settings = true }
                            Spacer()
                            Button("Next") { model.moveChapter(1) }.disabled(model.busy || (model.chapterPosition ?? 0) >= model.chapters.count - 1)
                        }.padding().background(.regularMaterial)
                    }
                    Button(menu ? "Hide controls" : "Show controls") { menu.toggle() }.padding(8)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.route != .shelf {
                    ToolbarItem(placement: .navigationBarTrailing) { Button("Shelf") { model.showShelf() } }
                }
                if model.route != .search {
                    ToolbarItem(placement: .navigationBarLeading) { Button("Search") { model.navigate(.search) } }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText]) { result in
                switch result {
                case .success(let url): model.importFile(url)
                case .failure(let error): model.reportFileError(error.localizedDescription)
                }
            }
            .confirmationDialog("Discard the unsaved reading position?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard position and return to shelf", role: .destructive) { model.discardPositionAndReturnToShelf() }
                Button("Keep reading", role: .cancel) {}
            } message: {
                Text("The latest unsaved position will be lost. Previously saved progress is kept; reopen the book from the shelf to continue.")
            }
            .sheet(isPresented: $settings) { typography }
            .task { model.start() }
            .onChange(of: scenePhase) { phase in
                if phase != .active { model.flushReadingPosition() }
            }
            .preferredColorScheme(style.dark ? .dark : .light)
        }
    }

    private var title: String {
        switch model.route {
        case .shelf: return "Shelf"
        case .search: return "Native Reader"
        case .contents: return model.book?.title ?? "Contents"
        case .reading: return model.content?.chapter.title ?? "Reader"
        }
    }

    private var shelf: some View {
        List {
            if model.shelf.isEmpty {
                Text("Your shelf is empty. Search for a book and add it from Contents.").foregroundStyle(.secondary)
            }
            Button("Search and import sources") { model.navigate(.search) }
            ForEach(model.shelf, id: \.book.id) { entry in
                Button { model.openShelfBook(entry) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.book.title)
                        Text(ReaderModel.authorLabel(entry.book.author)).font(.caption)
                        Text(entry.sourceName).font(.caption).foregroundStyle(.secondary)
                        if !entry.lastChapter.isEmpty { Text(entry.lastChapter).font(.caption).foregroundStyle(.secondary) }
                    }
                }.buttonStyle(.plain).disabled(model.busy)
                    .swipeActions { Button("Remove", role: .destructive) { model.removeShelfBook(entry) } }
            }
        }.refreshable { model.refreshShelf() }
    }

    private var search: some View {
        List {
            Section("Sources") {
                if !model.initialized && !model.busy { Button("Initialize reader") { model.start() } }
                if model.initialized { Button("Refresh sources") { model.refreshSources() }.disabled(model.busy) }
                Button("Import Legado JSON") { importing = true }.disabled(model.busy || !model.initialized)
                if let notice = model.importNotice { Text(notice).foregroundStyle(.secondary) }
                if let details = model.importDetails {
                    DisclosureGroup("Import details") {
                        Text(details).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if model.sources.isEmpty { Text("Import an enabled text source to begin.").foregroundStyle(.secondary) }
                else {
                    Picker("Search scope", selection: $model.searchScope) {
                        Text("All enabled sources").tag(ReaderSearchScope.all)
                        Text("Selected sources").tag(ReaderSearchScope.selected)
                    }.disabled(model.busy)
                    if model.searchScope == .all {
                        Text("All \(model.sources.count) enabled text sources").font(.caption).foregroundStyle(.secondary)
                    } else {
                        DisclosureGroup("Selected sources (\(model.selectedSourceIDs.count))") {
                            ForEach(model.sources, id: \.id) { source in
                                Toggle(source.name, isOn: Binding(get: {
                                    model.selectedSourceIDs.contains(source.id)
                                }, set: { selected in
                                    if selected { model.selectedSourceIDs.insert(source.id) }
                                    else { model.selectedSourceIDs.remove(source.id) }
                                })).disabled(model.busy)
                            }
                        }
                        if model.selectedSourceIDs.isEmpty { Text("Select at least one source to search.").foregroundStyle(.secondary) }
                    }
                }
            }
            Section("Search") {
                TextField("Book title or author", text: $model.query).onSubmit { model.search() }
                Button("Search") { model.search() }.disabled(!model.canSearch)
            }
            Section("Results") {
                if model.hasSearched {
                    HStack {
                        if model.searchRunning { ProgressView() }
                        Text(model.searchProgress).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if model.searchRunning { Button("Stop") { model.stopSearch() }.disabled(model.searchCommandPending) }
                    }
                    if model.searchIncomplete { Text("Results may be incomplete. A discovered candidate does not guarantee readable chapters.").font(.caption).foregroundStyle(.secondary) }
                }
                if model.searchIsEmpty { Text("No books found.").foregroundStyle(.secondary) }
                ForEach(model.searchWorks, id: \.id) { work in
                    DisclosureGroup(isExpanded: Binding(get: {
                        expandedWorks.contains(work.id)
                    }, set: { expanded in
                        if expanded { expandedWorks.insert(work.id) }
                        else { expandedWorks.remove(work.id) }
                    })) {
                        ForEach(work.candidates, id: \.id) { candidate in
                            Button { model.select(candidate.book) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(candidate.sourceName)
                                    Text(candidate.book.id).font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(model.busy)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(work.title)
                            Text(ReaderModel.authorLabel(work.author)).font(.caption).foregroundStyle(.secondary)
                            Text("\(work.sourceCount) discovered sources · \(work.candidates.count) candidates").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.hasNextPage { Button("More results") { model.loadMoreSearch() }.disabled(model.busy || model.searchCommandPending) }
                if !model.searchSources.isEmpty {
                    DisclosureGroup("Source outcomes") {
                        ForEach(model.searchSources, id: \.sourceId) { source in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(source.name)
                                Text(source.status.name + " · page \(source.page)").font(.caption).foregroundStyle(.secondary)
                                if let failure = source.failure { Text(failure.message).font(.caption) }
                                if model.searchSessionID != nil {
                                    HStack {
                                        if source.status == .failed { Button("Retry") { model.retrySearchSource(source.sourceId) } }
                                        Button("Restart") { model.restartSearchSource(source.sourceId) }
                                    }.disabled(model.busy || model.searchCommandPending)
                                }
                            }
                        }
                    }
                }
            }
        }.onChange(of: model.searchSessionID) { _ in
            if model.searchSessionID == nil { expandedWorks.removeAll() }
        }
    }

    private var contents: some View {
        List {
            if let book = model.book {
                Section { Text(ReaderModel.authorLabel(book.author)); Text(book.intro).font(.callout).foregroundStyle(.secondary) }
            }
            Section {
                Button("Add to shelf") { model.addCurrentBook() }.disabled(model.busy || model.chapters.isEmpty)
                if let notice = model.shelfNotice { Text(notice).foregroundStyle(.secondary) }
            }
            Section("Chapters") {
                if model.chapters.isEmpty { Text("No chapters available.") }
                ForEach(model.chapters, id: \.id) { chapter in
                    Button {
                        model.read(chapter)
                    } label: {
                        HStack { Text(chapter.title); Spacer(); if model.content?.chapter.id == chapter.id { Image(systemName: "bookmark.fill") } }
                    }.disabled(model.busy)
                }
            }
        }
    }

    private var typography: some View {
        NavigationStack {
            Form {
                Section("Typeface") {
                    Picker("Font", selection: $style.fontName) {
                        ForEach(["PingFangSC-Regular", "STSongti-SC-Regular", "STKaitiSC-Regular"].filter { UIFont(name: $0, size: 22) != nil }, id: \.self) { Text($0).tag($0) }
                    }
                    setting("Size", value: $style.size, range: 16...36)
                    setting("Line spacing", value: $style.lineSpacing, range: 0...18)
                    setting("Paragraph spacing", value: $style.paragraphSpacing, range: 0...30)
                    setting("Margins", value: $style.margin, range: 12...64)
                    Toggle("Dark appearance", isOn: $style.dark)
                }
            }.navigationTitle("Typography")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } }
        }
    }

    private func setting(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) { Text("\(title): \(Int(value.wrappedValue))"); Slider(value: value, in: range, step: 1) }
    }
}
