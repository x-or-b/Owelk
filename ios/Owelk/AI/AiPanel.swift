import SwiftUI

/// The AI beside the paper: answers about it, a three-line summary, and explanations of selected text. Places the
/// answers cite ([p. 3: "…"]) open their page.
struct AiPanel: View {
    @ObservedObject var chat: AiChat
    let goToPage: (Int) -> Void
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI").font(.headline)
                Text(AiSettings.model(for: AiSettings.service)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button {
                    chat.clear()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .labelStyle(.iconOnly)
                .disabled(chat.turns.isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
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
                     + "your question go to that service when you ask.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var composer: some View {
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
    }
}

private struct TurnView: View {
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
