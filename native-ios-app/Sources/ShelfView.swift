import SwiftUI
import ReaderEngine

private struct ShelfGroupFormDraft: Identifiable {
    let id = UUID()
    let group: ShelfGroupSnapshot?
    let token: String
}

private struct ShelfMembershipDraft: Identifiable {
    let id = UUID()
    let books: [ShelfBookSnapshot]
    let groups: [ShelfGroupSnapshot]
    let token: String
}

private struct ShelfRemovalDraft {
    let books: [ShelfBookSnapshot]
    let token: String
}

private struct ShelfGroupDeletionDraft {
    let group: ShelfGroupSnapshot
    let token: String
}

@MainActor
struct ShelfView: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var preferences: ReadingPreferences
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var groupForm: ShelfGroupFormDraft?
    @State private var memberships: ShelfMembershipDraft?
    @State private var removal: ShelfRemovalDraft?
    @State private var deletion: ShelfGroupDeletionDraft?

    private var selectedBooks: [ShelfBookSnapshot] {
        model.visibleShelfBooks.filter { selected.contains($0.book.id) }
    }
    private var grid: Bool { preferences.shelfLayout == .grid }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if selecting { selectionBar }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let notice = model.shelfNotice {
                        Label(notice, systemImage: "checkmark.circle")
                            .font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("shelf.notice")
                    }
                    if model.currentShelfGroup == nil && model.shelf.isEmpty {
                        Text("Your shelf is empty. Find a book, try a chapter, and keep it here for later.")
                            .foregroundStyle(.secondary)
                        Button("Find a book") { model.navigate(.search) }
                    } else if model.currentShelfGroup != nil && model.visibleShelfBooks.isEmpty {
                        Text("This group is empty. Set a book's groups from its action menu to add it here.")
                            .foregroundStyle(.secondary).accessibilityIdentifier("shelf.emptyGroup")
                    }
                    if grid {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 205), alignment: .top)], spacing: 22) {
                            entries
                        }
                    } else {
                        LazyVStack(spacing: 12) { entries }
                    }
                }.padding(20)
            }.refreshable { model.refreshShelf() }
        }
        .sheet(item: $groupForm) { draft in ShelfGroupForm(model: model, draft: draft) }
        .sheet(item: $memberships) { draft in
            ShelfMembershipForm(model: model, draft: draft) {
                selected = []; selecting = false
            }
        }
        .confirmationDialog("Remove from shelf?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            if let removal {
                Button("Remove from shelf", role: .destructive) {
                    model.removeShelfBooks(removal.books, expectedToken: removal.token) { saved in
                        if saved { selected = []; selecting = false }
                    }
                    self.removal = nil
                }.accessibilityIdentifier("shelf.remove.confirm")
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text("Remove \(removal?.books.count ?? 0) books from the shelf and every group. Reading records and cached content will be kept.")
        }
        .confirmationDialog("Delete group?", isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            if let deletion {
                Button("Delete group", role: .destructive) {
                    model.deleteShelfGroup(deletion.group, expectedToken: deletion.token)
                    self.deletion = nil
                }.accessibilityIdentifier("shelf.deleteGroup.confirm")
            }
            Button("Cancel", role: .cancel) { deletion = nil }
        } message: { Text("Books will remain on your shelf and in their other groups. Ungrouped books will appear on home.") }
        .onChange(of: model.shelfGroupID) { _ in selected = []; selecting = false }
        .onReceive(model.$shelf) { books in
            let visible = books.filter { entry in
                model.shelfGroupID.map { entry.groupIds.contains($0) } ?? entry.groupIds.isEmpty
            }
            selected.formIntersection(visible.map(\.book.id))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            if model.shelfGroupID != nil {
                Button { model.openShelfGroup(nil) } label: { Label("Library", systemImage: "chevron.left") }
                    .accessibilityIdentifier("shelf.home")
            }
            Text(bookCount(model.shelfGroupID == nil ? model.shelf.count : model.visibleShelfBooks.count))
                .font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            layoutButton(.grid, title: "Grid view", icon: "square.grid.2x2")
            layoutButton(.list, title: "List view", icon: "list.bullet")
            if model.shelfGroupID == nil {
                Button { showGroupForm(nil) } label: { Label("New group", systemImage: "folder.badge.plus") }
                    .accessibilityIdentifier("shelf.newGroup")
            }
            Button(selecting ? "Done" : "Select") {
                selecting.toggle(); selected = []
            }.accessibilityIdentifier("shelf.select")
        }.buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 10)
            .disabled(model.busy || model.shelfToken.isEmpty)
    }

    private func layoutButton(_ mode: ShelfLayout, title: String, icon: String) -> some View {
        Button { preferences.shelfLayout = mode } label: {
            Image(systemName: icon).frame(width: 36, height: 36)
                .background(preferences.shelfLayout == mode ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.accessibilityLabel(title).accessibilityValue(preferences.shelfLayout == mode ? "Selected" : "")
            .accessibilityIdentifier("shelf.layout." + mode.rawValue)
    }

    private var selectionBar: some View {
        HStack {
            Button("Select all") { selected = Set(model.visibleShelfBooks.map(\.book.id)) }
                .accessibilityIdentifier("shelf.selectAll").disabled(model.visibleShelfBooks.isEmpty)
            Text("\(selected.count) selected").font(.subheadline).foregroundStyle(.secondary)
                .accessibilityIdentifier("shelf.selectionCount")
            Spacer()
            Menu("Actions") {
                Button("Set groups") { showMemberships(selectedBooks) }
                if let id = model.shelfGroupID {
                    Button("Remove from this group") { removeFromGroup(selectedBooks, id: id) }
                }
                Button("Remove from shelf", role: .destructive) { prepareRemoval(selectedBooks) }
            }.accessibilityIdentifier("shelf.selectionActions").disabled(selectedBooks.isEmpty)
        }.padding(.horizontal, 20).padding(.vertical, 8).background(.thinMaterial).disabled(model.busy)
    }

    @ViewBuilder private var entries: some View {
        if model.shelfGroupID == nil {
            ForEach(model.shelfGroups, id: \.id) { group in groupCell(group) }
        }
        ForEach(model.visibleShelfBooks, id: \.book.id) { book in bookCell(book) }
    }

    private func groupCell(_ group: ShelfGroupSnapshot) -> some View {
        HStack(spacing: 14) {
            Button { model.openShelfGroup(group.id) } label: {
                if grid {
                    VStack(spacing: 10) {
                        Image(systemName: "folder.fill").font(.system(size: 86)).frame(height: 172)
                            .foregroundStyle(.tint.opacity(0.75))
                        Text(group.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                        Text(bookCount(Int(group.bookCount))).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 16) {
                        Image(systemName: "folder.fill").font(.system(size: 36)).frame(width: 54, height: 78)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.name).font(.headline).foregroundStyle(.primary)
                            Text(bookCount(Int(group.bookCount))).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }
            }.buttonStyle(.plain).accessibilityIdentifier("shelf.group." + group.id)
            if !grid { groupMenu(group) }
        }
        .padding(grid ? 10 : 14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) { if grid { groupMenu(group).padding(4) } }
        .disabled(model.busy || selecting)
    }

    private func groupMenu(_ group: ShelfGroupSnapshot) -> some View {
        Menu {
            Button("Rename group") { showGroupForm(group) }
            Button("Delete group", role: .destructive) {
                deletion = ShelfGroupDeletionDraft(group: group, token: model.shelfToken)
            }
        } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44).background(.regularMaterial, in: Circle()) }
            .accessibilityLabel("Actions for " + group.name).accessibilityIdentifier("shelf.groupMenu." + group.id)
    }

    private func bookCell(_ entry: ShelfBookSnapshot) -> some View {
        HStack(spacing: 12) {
            Button {
                if selecting {
                    if selected.contains(entry.book.id) { selected.remove(entry.book.id) }
                    else { selected.insert(entry.book.id) }
                } else { model.openShelfBook(entry) }
            } label: {
                if grid {
                    VStack(alignment: .leading, spacing: 8) {
                        ShelfCover(url: entry.coverUrl, height: 172).frame(maxWidth: .infinity)
                        bookText(entry, compact: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 14) {
                        ShelfCover(url: entry.coverUrl, height: 78)
                        bookText(entry, compact: false)
                        Spacer(minLength: 0)
                        if selecting { selectionMark(entry) }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
            }.buttonStyle(.plain).accessibilityIdentifier("shelf.book." + entry.book.id)
                .accessibilityValue(selecting ? (selected.contains(entry.book.id) ? "Selected" : "Not selected") : "")
            if !grid && !selecting { bookMenu(entry) }
        }
        .padding(grid ? 10 : 14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            if grid {
                if selecting { selectionMark(entry).padding(10) }
                else { bookMenu(entry).padding(4) }
            }
        }
        .contextMenu { if !selecting { bookActions(entry) } }
        .disabled(model.busy)
    }

    private func bookText(_ entry: ShelfBookSnapshot, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.book.title).font(compact ? .subheadline.weight(.semibold) : .headline)
                .foregroundStyle(.primary).lineLimit(compact ? 2 : 3)
            Text(ReaderModel.authorLabel(entry.book.author)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if !compact {
                if !entry.lastChapter.isEmpty {
                    Label(entry.lastChapter, systemImage: "bookmark").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(entry.sourceName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectionMark(_ entry: ShelfBookSnapshot) -> some View {
        Image(systemName: selected.contains(entry.book.id) ? "checkmark.circle.fill" : "circle")
            .font(.title2).foregroundStyle(.tint).accessibilityHidden(true)
    }

    private func bookMenu(_ entry: ShelfBookSnapshot) -> some View {
        Menu { bookActions(entry) } label: {
            Image(systemName: "ellipsis.circle").frame(width: 44, height: 44).background(.regularMaterial, in: Circle())
        }.accessibilityLabel("Actions for " + entry.book.title).accessibilityIdentifier("shelf.bookMenu." + entry.book.id)
    }

    @ViewBuilder private func bookActions(_ entry: ShelfBookSnapshot) -> some View {
        Button("Set groups") { showMemberships([entry]) }
        if let id = model.shelfGroupID {
            Button("Remove from this group") { removeFromGroup([entry], id: id) }
        }
        Button("Remove from shelf", role: .destructive) { prepareRemoval([entry]) }
    }

    private func showGroupForm(_ group: ShelfGroupSnapshot?) {
        model.message = nil
        groupForm = ShelfGroupFormDraft(group: group, token: model.shelfToken)
    }
    private func bookCount(_ count: Int) -> String { count == 1 ? "1 book" : "\(count) books" }
    private func showMemberships(_ books: [ShelfBookSnapshot]) {
        model.message = nil
        memberships = ShelfMembershipDraft(books: books, groups: model.shelfGroups, token: model.shelfToken)
    }
    private func prepareRemoval(_ books: [ShelfBookSnapshot]) {
        removal = ShelfRemovalDraft(books: books, token: model.shelfToken)
    }
    private func removeFromGroup(_ books: [ShelfBookSnapshot], id: String) {
        model.changeShelfGroups(books, add: [], remove: [id]) { saved in
            if saved { selected = []; selecting = false }
        }
    }
}

private struct ShelfCover: View {
    let url: String?
    let height: CGFloat
    private var imageURL: URL? {
        guard let url, let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme?.lowercased() ?? "") else { return nil }
        return parsed
    }
    var body: some View {
        AsyncImage(url: imageURL) { phase in
            if case .success(let image) = phase { image.resizable().scaledToFit() }
            else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color(uiColor: .tertiarySystemFill))
                    Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
        }.frame(width: height * 0.68, height: height).clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
    }
}

@MainActor
private struct ShelfGroupForm: View {
    @ObservedObject var model: ReaderModel
    let draft: ShelfGroupFormDraft
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    init(model: ReaderModel, draft: ShelfGroupFormDraft) {
        self.model = model; self.draft = draft
        _name = State(initialValue: draft.group?.name ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Group name", text: $name).accessibilityIdentifier("shelf.groupName")
                if let message = model.message { Text(message).foregroundStyle(.red) }
                if model.shelfToken != draft.token {
                    Text("The shelf changed. Cancel and reopen this editor to review the current groups.")
                        .foregroundStyle(.secondary).accessibilityIdentifier("shelf.editor.stale")
                }
            }.navigationTitle(draft.group == nil ? "New group" : "Rename group")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let completion: (Bool) -> Void = { if $0 { dismiss() } }
                            if let group = draft.group { model.renameShelfGroup(group, name: name, expectedToken: draft.token, completion: completion) }
                            else { model.createShelfGroup(name, expectedToken: draft.token, completion: completion) }
                        }.accessibilityIdentifier("shelf.group.save")
                            .disabled(model.busy || model.shelfToken != draft.token || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }.interactiveDismissDisabled(model.busy)
    }
}

@MainActor
private struct ShelfMembershipForm: View {
    @ObservedObject var model: ReaderModel
    let draft: ShelfMembershipDraft
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var changes: [String: Bool] = [:]

    private enum Membership { case none, mixed, all }
    private func membership(_ id: String) -> Membership {
        if let changed = changes[id] { return changed ? .all : .none }
        let count = draft.books.filter { $0.groupIds.contains(id) }.count
        return count == 0 ? .none : count == draft.books.count ? .all : .mixed
    }
    private func label(_ value: Membership) -> String {
        switch value { case .none: return "Not selected"; case .mixed: return "Some books"; case .all: return "Selected" }
    }
    private func icon(_ value: Membership) -> String {
        switch value { case .none: return "circle"; case .mixed: return "minus.circle.fill"; case .all: return "checkmark.circle.fill" }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(draft.books.count) books. Untouched groups keep each book's existing membership.")
                        .font(.callout).foregroundStyle(.secondary)
                    if draft.groups.isEmpty { Text("No groups yet. Create a group from Library, then organize your books.") }
                    ForEach(draft.groups, id: \.id) { group in
                        Button { changes[group.id] = membership(group.id) != .all } label: {
                            HStack {
                                Text(group.name).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: icon(membership(group.id)))
                            }.contentShape(Rectangle())
                        }.accessibilityIdentifier("shelf.membership.group." + group.id)
                            .accessibilityValue(label(membership(group.id)))
                    }
                }
                if let message = model.message { Text(message).foregroundStyle(.red) }
                if model.shelfToken != draft.token {
                    Text("The shelf changed. Cancel and reopen this editor to review the current groups.")
                        .foregroundStyle(.secondary).accessibilityIdentifier("shelf.editor.stale")
                }
            }.navigationTitle("Set groups")
                .disabled(model.busy)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            model.changeShelfGroups(draft.books, add: changes.filter(\.value).map(\.key),
                                                    remove: changes.filter { !$0.value }.map(\.key), expectedToken: draft.token) { success in
                                if success { saved(); dismiss() }
                            }
                        }.accessibilityIdentifier("shelf.membership.save").disabled(model.busy || model.shelfToken != draft.token)
                    }
                }
        }.interactiveDismissDisabled(model.busy)
    }
}
