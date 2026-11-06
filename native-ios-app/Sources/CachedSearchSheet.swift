import SwiftUI

struct CachedSearchSheet: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Search cached original text", text: $model.cachedSearchQuery)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("cachedSearch.query")
                    .onSubmit(model.searchCachedChapters)
                HStack {
                    Button("Search", action: model.searchCachedChapters)
                        .accessibilityIdentifier("cachedSearch.submit")
                        .disabled(model.cachedSearchBusy || model.busy || model.cachedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.cachedSearchBusy {
                        ProgressView("Searching cached chapters")
                        Button("Cancel", action: model.cancelCachedSearch).accessibilityIdentifier("cachedSearch.cancel")
                    }
                }
                if let notice = model.cachedSearchNotice {
                    Text(notice).accessibilityIdentifier("cachedSearch.notice")
                    Button("Search again", action: model.searchCachedChapters)
                        .disabled(model.busy || model.cachedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let result = model.cachedSearchResults {
                    Text("Searched \(result.cachedChapters) cached chapters; checked \(result.examinedChapters) of \(result.totalChapters) chapters.")
                        .font(.caption).accessibilityIdentifier("cachedSearch.coverage")
                    if result.truncated {
                        Text("Showing the first 200 matches. Refine your search for more specific results.")
                            .accessibilityIdentifier("cachedSearch.truncated")
                    } else if result.cachedChapters < result.totalChapters {
                        Text("Some chapters have no cached text and were not searched.")
                            .font(.caption).accessibilityIdentifier("cachedSearch.partial")
                    }
                    if result.hits.isEmpty {
                        Text(result.cachedChapters == 0 ? "No cached text to search." : "No matches in cached text.")
                            .accessibilityIdentifier("cachedSearch.empty")
                    }
                    List(Array(result.hits.enumerated()), id: \.offset) { index, hit in
                        Button { model.openCachedSearchHit(hit) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.chapterTitle).font(.headline)
                                Text(hit.excerpt).font(.body)
                            }
                        }.accessibilityIdentifier("cachedSearch.hit.\(index)").disabled(model.busy)
                    }
                } else if !model.cachedSearchBusy && model.cachedSearchNotice == nil {
                    Text("Search the original text already cached for this book. No chapters will be downloaded.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding()
            .navigationTitle("Search cached chapters")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: model.closeCachedSearch).accessibilityIdentifier("cachedSearch.done")
            } }
        }
    }
}
