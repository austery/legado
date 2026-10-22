import SwiftUI
import UniformTypeIdentifiers
import ReaderEngine

struct SourceExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var json: String
    init(json: String) { self.json = json }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        json = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(json.utf8))
    }
}

@MainActor
struct SourceManagementView: View {
    @ObservedObject var model: ReaderModel
    let importFile: () -> Void
    @State private var query = ""
    @State private var status = "All"
    @State private var group: String?
    @State private var selecting = false
    @State private var groupName = ""
    @State private var editingGroups = false
    @State private var detailID: String?
    @State private var editingDetailGroups = false
    @State private var pendingDetailExport: String?

    private var groups: [String] { Array(Set(model.managedSources.flatMap(\.groups))).sorted() }
    private var visible: [ManagedSource] {
        model.managedSources.filter { source in
            (status == "All" || source.enabled == (status == "Enabled")) &&
            (group.map { source.groups.contains($0) } ?? true) &&
            (query.isEmpty || source.name.localizedCaseInsensitiveContains(query) ||
             source.id.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Button("Import sources", action: importFile).accessibilityIdentifier("sources.import")
                    Spacer()
                    Button(selecting ? "Done" : "Select") { selecting.toggle() }
                        .accessibilityIdentifier("sources.select")
                }.buttonStyle(.borderless)
                Picker("Status", selection: $status) {
                    ForEach(["All", "Enabled", "Disabled"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("sources.status")
                Picker("Group", selection: $group) {
                    Text("All groups").tag(Optional<String>.none)
                    ForEach(groups, id: \.self) { Text($0).tag(Optional($0)) }
                }.accessibilityIdentifier("sources.groupFilter")
                if let details = model.importDetails {
                    DisclosureGroup("Import details") {
                        Text(details).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            } footer: {
                if let notice = model.importNotice { Text(notice) }
            }
            if selecting {
                Section("\(model.managedSelection.count) selected") {
                    HStack {
                        Button("Select visible") { model.managedSelection.formUnion(visible.map(\.id)) }
                        Spacer()
                        Button("Clear selection") { model.managedSelection = [] }
                    }.buttonStyle(.borderless)
                    HStack(spacing: 12) {
                        Button("Enable") { model.setSourcesEnabled(Array(model.managedSelection), enabled: true) }
                        Button("Disable") { model.setSourcesEnabled(Array(model.managedSelection), enabled: false) }
                        Button("Groups") { editingGroups = true }
                        Button("Export") { model.exportSources(Array(model.managedSelection)) }
                    }.buttonStyle(.bordered).disabled(model.managedSelection.isEmpty)
                }
            }
            Section("Sources (\(visible.count))") {
                if visible.isEmpty { Text("No matching text sources.").foregroundStyle(.secondary) }
                ForEach(visible, id: \.id) { source in
                    HStack(alignment: .center, spacing: 12) {
                        if selecting {
                            Button {
                                if !model.managedSelection.insert(source.id).inserted {
                                    model.managedSelection.remove(source.id)
                                }
                            } label: {
                                Image(systemName: model.managedSelection.contains(source.id) ? "checkmark.circle.fill" : "circle")
                            }.buttonStyle(.borderless).accessibilityLabel("Select \(source.name)")
                        }
                        Button { detailID = source.id } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(source.name).font(.headline).foregroundStyle(.primary)
                                Text(source.groups.isEmpty ? "Ungrouped" : source.groups.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(source.id).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.borderless)
                        Toggle("Enabled", isOn: Binding(get: { source.enabled }, set: {
                            model.setSourcesEnabled([source.id], enabled: $0)
                        })).labelsHidden().accessibilityLabel("Enable \(source.name)")
                    }.padding(.vertical, 3)
                }
            }
        }
        .searchable(text: $query, prompt: "Source name or address")
        .disabled(model.busy || !model.initialized)
        .task { model.refreshManagedSources() }
        .onChange(of: groups) { values in if let selected = group, !values.contains(selected) { group = nil } }
        .sheet(isPresented: Binding(get: { model.sourceImportPreview != nil }, set: {
            if !$0 { model.cancelSourceImport() }
        })) { importPreview }
        .sheet(isPresented: $editingGroups) { groupEditor }
        .sheet(isPresented: Binding(get: { detailID != nil }, set: { if !$0 { detailID = nil } }), onDismiss: {
            if let id = pendingDetailExport { pendingDetailExport = nil; model.exportSources([id]) }
        }) {
            if let source = model.managedSources.first(where: { $0.id == detailID }) { details(source) }
        }
        .fileExporter(isPresented: Binding(get: { model.sourceExportJSON != nil }, set: {
            if !$0 { model.sourceExportJSON = nil }
        }), document: SourceExportDocument(json: model.sourceExportJSON ?? "[]"),
            contentType: .json, defaultFilename: "Legado-sources") { result in
                if case .failure(let error) = result { model.message = "Export failed: \(error.localizedDescription)" }
                model.sourceExportJSON = nil
            }
    }

    private var importPreview: some View {
        NavigationStack {
            List {
                Section {
                    if let message = model.message {
                        Text(message).foregroundStyle(.red)
                        Button("Refresh preview") { model.refreshSourceImportPreview() }.disabled(model.busy)
                    }
                    Text("Review before importing. Nothing changes until you confirm.")
                    Text("New and newer versions are selected by default. Update timestamps are advisory.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Keep local names", isOn: $model.importKeepName)
                    Toggle("Keep local groups", isOn: $model.importKeepGroups)
                    Toggle("Keep local enabled settings", isOn: $model.importKeepEnabled)
                }
                ForEach(model.sourceImportPreview?.items ?? [], id: \.source.id) { item in
                    importItem(item)
                }
            }
            .navigationTitle("Review import")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancelSourceImport() }.disabled(model.busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import selected") { model.confirmSourceImport() }
                        .disabled(model.busy || model.sourceImportSelection.isEmpty)
                        .accessibilityIdentifier("sources.confirmImport")
                }
            }
            .interactiveDismissDisabled(model.busy)
        }
    }

    private func importItem(_ item: SourceImportItem) -> some View {
        Toggle(isOn: Binding(get: { model.sourceImportSelection.contains(item.source.id) }, set: { selected in
            if selected { model.sourceImportSelection.insert(item.source.id) }
            else { model.sourceImportSelection.remove(item.source.id) }
        })) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.source.name).font(.headline)
                Text(item.source.id).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                Text(importKindLabel(item.kind)).font(.caption)
                Text(item.source.enabled ? "Enabled in file" : "Disabled in file").font(.caption)
                Text("Incoming update: \(item.source.updatedAt)").font(.caption2)
                if let previous = item.previousUpdatedAt { Text("Local update: \(previous)").font(.caption2) }
                if item.duplicateCount > 0 {
                    Text("\(item.duplicateCount) duplicate entries; the last entry is used.").font(.caption)
                }
            }
        }
    }

    private func importKindLabel(_ kind: SourceImportKind) -> String {
        if kind == .theNew { return "New source" }
        if kind == .newer { return "Newer version · replaces existing rules" }
        return "Existing source · replacement optional"
    }

    private var groupEditor: some View {
        NavigationStack {
            Form {
                Section("New group") {
                    TextField("Group name", text: $groupName).accessibilityIdentifier("sources.groupName")
                }
                Section("Existing groups") {
                    ForEach(groups, id: \.self) { name in
                        HStack {
                            Text(name)
                            Spacer()
                            Button("Remove") { updateGroup(name, add: false) }
                                .buttonStyle(.borderless).accessibilityLabel("Remove from \(name)")
                        }
                    }
                }
                if let message = model.message { Text(message).foregroundStyle(.red) }
            }
            .navigationTitle("Source groups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { editingGroups = false; editingDetailGroups = false }.disabled(model.busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to group") { updateGroup(groupName, add: true) }
                        .disabled(model.busy || groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(model.busy)
        }
    }

    private func updateGroup(_ name: String, add: Bool) {
        model.changeSourceGroup(Array(model.managedSelection), group: name, add: add) {
            editingGroups = false; editingDetailGroups = false
        }
    }

    private func details(_ source: ManagedSource) -> some View {
        NavigationStack {
            Form {
                LabeledContent("Name", value: source.name)
                Toggle("Show in Discover", isOn: Binding(get: { source.discoveryEnabled }, set: {
                    model.setSourceDiscoveryEnabled(source.id, enabled: $0)
                })).disabled(model.busy).accessibilityIdentifier("sources.discoveryEnabled")
                if !source.hasDiscovery { Text("This source has no discovery categories.").font(.caption).foregroundStyle(.secondary) }
                LabeledContent("Identity") { Text(source.id).textSelection(.enabled) }
                LabeledContent("Groups", value: source.groups.joined(separator: ", "))
                Toggle("Enabled", isOn: Binding(get: { source.enabled }, set: {
                    model.setSourcesEnabled([source.id], enabled: $0)
                })).disabled(model.busy)
                Button("Manage groups") {
                    model.managedSelection = [source.id]; editingDetailGroups = true
                }
                Button("Export source") { pendingDetailExport = source.id; detailID = nil }
            }.navigationTitle("Source details")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detailID = nil } } }
        }.sheet(isPresented: $editingDetailGroups) { groupEditor }
    }
}
