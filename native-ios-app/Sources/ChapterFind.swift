import SwiftUI

struct ChapterFindContext: Equatable {
    let chapterKey: String
    let readingIdentity: String
    let text: String
}

@MainActor
final class ChapterFindSession: ObservableObject {
    @Published private(set) var context: ChapterFindContext?
    @Published var query = ""
    @Published private(set) var matches: [NSRange] = []
    @Published private(set) var selectedIndex: Int?
    var isPresented: Bool { context != nil }

    func open(_ context: ChapterFindContext) {
        self.context = context
        query = ""
        matches = []
        selectedIndex = nil
    }

    func updateContext(_ current: ChapterFindContext?) {
        if context != nil && context != current { close() }
    }

    func close() {
        context = nil
        query = ""
        matches = []
        selectedIndex = nil
    }

    func move(forward: Bool) {}
}

struct ChapterFindPanel: View {
    @ObservedObject var session: ChapterFindSession
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Find in current chapter", text: $session.query)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    .textInputAutocapitalization(.never).focused($editing)
                    .accessibilityIdentifier("reader.find.query")
                    .onSubmit { editing = false }
                Button { editing = false; session.close() } label: {
                    Label("Close find", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }.accessibilityIdentifier("reader.find.close")
            }
            HStack {
                Text(status).font(.callout).accessibilityIdentifier("reader.find.status")
                Spacer()
                Button("Previous match") { editing = false; session.move(forward: false) }
                    .accessibilityIdentifier("reader.find.previous").disabled(session.matches.isEmpty)
                Button("Next match") { editing = false; session.move(forward: true) }
                    .accessibilityIdentifier("reader.find.next").disabled(session.matches.isEmpty)
            }
            Text("Current chapter only · Case sensitive").font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 16).padding(.vertical, 8).background(.regularMaterial)
    }

    private var status: String {
        if session.query.isEmpty { return "Enter text to find" }
        if session.matches.isEmpty { return "No matches" }
        if let index = session.selectedIndex { return "\(index + 1) of \(session.matches.count)" }
        return "\(session.matches.count) matches"
    }
}
