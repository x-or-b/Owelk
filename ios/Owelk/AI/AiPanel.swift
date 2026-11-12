import SwiftUI

/// The AI over the paper, in a small window of its own: moved by its bar, sized from either bottom corner (unmarked),
/// and its conversation as see-through as the reader likes (the paper shows under it; the bar stays solid, so it can
/// always be found, moved and closed). Where it was, its size and its opacity are kept.
struct FloatingAiPanel: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject var model: ReaderModel
    /// Moved or sized by the reader (until then it sits at the top right).
    @AppStorage("ai.window.placed") private var placed = false
    @AppStorage("ai.window.x") private var x = 0.0
    @AppStorage("ai.window.y") private var y = 0.0
    @AppStorage("ai.window.width") private var width = 400.0
    @AppStorage("ai.window.height") private var height = 560.0
    @AppStorage("ai.window.opacity") private var opacity = 1.0
    /// A drag under way, measured on the screen (the window moving under the finger would otherwise feed back into
    /// the drag), and kept only when the finger lifts.
    @GestureState private var moving = CGSize.zero
    @GestureState private var sizing: Sizing?
    /// The list of chats is open over the conversation.
    @State private var listing = false

    static let smallest = CGSize(width: 300, height: 260)

    /// A bottom corner the window is sized from; the other side stays where it is.
    enum Corner { case left, right }

    struct Sizing {
        let corner: Corner
        let drag: CGSize
    }

    var body: some View {
        GeometryReader { space in
            let area = space.size
            let rest = Self.frame(in: area, at: placed ? CGPoint(x: x, y: y) : nil, width: width, height: height)
            let frame = sizing.map { Self.sized(rest, by: $0.drag, from: $0.corner, in: area) }
                ?? Self.moved(rest, by: moving, in: area)
            VStack(spacing: 0) {
                bar(rest, in: area)
                Divider()
                FloatingConversation(model: model)
                    .background(Color(uiColor: .systemBackground))
                    .compositingGroup()
                    .opacity(opacity)
                    .overlay {
                        if listing {
                            WindowChats(chat: model.ai, paper: model.paper) { id in
                                listing = false
                                Task { await model.ai.open(id) }
                            }
                            .background(Color(uiColor: .systemBackground))
                        }
                    }
            }
            .frame(width: frame.width, height: frame.height)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(uiColor: .separator)))
            .overlay(alignment: .bottomLeading) { grip(.left, rest, in: area) }
            .overlay(alignment: .bottomTrailing) { grip(.right, rest, in: area) }
            .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
            .offset(x: frame.minX, y: frame.minY)
        }
    }

    /// Where the window is in an area: as it was left, kept inside the area; at first, at the top right.
    static func frame(in area: CGSize, at origin: CGPoint?, width: Double, height: Double) -> CGRect {
        let size = CGSize(width: max(smallest.width, min(width, area.width - 16)),
                          height: max(smallest.height, min(height, area.height - 16)))
        let left = origin?.x ?? area.width - size.width - 16
        let top = origin?.y ?? 16
        return CGRect(x: max(8, min(left, area.width - size.width - 8)), y: max(8, min(top, area.height - size.height - 8)),
                      width: size.width, height: size.height)
    }

    /// The window moved by a drag, kept inside the area.
    static func moved(_ frame: CGRect, by drag: CGSize, in area: CGSize) -> CGRect {
        Self.frame(in: area, at: CGPoint(x: frame.minX + drag.width, y: frame.minY + drag.height),
                   width: frame.width, height: frame.height)
    }

    /// The window sized from a bottom corner: its top and its other side stay put, and it grows only into the room
    /// there is (a window at the right edge grows wider from its left corner).
    static func sized(_ frame: CGRect, by drag: CGSize, from corner: Corner, in area: CGSize) -> CGRect {
        let height = max(smallest.height, min(frame.height + drag.height, area.height - 8 - frame.minY))
        switch corner {
        case .right:
            let width = max(smallest.width, min(frame.width + drag.width, area.width - 8 - frame.minX))
            return CGRect(x: frame.minX, y: frame.minY, width: width, height: height)
        case .left:
            let width = max(smallest.width, min(frame.width - drag.width, frame.maxX - 8))
            return CGRect(x: frame.maxX - width, y: frame.minY, width: width, height: height)
        }
    }

    private func keep(_ frame: CGRect) {
        placed = true
        x = frame.minX
        y = frame.minY
        width = frame.width
        height = frame.height
    }

    private func bar(_ rest: CGRect, in area: CGSize) -> some View {
        HStack(spacing: 10) {
            // Every chat, this paper's first.
            Button {
                listing.toggle()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(listing ? Theme.accent : Color.primary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Chats")
            .accessibilityAddTraits(listing ? .isSelected : [])
            .padding(.leading, 10)
            // The handle: the window moves from here, not from the controls beside it.
            HStack(spacing: 10) {
                Text("AI").font(.headline)
                Text(AiSettings.model(for: AiSettings.service)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.vertical, 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .updating($moving) { drag, moving, _ in moving = drag.translation }
                .onEnded { drag in keep(Self.moved(rest, by: drag.translation, in: area)) })
            Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary).accessibilityHidden(true)
            Slider(value: $opacity, in: 0.35...1).frame(width: 90).accessibilityLabel("Opacity")
            Button {
                listing = false
                model.ai.clear()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .labelStyle(.iconOnly)
            .disabled(model.ai.turns.isEmpty || model.ai.running)
            Button {
                model.showsAI = false
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .padding(.trailing, 14)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(uiColor: .systemBackground))
        .tint(.primary)
    }

    /// A bottom corner, unmarked, that sizes the window when dragged.
    private func grip(_ corner: Corner, _ rest: CGRect, in area: CGSize) -> some View {
        Color.clear
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating($sizing) { drag, sizing, _ in sizing = Sizing(corner: corner, drag: drag.translation) }
                .onEnded { drag in keep(Self.sized(rest, by: drag.translation, from: corner, in: area)) })
            .accessibilityLabel("Resize")
    }
}

/// The chats the window can show: this paper's, those of the collections it is in, then every other one (the Mac's
/// among them). Those about something else are read in the window.
private struct WindowChats: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject var chat: AiChat
    let paper: Paper
    let open: (String) -> Void

    var body: some View {
        let library = store.library
        let collections = Set(paper.collections.map { "collection:" + $0 })
        let here = library.threads.filter { $0.paper == paper.id }
        let near = library.threads.filter { $0.paper != paper.id && collections.contains($0.folder) }
        let rest = library.threads.filter { $0.paper != paper.id && !collections.contains($0.folder) }
        List {
            group("This Paper", here, places: false)
            group("This Paper's Collections", near, places: true)
            group("Other Chats", rest, places: true)
        }
        .listStyle(.plain)
        .contentMargins(.horizontal, 12, for: .scrollContent)
        .overlay {
            if library.threads.isEmpty {
                Text("No chats yet.").foregroundStyle(.secondary)
            }
        }
        .disabled(chat.running)
    }

    @ViewBuilder
    private func group(_ title: String, _ chats: [AiThread], places: Bool) -> some View {
        if !chats.isEmpty {
            Section(title) {
                ForEach(chats) { item in
                    Button {
                        open(item.id)
                    } label: {
                        HStack {
                            ChatRow(chat: item, place: places ? store.library.place(of: item) : "")
                            Spacer(minLength: 8)
                            if item.id == chat.thread {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .accessibilityAddTraits(item.id == chat.thread ? .isSelected : [])
                }
            }
        }
    }
}

/// The window's conversation, apart from the window: moving or sizing the window, or turning pages, doesn't redraw
/// the answers (the chat redraws them as they change).
private struct FloatingConversation: View {
    let model: ReaderModel

    var body: some View {
        AiPanel(chat: model.ai) { model.go(toPage: $0) }
    }
}

/// The AI's conversation about the paper: answers about it, a three-line summary, and explanations of selected text.
/// Places the answers cite ([p. 3: "…"]) open their page.
struct AiPanel: View {
    @ObservedObject var chat: AiChat
    let goToPage: (Int) -> Void
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if chat.turns.isEmpty { start }
                        ForEach(chat.turns) { turn in
                            TurnView(turn: turn).id(turn.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: chat.turns.last?.answer) { _, _ in
                    if let last = chat.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            composer
        }
        .tint(.primary)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "owelk-page", let page = Int(url.absoluteString.dropFirst("owelk-page:".count)) else {
                return .systemAction
            }
            goToPage(page - 1)
            return .handled
        })
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 12) {
            if chat.hasKey {
                Text("Ask about this paper, or select text and choose Explain or Ask AI.")
                    .foregroundStyle(.secondary)
                Button {
                    chat.summarize()
                } label: {
                    Label("Summarize This Paper", systemImage: "list.bullet")
                }
                .buttonStyle(.bordered)
            } else {
                Text("Add your Claude or OpenAI API key in Settings (the gear in the library). The paper's text and "
                     + "your question go to that service when you ask. Past chats, the Mac's among them, are under "
                     + "the menu button at the top left.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var composer: some View {
        if let elsewhere = chat.elsewhere, chat.attached == nil {
            // Asked here, a question carries this paper's text: kept in that chat, or in a copy kept with this paper.
            VStack(alignment: .leading, spacing: 10) {
                Text(elsewhere.isEmpty ? "This chat isn't about this paper." : "This chat is about “\(elsewhere)”.")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 10) {
                    Button {
                        chat.goOn()
                    } label: {
                        Label("Continue", systemImage: "arrow.turn.down.right").frame(maxWidth: .infinity)
                    }
                    Button {
                        Task { await chat.fork() }
                    } label: {
                        Label("Fork for This Paper", systemImage: "arrow.triangle.branch").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(chat.running)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        } else {
            questionField
        }
    }

    private var questionField: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attached = chat.attached {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1).fill(.secondary).frame(width: 3)
                    Text(attached).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    Spacer()
                    Button {
                        chat.attached = nil
                    } label: {
                        Image(systemName: "xmark").imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove the selection")
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(chat.attached == nil ? "Ask about this paper" : "Ask about the selection", text: $chat.draft,
                          axis: .vertical)
                    .lineLimit(1...6)
                    .focused($typing)
                    .onSubmit { chat.ask() }
                if chat.running {
                    Button {
                        chat.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                    .accessibilityLabel("Stop")
                } else {
                    Button {
                        chat.ask()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .tint(Theme.accent)
                    .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                }
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(12)
        .onChange(of: chat.attached) { _, attached in if attached != nil { typing = true } }
        .onAppear { if chat.attached != nil { typing = true } }
    }
}

struct TurnView: View {
    let turn: AiChat.Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.asked)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            if !turn.answer.isEmpty { AnswerText(text: turn.answer) }
            if turn.running && turn.answer.isEmpty { ProgressView() }
            if turn.cutOff { Text("The answer was cut off at its length limit.").font(.caption).foregroundStyle(.secondary) }
            if let error = turn.error { Text(error).font(.callout).foregroundStyle(.red) }
        }
    }
}

/// An answer's Markdown, line by line: headings bold, list items with bullets, inline styles and links (page
/// citations among them) as Markdown has them. Math stays as written.
struct AnswerText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.lines(text).enumerated()), id: \.offset) { _, line in
                Self.view(for: line)
            }
        }
        .textSelection(.enabled)
    }

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").reduce(into: [String]()) { lines, line in
            // Blank lines between paragraphs only (not runs of them).
            if line.trimmingCharacters(in: .whitespaces).isEmpty, lines.last?.isEmpty ?? true { return }
            lines.append(line.trimmingCharacters(in: .whitespaces).isEmpty ? "" : line)
        }
    }

    @ViewBuilder
    private static func view(for line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Color.clear.frame(height: 2)
        } else if trimmed.hasPrefix("#") {
            Text(inline(trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))).font(.headline)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(inline(String(trimmed.dropFirst(2))))
            }
            .padding(.leading, CGFloat(line.prefix { $0 == " " }.count / 2) * 12)
        } else {
            Text(inline(trimmed))
        }
    }

    static func inline(_ text: String) -> AttributedString {
        let linked = AiPrompt.linkingPages(text)
        return (try? AttributedString(markdown: linked,
                                      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
