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
    init(model: ReaderModel) { _model = StateObject(wrappedValue: model) }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
                        ReadingText(chapterKey: content.chapter.sourceId + "\u{0}" + content.chapter.bookId + "\u{0}" + content.chapter.id, text: content.text, style: style, restoration: model.readingRestoration, onDisplayed: model.readingDisplayed, onParagraphScroll: model.readingScrolled)
                            .opacity(model.route == .reading ? 1 : 0)
                            .allowsHitTesting(model.route == .reading)
                            .accessibilityHidden(model.route != .reading)
                    }
                    if model.route == .shelf { shelf }
                    if model.route == .search { search }
                    if model.route == .contents { contents }
                }
                if model.route == .reading { readingControls }

            }
            .background(model.route == .reading ? paper : Color(uiColor: .systemGroupedBackground))
            .tint(style.dark ? Color(red: 0.82, green: 0.73, blue: 0.58) : Color(red: 0.43, green: 0.32, blue: 0.20))
            .navigationTitle(model.route == .reading ? "" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.route != .shelf {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { model.showShelf() } label: { Label("Shelf", systemImage: "chevron.left") }
                            .accessibilityIdentifier("reader.shelf")
                    }
                }
                if model.route == .shelf || model.route == .contents {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { model.navigate(.search) } label: { Label("Search", systemImage: "magnifyingglass") }
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
            .task { model.start() }
            .onChange(of: scenePhase) { phase in
                if phase != .active { model.flushReadingPosition() }
            }
            .preferredColorScheme(style.dark ? .dark : .light)
        }
    }

    private var title: String {
        switch model.route {
        case .shelf: return "Library"
        case .search: return "Native Reader"
        case .contents: return model.book?.title ?? "Contents"
        case .reading: return model.content?.chapter.title ?? "Reader"
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
                Text("Your shelf is empty. Search for a book and add it from Contents.").foregroundStyle(.secondary)
            }
            Button("Search and import sources") { model.navigate(.search) }
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
                Section {
                    Text(ReaderModel.authorLabel(book.author)).font(.subheadline).foregroundStyle(.secondary)
                    if !book.intro.isEmpty { Text(book.intro).font(.callout).foregroundStyle(.secondary) }
                    if let content = model.content {
                        Button { model.resumeCurrentBook() } label: {
                            Label("Continue reading · " + content.chapter.title, systemImage: "book")
                        }.disabled(model.busy).accessibilityIdentifier("contents.continue")
                    }
                }
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
                        HStack {
                            Text(chapter.title).foregroundStyle(.primary)
                            Spacer()
                            if model.content?.chapter.id == chapter.id {
                                Label("Current chapter", systemImage: "bookmark.fill")
                                    .labelStyle(.iconOnly).font(.caption)
                            }
                        }.padding(.vertical, 5)
                    }.disabled(model.busy)
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
                HStack {
                    chapterButton("Previous", icon: "chevron.left", delta: -1)
                    Spacer(minLength: 12)
                    Button { model.navigate(.contents) } label: {
                        Label("Contents", systemImage: "list.bullet").frame(minHeight: 44).contentShape(Rectangle())
                    }
                        .accessibilityIdentifier("reader.contents")
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
                        Button { style.size = max(16, style.size - 2) } label: { Image(systemName: "textformat.size.smaller") }
                            .accessibilityLabel("Smaller text").accessibilityIdentifier("typography.smaller")
                            .disabled(style.size <= 16)
                        Text("\(Int(style.size))").monospacedDigit().frame(minWidth: 32)
                        Button { style.size = min(36, style.size + 2) } label: { Image(systemName: "textformat.size.larger") }
                            .accessibilityLabel("Larger text").accessibilityIdentifier("typography.larger")
                            .disabled(style.size >= 36)
                    }.buttonStyle(.borderless)
                    Toggle("Dark appearance", isOn: $style.dark)
                }
                Section {
                    DisclosureGroup("More text options") {
                        Picker("Font", selection: $style.fontName) {
                            ForEach(["PingFangSC-Regular", "STSongti-SC-Regular", "STKaitiSC-Regular"].filter { UIFont(name: $0, size: 22) != nil }, id: \.self) { Text($0).tag($0) }
                        }
                        setting("Size", value: $style.size, range: 16...36)
                        setting("Line spacing", value: $style.lineSpacing, range: 0...18)
                        setting("Paragraph spacing", value: $style.paragraphSpacing, range: 0...30)
                        setting("Margins", value: $style.margin, range: 12...64)
                    }
                }
            }.navigationTitle("Typography").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } }
        }.presentationDetents([.medium, .large])
    }

    private func setting(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) { Text("\(title): \(Int(value.wrappedValue))"); Slider(value: value, in: range, step: 1) }
    }
}
