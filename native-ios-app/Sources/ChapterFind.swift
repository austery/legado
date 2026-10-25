import SwiftUI

struct ChapterFindContext: Equatable {
    let chapterKey: String
    let readingIdentity: String
    let text: String
}

@MainActor
final class ChapterFindSession: ObservableObject {
    @Published private(set) var context: ChapterFindContext?
    @Published var query = "" { didSet { updateMatches() } }
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

    private func updateMatches() {
        selectedIndex = nil
        guard let context, !query.isEmpty else { matches = []; return }
        let body = context.text as NSString
        var found: [NSRange] = []
        var cursor = 0
        while cursor < body.length {
            let range = body.range(of: query, options: .literal,
                                   range: NSRange(location: cursor, length: body.length - cursor))
            guard range.location != NSNotFound else { break }
            found.append(range)
            cursor = NSMaxRange(range)
        }
        matches = found
    }

    func move(forward: Bool) {
        guard context != nil, !matches.isEmpty else { return }
        if let selectedIndex {
            self.selectedIndex = (selectedIndex + (forward ? 1 : -1) + matches.count) % matches.count
        } else {
            selectedIndex = forward ? 0 : matches.count - 1
        }
    }
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
