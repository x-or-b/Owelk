import SwiftUI

/// The AI conversations from every computer (the desktop's Threads): the latest first, searched by title or by the
/// paper or folder they are about. One opens to read with no API key; one about a paper also opens that paper with
/// it in the AI window, to go on with it there.
struct ChatsScreen: View {
    @EnvironmentObject private var store: LibraryStore
    /// A paper opened with a chat beside it, at a place an answer links to.
    let openPaper: (Paper, String?, PaperLink?) -> Void
    @State private var query = ""

    var body: some View {
        let places = Dictionary(store.library.threads.map { ($0.id, place(of: $0)) }) { first, _ in first }
        let words = query.split(separator: " ").map(String.init)
        let chats = store.library.threads.filter { chat in
            words.allSatisfy { chat.title.localizedStandardContains($0) || (places[chat.id] ?? "").localizedStandardContains($0) }
        }
        NavigationStack {
            List(chats) { chat in
                NavigationLink(value: chat) { ChatRow(chat: chat, place: places[chat.id] ?? "") }
            }
            .listStyle(.plain)
            .overlay {
                if chats.isEmpty {
                    Text(query.isEmpty ? "No chats yet. Chats with the AI on any computer show here."
                                       : "No chats match “\(query)”.")
                        .foregroundStyle(.secondary).padding()
                }
            }
            .navigationTitle("Chats")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Chats")
            .navigationDestination(for: AiThread.self) { chat in
                ChatView(chat: chat, place: place(of: chat), paper: paper(of: chat), openPaper: openPaper)
            }
        }
    }

    private func paper(of chat: AiThread) -> Paper? { store.library.paper(of: chat) }

    private func place(of chat: AiThread) -> String { store.library.place(of: chat) }
}

struct ChatRow: View {
    let chat: AiThread
    let place: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(chat.title.isEmpty ? "Chat" : chat.title).font(.body.weight(.medium)).lineLimit(2)
            if !place.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: chat.paper.isEmpty ? "folder" : "doc.text").imageScale(.small)
                    Text(place).lineLimit(1)
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            if let date = ISO8601DateFormatter.withFraction.date(from: chat.updatedAt) {
                Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A conversation to read: each question with its answer, as the AI window shows them.
private struct ChatView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.openURL) private var openElsewhere
    let chat: AiThread
    let place: String
    let paper: Paper?
    let openPaper: (Paper, String?, PaperLink?) -> Void
    @State private var turns: [AiChat.Turn]?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if !place.isEmpty {
                    Label(place, systemImage: paper == nil ? "folder" : "doc.text")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(turns ?? []) { TurnView(turn: $0) }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if turns == nil {
                ProgressView()
            } else if turns?.isEmpty == true {
                Text("This chat has no messages.").foregroundStyle(.secondary)
            }
        }
        .tint(.primary)
        .navigationTitle(chat.title.isEmpty ? "Chat" : chat.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let paper {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Open Paper") { openPaper(paper, chat.id, nil) }
                }
            }
        }
        // A place in this chat's paper an answer cites opens the paper there, with this chat beside it; other links
        // are followed as the library follows them.
        .environment(\.openURL, OpenURLAction { url in
            if let paper, let link = PaperLink(url),
               link.document.isEmpty || store.library.paperOf[link.document] == paper.id {
                openPaper(paper, chat.id, link)
            } else {
                openElsewhere(url)
            }
            return .handled
        })
        .task(id: chat.id) { turns = AiChat.turns(of: await store.messages(of: chat.id)) }
    }
}
