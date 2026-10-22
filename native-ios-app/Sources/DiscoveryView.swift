import SwiftUI
import ReaderEngine

@MainActor
struct DiscoveryView: View {
    @ObservedObject var reader: ReaderModel
    @ObservedObject var model: DiscoveryModel
    @FocusState private var filteringSource: Bool
    private var groups: [String] { Array(Set(model.sources.flatMap(\.groups))).sorted() }
    private var filtered: [ManagedSource] {
        model.sources.filter { source in
            (model.sourceGroup.map { source.groups.contains($0) } ?? true) &&
            (model.sourceQuery.isEmpty || source.name.localizedCaseInsensitiveContains(model.sourceQuery) || source.id.localizedCaseInsensitiveContains(model.sourceQuery))
        }
    }
    var body: some View {
        ScrollViewReader { scroll in
            List {
                if model.selectedSourceID == nil { sourceList }
                else { browser }
            }
            .onAppear {
                if let id = model.returnBookID { scroll.scrollTo("book." + id, anchor: .center) }
            }
        }
        .task { model.reloadSources() }
    }
    @ViewBuilder private var sourceList: some View {
        Section {
            Text("Browse a source's categories and rankings, then choose a book to try.").foregroundStyle(.secondary)
            TextField("Source name or address", text: $model.sourceQuery)
                .focused($filteringSource).submitLabel(.done).onSubmit { filteringSource = false }
                .accessibilityIdentifier("discovery.sourceFilter")
            Picker("Group", selection: $model.sourceGroup) {
                Text("All groups").tag(Optional<String>.none)
                ForEach(groups, id: \.self) { Text($0).tag(Optional($0)) }
            }.accessibilityIdentifier("discovery.groupFilter")
            Button("Manage sources") { reader.navigate(.sources) }.accessibilityIdentifier("discovery.manageSources")
        }
        if model.sourcesLoading { ProgressView("Loading sources…") }
        if let failure = model.sourceFailure {
            Section { Text(failure); Button("Retry sources") { model.reloadSources() } }
        }
        if model.sources.isEmpty && !model.sourcesLoading {
            Text("No text sources yet. Import a source from Sources to start browsing.")
        } else if filtered.isEmpty {
            Text("No matching sources.")
        }
        Section("Available sources") {
            let available = filtered.filter { DiscoveryModel.unavailableReason($0) == nil }
            if available.isEmpty { Text("No available discovery sources. Check source and discovery settings in Sources.").foregroundStyle(.secondary) }
            ForEach(available, id: \.id) { source in
                Button { model.openSource(source.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.name).font(.headline)
                        Text(source.groups.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        Text(source.id).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("discovery.source." + source.id)
            }
        }
        let unavailable = filtered.filter { DiscoveryModel.unavailableReason($0) != nil }
        if !unavailable.isEmpty {
            Section("Unavailable sources") {
                ForEach(unavailable, id: \.id) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.name)
                        Text(DiscoveryModel.unavailableReason(source) ?? "Unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    @ViewBuilder private var browser: some View {
        Section {
            Button("All discovery sources") { model.showSources() }.accessibilityIdentifier("discovery.allSources")
            Text(model.sourceName).font(.headline)
            if model.update?.categoryId != nil {
                Button("All categories") { if let id = model.selectedSourceID { model.openSource(id) } }
                    .accessibilityIdentifier("discovery.allCategories")
                Text(model.categoryName).font(.subheadline)
            }
            HStack {
                if model.loading { ProgressView(); Text("Loading discovery…") }
                else if model.cancelled { Text("Browsing stopped. Results may be incomplete.").foregroundStyle(.secondary) }
                else { Text(model.update?.categoryId == nil ? "Choose a category" : (model.books.count == 1 ? "1 book" : "\(model.books.count) books")).foregroundStyle(.secondary) }
                Spacer()
                if model.loading { Button("Stop browsing") { model.stop() }.disabled(model.commandPending) }
            }.accessibilityIdentifier("discovery.status")
            if let failure = model.failure { Text(failure).font(.callout).foregroundStyle(.secondary) }
            if model.canRetry { Button("Retry discovery") { model.retry() }.accessibilityIdentifier("discovery.retry") }
            Button(model.cancelled ? "Reload source" : "Refresh discovery") { model.refresh() }
                .disabled(model.loading || model.commandPending).accessibilityIdentifier("discovery.refresh")
        }
        if model.update?.categoryId == nil {
            if model.categories.isEmpty && !model.loading && model.failure == nil && !model.cancelled {
                Text("This source returned no categories.").foregroundStyle(.secondary)
            }
            Section("Categories") {
                ForEach(model.categories, id: \.id) { category in
                    if category.kind == .heading { Text(category.name).font(.headline) }
                    else if category.kind == .unsupported {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(category.name, systemImage: "info.circle")
                            Text(category.notice).font(.caption).foregroundStyle(.secondary)
                        }.accessibilityIdentifier("discovery.unsupported")
                    } else {
                        Button(category.name) { model.selectCategory(category.id) }
                            .disabled(model.cancelled || model.commandPending)
                            .accessibilityIdentifier("discovery.category." + category.name)
                    }
                }
            }
        } else {
            if !model.options.isEmpty {
                Section("Filters") {
                    ForEach(model.options, id: \.name) { option in
                        Menu {
                            ForEach(option.choices, id: \.value) { choice in
                                Button { model.selectOption(option, choice: choice) } label: {
                                    if choice.selected { Label(choice.label, systemImage: "checkmark") }
                                    else { Text(choice.label) }
                                }
                            }
                        } label: {
                            LabeledContent(option.name, value: option.choices.filter(\.selected).map(\.label).joined(separator: ", "))
                        }.disabled(model.cancelled || model.commandPending)
                            .accessibilityIdentifier("discovery.option." + option.name)
                    }
                }
            }
            Section("Books") {
                if model.books.isEmpty && !model.loading && model.failure == nil && !model.cancelled { Text("No books in this category.") }
                ForEach(model.books, id: \.id) { book in
                    Button { model.returnBookID = book.id; reader.select(book) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(book.title).font(.headline).foregroundStyle(.primary)
                            Text(ReaderModel.authorLabel(book.author)).font(.subheadline).foregroundStyle(.secondary)
                            if !book.intro.isEmpty { Text(book.intro).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(reader.busy)
                        .accessibilityIdentifier("discovery.book." + book.id).id("book." + book.id)
                }
                if model.hasNextPage { Button("Load more books") { model.loadMore() }.accessibilityIdentifier("discovery.more") }
                else if !model.loading && model.failure == nil && !model.cancelled && !model.books.isEmpty {
                    Text("End of category.").foregroundStyle(.secondary)
                }
            }
        }
    }
}
