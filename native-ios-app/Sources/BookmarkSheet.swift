import SwiftUI

struct BookmarkSheet: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        NavigationStack {
            List {
                if model.bookmarkBusy { ProgressView("Updating bookmarks") }
                if let notice = model.bookmarkNotice {
                    Text(notice).accessibilityIdentifier("bookmarks.notice")
                    if model.canRetryBookmark {
                        Button("Retry", action: model.retryBookmark).disabled(model.bookmarkBusy)
                    }
                }
                if model.bookmarks.isEmpty && !model.bookmarkBusy {
                    Text("No bookmarks yet. Save a paragraph while reading.")
                        .accessibilityIdentifier("bookmarks.empty")
                }
                ForEach(model.bookmarks, id: \.id) { bookmark in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { model.openBookmark(bookmark) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(bookmark.chapterTitle).font(.headline)
                                Text(bookmark.excerpt).font(.body).lineLimit(3)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(model.busy || model.bookmarkBusy || !bookmark.availableInCurrentSource)
                        .accessibilityIdentifier("bookmarks.open.\(bookmark.id)")
                        if !bookmark.availableInCurrentSource {
                            Text("Unavailable in the current source. Switch back to the saved source to open it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Delete bookmark", role: .destructive) { model.deleteBookmark(bookmark) }
                            .disabled(model.busy || model.bookmarkBusy)
                            .accessibilityIdentifier("bookmarks.delete.\(bookmark.id)")
                    }.padding(.vertical, 4)
                }
            }
            .navigationTitle("Bookmarks")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: model.closeBookmarks).accessibilityIdentifier("bookmarks.done")
                }
            }
        }
    }
}
