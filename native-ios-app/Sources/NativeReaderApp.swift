import SwiftUI
import ReaderEngine
import UniformTypeIdentifiers

#if !READER_UI_TEST_HOST
@main
struct NativeReaderApp: App {
    var body: some Scene { WindowGroup { ReaderScreen(model: ReaderModel()) } }
}

#endif

@MainActor
struct ReaderScreen: View {
    @StateObject private var model: ReaderModel
    @ObservedObject private var preferences: ReadingPreferences
    init(model: ReaderModel, preferences: ReadingPreferences? = nil) {
        _model = StateObject(wrappedValue: model)
        self.preferences = preferences ?? .shared
    }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var confirmingDiscard = false
    @State private var importing = false
    @State private var settings = false
    @State private var menu = true
    @State private var catalogQuery = ""
    private var style: ReadingStyle { preferences.style }
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
                    VStack(alignment: .leading, spacing: 12) {
                        Text(notice).font(.callout)
                        HStack {
                        if model.saveNotice != nil && model.canRetryPosition { Button("Retry save") { model.flushReadingPosition() } }
                        if model.canRetryPosition {
                            Button("Return without saving") { confirmingDiscard = true }
                        }
                        Button("Dismiss") { model.resumeNotice = nil; model.saveNotice = nil }
                        }.buttonStyle(.bordered)
                    }.padding().background(.regularMaterial)
                }
                if model.busy {
                    HStack {
                        ProgressView(); Text(model.committingSwitch ? "Switching source…" : "Loading…"); Spacer()
                        if !model.committingSwitch { Button("Cancel") { model.cancelLoading() } }
                    }.padding()
                }
                if let original = model.switchingFrom {
                    HStack {
                        Text("Change source · \(original.title)").font(.callout)
                        Spacer()
                        Button("Keep original source") { model.cancelSourceSwitch() }
                            .disabled(model.committingSwitch).accessibilityIdentifier("switch.cancel")
                    }.padding()
                }
                if model.route == .reading, let content = model.content {
                    VStack(spacing: 6) {
                        Text(model.book?.title ?? "")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(content.chapter.title)
                            .font(.title3.weight(.medium)).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 16)
                    .accessibilityElement(children: .combine)
                }
                ZStack {
                    if let content = model.content {
                        ReadingText(chapterKey: content.chapter.sourceId + "\u{0}" + content.chapter.bookId + "\u{0}" + content.chapter.id, text: content.text, style: style, restoration: model.readingRestoration, onDisplayed: model.readingDisplayed, onParagraphScroll: model.readingScrolled, isReading: model.route == .reading)
                            .opacity(model.route == .reading ? 1 : 0)
                            .allowsHitTesting(model.route == .reading)
                            .accessibilityHidden(model.route != .reading)
                    }
                    if model.route == .shelf { shelf }
                    if model.route == .search { search }
                    if model.route == .sources { sources }
                    if model.route == .details { details }
                    if model.route == .contents { contents }
                    if model.route == .sourceSwitch { sourceSwitch }
                }
                if model.route == .reading { readingControls }
                if model.switchingFrom == nil && (model.route == .shelf || model.route == .search || model.route == .sources) { libraryNavigation }

            }
            .background(model.route == .reading ? paper : Color(uiColor: .systemGroupedBackground))
            .tint(style.dark ? Color(red: 0.82, green: 0.73, blue: 0.58) : Color(red: 0.43, green: 0.32, blue: 0.20))
            .navigationTitle(model.route == .reading ? "" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.route != .shelf && model.switchingFrom == nil {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { model.showShelf() } label: { Label("Shelf", systemImage: "chevron.left") }
                            .accessibilityIdentifier("reader.shelf")
                            .disabled(model.busy)
                    }
                }
                if model.route == .details || model.route == .contents {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { model.navigate(.search) } label: { Label("Search results", systemImage: "magnifyingglass") }
                            .accessibilityIdentifier("navigation.searchResults").disabled(model.busy)
                    }
                }
                if model.route == .reading {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { menu.toggle() } label: {
                            Label(menu ? "Hide controls" : "Show controls", systemImage: menu ? "ellipsis.circle.fill" : "ellipsis.circle")
                        }.accessibilityIdentifier("reader.controls")
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText]) { result in
                switch result {
                case .success(let url): model.importFile(url)
                case .failure(let error): model.reportFileError(error.localizedDescription)
                }
            }
            .alert("Discard the unsaved reading position?", isPresented: $confirmingDiscard) {
                Button("Discard position and return to shelf", role: .destructive) { model.discardPositionAndReturnToShelf() }
                Button("Keep reading", role: .cancel) {}
            } message: {
                Text("The latest unsaved position will be lost. Previously saved progress is kept; reopen the book from the shelf to continue.")
            }
            .sheet(isPresented: $settings) { typography }
            .alert("Clear optional cached chapters?", isPresented: Binding(
                get: { model.cacheClearPlan != nil },
                set: { if !$0 { model.cacheClearPlan = nil } })) {
                Button("Clear cached chapters", role: .destructive) { model.confirmCacheClear() }
                Button("Cancel", role: .cancel) { model.cacheClearPlan = nil }
            } message: {
                Text("Remove \(model.cacheClearPlan?.count ?? 0) cached chapters. Saved progress and chapters currently displayed are protected.")
            }
            .task { model.start() }
            .onAppear { model.setPrefetchEnabled(preferences.prefetchNextTwo) }
            .onChange(of: preferences.prefetchNextTwo) { model.setPrefetchEnabled($0) }
            .onChange(of: scenePhase) { phase in
                model.setForegroundActive(phase == .active)
                if phase != .active { model.flushReadingPosition() }
            }
            .onChange(of: model.book?.id) { _ in catalogQuery = "" }
            .onChange(of: model.book?.sourceId) { _ in catalogQuery = "" }
            .preferredColorScheme(style.dark ? .dark : .light)
        }
    }

    private var title: String {
        switch model.route {
        case .shelf: return "Library"
        case .search: return "Search"
        case .sources: return "Sources"
        case .details: return "Book details"
        case .contents: return "Contents"
        case .reading: return model.content?.chapter.title ?? "Reader"
        case .sourceSwitch: return "Replacement chapter"
        }
    }

    private var shelf: some View {
        List {
            if let notice = model.shelfNotice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("shelf.notice")
            }
            if model.shelf.isEmpty {
                Text("Your shelf is empty. Find a book, try a chapter, and keep it here for later.").foregroundStyle(.secondary)
            }
            if model.shelf.isEmpty {
                Button("Find a book") { model.navigate(.search) }
            }
            ForEach(model.shelf, id: \.book.id) { entry in
                Button { model.openShelfBook(entry) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.book.title).font(.headline).foregroundStyle(.primary)
                        Text(ReaderModel.authorLabel(entry.book.author)).font(.subheadline).foregroundStyle(.secondary)
                        if !entry.lastChapter.isEmpty {
                            Label(entry.lastChapter, systemImage: "bookmark")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(entry.sourceName).font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(model.busy)
                    .swipeActions { Button("Remove", role: .destructive) { model.removeShelfBook(entry) } }
            }
        }.refreshable { model.refreshShelf() }
    }

    private var libraryNavigation: some View {
        HStack {
            libraryButton("Library", icon: "books.vertical", route: .shelf)
            libraryButton("Search", icon: "magnifyingglass", route: .search)
            libraryButton("Sources", icon: "square.stack.3d.up", route: .sources)
        }.padding(.vertical, 8).background(.regularMaterial)
    }

    private func libraryButton(_ title: String, icon: String, route: ReaderRoute) -> some View {
        Button {
            if route == .shelf { model.showShelf() } else { model.navigate(route) }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }.frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(model.route == route ? Color.accentColor : .secondary)
        }.disabled(model.busy || model.route == route)
            .accessibilityIdentifier("navigation.\(String(describing: route))")
    }

    private var sources: some View {
        SourceManagementView(model: model, importFile: { importing = true })
    }

    private var search: some View {
        List {
            Section("Search scope") {
                if model.sources.isEmpty {
                    Text("No enabled text sources.").foregroundStyle(.secondary)
                    Button("Import sources") { model.navigate(.sources) }
                } else {
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
                    .accessibilityIdentifier("search.query")
                Button("Search") { model.search() }.disabled(!model.canSearch).accessibilityIdentifier("search.submit")
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
                            }.disabled(model.busy || !model.eligibleSwitchCandidate(candidate.book)).accessibilityIdentifier("search.candidate." + candidate.id)
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
        }.onChange(of: model.query) { _ in expandedWorks.removeAll() }
        .onChange(of: model.searchSessionID) { _ in
            if model.searchSessionID != nil && model.searchWorks.isEmpty { expandedWorks.removeAll() }
        }
    }

    private var details: some View {
        List {
            if let book = model.book {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(book.title).font(.largeTitle.weight(.semibold))
                        Text(ReaderModel.authorLabel(book.author)).font(.title3).foregroundStyle(.secondary)
                        Label(model.sources.first { $0.id == book.sourceId }?.name ?? book.sourceId,
                              systemImage: "square.stack.3d.up").font(.subheadline).foregroundStyle(.secondary)
                        Text("\(model.chapters.count) chapters").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
                Section {
                    Button {
                        if model.content != nil { model.returnToCurrentReading() }
                        else if let first = model.chapters.first { model.read(first) }
                    } label: {
                        Label(model.content == nil ? "Read first chapter" : "Continue reading", systemImage: "book.fill")
                    }.disabled(model.busy || model.chapters.isEmpty).accessibilityIdentifier("details.read")
                    Button { model.navigate(.contents) } label: { Label("Contents", systemImage: "list.bullet") }
                        .disabled(model.busy).accessibilityIdentifier("details.contents")
                    Button { model.addCurrentBook() } label: { Label("Add to shelf", systemImage: "plus.circle") }
                        .disabled(model.busy || model.chapters.isEmpty).accessibilityIdentifier("details.add")
                    if model.canChangeSource {
                        Button("Change source") { model.beginSourceSwitch() }
                            .disabled(model.busy).accessibilityIdentifier("details.changeSource")
                    }
                    if let notice = model.shelfNotice { Text(notice).foregroundStyle(.secondary) }
                }
                Section("About this book") {
                    Text(book.intro.isEmpty ? "No introduction available." : book.intro)
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                if model.isShelved { offlineControls }
            }
        }.onAppear { model.refreshOfflineStatus() }
    }

    private var offlineControls: some View {
        Section("Offline reading") {
            if let status = model.offlineStatus {
                Text("\(status.chapters.filter { $0.availability == .available }.count) of \(status.chapters.count) chapters available offline")
                    .accessibilityIdentifier("offline.count")
            } else { Text("Checking cached chapters…") }
            Text("Uses the stored catalog for this source.").font(.caption).foregroundStyle(.secondary)
            if let progress = model.cacheProgress {
                Text("\(progress.completed) / \(progress.target) ready · \(progress.failedChapterIds.count) failed\(progress.cancelled ? " · Cancelled" : "")")
                    .accessibilityIdentifier("offline.progress")
                if !progress.lastFailure.isEmpty { Text(progress.lastFailure).font(.caption).foregroundStyle(.secondary) }
                if progress.running {
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.target)))
                    Button("Cancel caching") { model.cancelCaching() }.accessibilityIdentifier("offline.cancel")
                }
            }
            Button(model.cacheProgress?.failedChapterIds.isEmpty == false ? "Retry missing or failed chapters" : "Cache next 20 chapters") {
                model.cacheNextChapters()
            }.disabled(model.busy || model.cacheProgress?.running == true).accessibilityIdentifier("offline.cache")
            Button("Clear optional cached chapters", role: .destructive) { model.prepareCacheClear() }
                .disabled(model.busy).accessibilityIdentifier("offline.clear")
            if let notice = model.cacheNotice { Text(notice).font(.caption).accessibilityIdentifier("offline.notice") }
        }
    }

    private var filteredChapters: [ChapterSnapshot] {
        let query = catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? model.chapters : model.chapters.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var contents: some View {
        ScrollViewReader { scroll in
            List {
                Section {
                    if let book = model.book { Text(book.title).font(.headline) }
                    if let content = model.content {
                        Button { model.returnToCurrentReading() } label: {
                            Label("Continue reading · " + content.chapter.title, systemImage: "book")
                        }.disabled(model.busy).accessibilityIdentifier("contents.continue")
                        Button("Locate current chapter") {
                            catalogQuery = ""
                            withAnimation { scroll.scrollTo(content.chapter.id, anchor: .center) }
                        }.accessibilityIdentifier("contents.locate")
                    }
                    Button("Book details") { model.navigate(.details) }
                        .disabled(model.busy).accessibilityIdentifier("contents.details")
                    TextField("Filter chapter titles", text: $catalogQuery)
                        .accessibilityIdentifier("contents.filter")
                    if !catalogQuery.isEmpty {
                        Button("Clear filter") { catalogQuery = "" }.accessibilityIdentifier("contents.clearFilter")
                    }
                }
                Section("Chapters · \(filteredChapters.count)") {
                    if model.chapters.isEmpty { Text("No chapters available.") }
                    else if filteredChapters.isEmpty { Text("No matching chapters. Try another title or clear the filter.") }
                    ForEach(filteredChapters, id: \.id) { chapter in
                        Button {
                            if model.content?.chapter.id == chapter.id { model.returnToCurrentReading() }
                            else { model.read(chapter) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(chapter.title).foregroundStyle(.primary)
                                    if model.isShelved && !chapter.isVolume {
                                        Text(model.offlineLabel(chapter)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if model.content?.chapter.id == chapter.id {
                                    Label("Current chapter", systemImage: "bookmark.fill")
                                        .labelStyle(.iconOnly).font(.caption)
                                }
                            }.padding(.vertical, 5).contentShape(Rectangle())
                        }.disabled(model.busy).id(chapter.id)
                            .accessibilityIdentifier(model.content?.chapter.id == chapter.id ? "contents.currentChapter" : "contents.chapter.\(chapter.id)")
                    }
                }
            }.onAppear { model.refreshOfflineStatus() }.onChange(of: catalogQuery) { query in
                if query.isEmpty, let chapter = model.content?.chapter {
                    scroll.scrollTo(chapter.id, anchor: .center)
                }
            }
        }
    }

    private var paper: Color {
        style.dark ? Color(white: 0.08) : Color(red: 0.98, green: 0.97, blue: 0.94)
    }

    private var readingControls: some View {
        VStack(spacing: 12) {
            if menu {
                if model.canChangeSource {
                    Button("Change source") { model.beginSourceSwitch() }
                        .disabled(model.busy).accessibilityIdentifier("reader.changeSource")
                }
                HStack {
                    chapterButton("Previous", icon: "chevron.left", delta: -1)
                    Spacer(minLength: 12)
                    Button { model.navigate(.contents) } label: {
                        Label("Contents", systemImage: "list.bullet").frame(minHeight: 44).contentShape(Rectangle())
                    }
                        .accessibilityIdentifier("reader.contents")
                        .disabled(model.busy)
                    Spacer(minLength: 12)
                    Button { settings = true } label: {
                        Label("Typography", systemImage: "textformat.size")
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }.accessibilityIdentifier("reader.typography")
                    Spacer(minLength: 12)
                    chapterButton("Next", icon: "chevron.right", delta: 1)
                }
                .font(.callout).padding(.horizontal, 24)
            }
            if let position = model.chapterPosition {
                Text("Chapter \(position + 1) of \(model.chapters.count)")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("reader.chapterProgress")
            }
        }
        .padding(.top, menu ? 8 : 4).padding(.bottom, 12)
        .frame(maxWidth: .infinity).background(paper)
        .overlay(alignment: .top) { if menu { Divider().opacity(0.35) } }
    }

    private var sourceSwitch: some View {
        List {
            if let candidate = model.switchCandidate {
                Section("Replacement source") {
                    if let original = model.switchingFrom {
                        Text("From: " + (model.sources.first { $0.id == original.sourceId }?.name ?? original.sourceId))
                            .accessibilityIdentifier("switch.originalSource")
                    }
                    Text("To: " + (model.sources.first { $0.id == candidate.sourceId }?.name ?? candidate.sourceId))
                        .accessibilityIdentifier("switch.replacementSource")
                    Text(candidate.title)
                    Text("Choose a chapter. Switching starts at its beginning; the old paragraph position is not copied.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Choose another source") { model.navigate(.search) }
                        .disabled(model.busy)
                }
                if let prepared = model.preparedSwitch {
                    Section("Ready to switch") {
                        Text(prepared.chapter.title)
                        Text("The replacement text is downloaded. Your original source stays active until you confirm.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Confirm source switch") { model.confirmSourceSwitch() }
                            .disabled(model.busy).accessibilityIdentifier("switch.confirm")
                    }
                }
                Section("Choose replacement chapter") {
                    if model.recommendedSwitchChapter == nil {
                        Text("No unique title match. Select the chapter explicitly.").foregroundStyle(.secondary)
                    }
                    ForEach(model.switchChapters, id: \.id) { chapter in
                        Button { model.prepareSourceSwitch(chapter) } label: {
                            HStack {
                                Text(chapter.title)
                                if model.recommendedSwitchChapter?.id == chapter.id {
                                    Text("Recommended").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.disabled(model.busy).accessibilityIdentifier("switch.chapter.\(chapter.index)")
                    }
                }
            }
        }
    }

    private func chapterButton(_ title: String, icon: String, delta: Int) -> some View {
        Button { model.moveChapter(delta) } label: {
            HStack(spacing: 6) {
                if delta < 0 { Image(systemName: icon) }
                if horizontalSizeClass != .compact { Text(title) }
                if delta > 0 { Image(systemName: icon) }
            }.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(delta < 0 ? "reader.previous" : "reader.next")
        .disabled(model.busy || model.chapterPosition.map { !model.chapters.indices.contains($0 + delta) } != false)
    }

    private var typography: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Text size")
                        Spacer()
                        Button { preferences.style.size = max(16, style.size - 2) } label: { Image(systemName: "textformat.size.smaller") }
                            .accessibilityLabel("Smaller text").accessibilityIdentifier("typography.smaller")
                            .disabled(style.size <= 16)
                        Text("\(Int(style.size))").monospacedDigit().frame(minWidth: 32).accessibilityIdentifier("typography.size")
                        Button { preferences.style.size = min(36, style.size + 2) } label: { Image(systemName: "textformat.size.larger") }
                            .accessibilityLabel("Larger text").accessibilityIdentifier("typography.larger")
                            .disabled(style.size >= 36)
                    }.buttonStyle(.borderless)

                }
                Section("Typography") {
                    DisclosureGroup("More text options") {
                        Picker("Font", selection: $preferences.style.fontName) {
                            ForEach(["PingFangSC-Regular", "STSongti-SC-Regular", "STKaitiSC-Regular"].filter { UIFont(name: $0, size: 22) != nil }, id: \.self) { Text($0).tag($0) }
                        }
                        setting("Size", value: $preferences.style.size, range: 16...36)
                        setting("Line spacing", value: $preferences.style.lineSpacing, range: 0...18)
                        setting("Paragraph spacing", value: $preferences.style.paragraphSpacing, range: 0...30)
                        setting("Margins", value: $preferences.style.margin, range: 12...64)
                    }
                }
                Section("Appearance") {
                    Toggle("Dark appearance", isOn: $preferences.style.dark).accessibilityIdentifier("appearance.dark")
                }
                Section("Offline reading") {
                    Toggle("Prefetch next 2 chapters", isOn: $preferences.prefetchNextTwo)
                        .accessibilityIdentifier("offline.prefetch")
                    Text("While reading in the foreground. Applies to every shelved book; off by default.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text("These settings apply to every book and are kept when you reopen the app.").font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Reading settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } }
        }.presentationDetents([.medium, .large])
    }

    private func setting(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) { Text("\(title): \(Int(value.wrappedValue))"); Slider(value: value, in: range, step: 1) }
    }
}
