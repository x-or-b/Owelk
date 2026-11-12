import SwiftUI

/// The AI over the paper, in a small window of its own: moved by its bar, sized from its corner, and as see-through
/// as the reader likes (the paper shows under it). Where it was, its size and its opacity are kept.
struct FloatingAiPanel: View {
    @ObservedObject var model: ReaderModel
    /// Moved or sized by the reader (until then it sits at the top right).
    @AppStorage("ai.window.placed") private var placed = false
    @AppStorage("ai.window.x") private var x = 0.0
    @AppStorage("ai.window.y") private var y = 0.0
    @AppStorage("ai.window.width") private var width = 400.0
    @AppStorage("ai.window.height") private var height = 560.0
    @AppStorage("ai.window.opacity") private var opacity = 1.0
    @State private var moving: CGPoint?
    @State private var sizing: CGSize?

    static let smallest = CGSize(width: 300, height: 260)

    var body: some View {
        GeometryReader { space in
            let frame = Self.frame(in: space.size, at: placed ? CGPoint(x: x, y: y) : nil, width: width, height: height)
            VStack(spacing: 0) {
                bar(frame)
                Divider()
                AiPanel(chat: model.ai) { model.go(toPage: $0) }
            }
            .frame(width: frame.width, height: frame.height)
            .background(Color(uiColor: .systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(uiColor: .separator)))
            .overlay(alignment: .bottomTrailing) { grip(frame) }
            .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
            .opacity(opacity)
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

    private func bar(_ frame: CGRect) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).accessibilityHidden(true)
            Text("AI").font(.headline)
            Text(AiSettings.model(for: AiSettings.service)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary).accessibilityHidden(true)
            Slider(value: $opacity, in: 0.35...1).frame(width: 90).accessibilityLabel("Opacity")
            Button {
                model.ai.clear()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .labelStyle(.iconOnly)
            .disabled(model.ai.turns.isEmpty)
            Button {
                model.showsAI = false
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2).onChanged { drag in
            let start = moving ?? frame.origin
            moving = start
            placed = true
            x = start.x + drag.translation.width
            y = start.y + drag.translation.height
        }.onEnded { _ in moving = nil })
        .tint(.primary)
    }

    private func grip(_ frame: CGRect) -> some View {
        Image(systemName: "arrow.down.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                let start = sizing ?? frame.size
                sizing = start
                // Sized from where it is now (a window placed at first keeps its place).
                placed = true
                x = frame.minX
                y = frame.minY
                width = max(Self.smallest.width, start.width + drag.translation.width)
                height = max(Self.smallest.height, start.height + drag.translation.height)
            }.onEnded { _ in sizing = nil })
            .accessibilityLabel("Resize")
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
