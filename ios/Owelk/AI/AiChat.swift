import Foundation
import PDFKit

/// A conversation with the AI about the paper open in the reader, kept in the library as the desktop keeps its chats
/// (`ai_threads`, `ai_messages`), so it goes on on any computer. Opening the paper goes on with its latest one.
@MainActor
final class AiChat: ObservableObject {
    struct Turn: Identifiable {
        let id = UUID()
        /// What was asked, as the reader sees it.
        let asked: String
        /// The request as it was sent (what follow-up questions carry).
        var sent = ""
        var answer = ""
        var running = true
        var error: String?
        var cutOff = false
        var model = ""
    }

    @Published private(set) var turns: [Turn] = []
    @Published var draft = ""
    /// Selected text the next question is about.
    @Published var attached: String?
    @Published private(set) var running = false
    /// The conversation shown (nil: a new one, made with its first answer).
    @Published private(set) var thread: String?
    /// The conversation shown is about something else (another paper, a collection, nothing in particular): what it
    /// is about ("" when nothing). It is read here until the reader goes on with it (`goOn`) or forks it (`fork`); a
    /// question asked before that (Explain, Summarize) starts a new conversation about this paper.
    @Published private(set) var elsewhere: String?
    private var task: Task<Void, Never>?
    private var paperText: String?
    private let paper: Paper
    private let document: () -> PDFDocument?
    private weak var store: LibraryStore?

    init(paper: Paper, document: @escaping () -> PDFDocument?) {
        self.paper = paper
        self.document = document
    }

    var hasKey: Bool { !AiSettings.key(for: AiSettings.service).isEmpty }

    /// The library the conversation is kept in; the conversation chosen in the library is shown, or else the paper's
    /// latest one.
    func keep(in store: LibraryStore, showing chosen: String? = nil) async {
        self.store = store
        guard turns.isEmpty,
              let id = chosen ?? store.library.threads.first(where: { $0.paper == paper.id })?.id else { return }
        await open(id)
    }

    /// Shows a conversation (from any computer), to go on with it.
    func open(_ id: String) async {
        guard !running, let store else { return }
        let turns = Self.turns(of: await store.messages(of: id))
        thread = id
        let chat = store.library.threads.first { $0.id == id }
        elsewhere = chat.flatMap { $0.paper == paper.id ? nil : store.library.place(of: $0) }
        self.turns = turns
    }

    /// A conversation's turns: each question with the answer after it.
    nonisolated static func turns(of messages: [AiMessage]) -> [Turn] {
        var turns: [Turn] = []
        for message in messages {
            if message.role == "user" {
                turns.append(Turn(asked: message.display.isEmpty ? message.content : message.display,
                                  sent: message.content, running: false))
            } else if message.role == "assistant", !turns.isEmpty {
                turns[turns.count - 1].answer = message.content
                turns[turns.count - 1].model = message.model
            }
        }
        return turns
    }

    /// Goes on with the conversation about something else, as it is: questions are kept in it, with this paper's
    /// text sent along.
    func goOn() { elsewhere = nil }

    /// Goes on with a copy of the conversation about something else, kept with this paper ("Branch · …").
    func fork() async {
        guard !running, let store, let thread, let copy = await store.forkThread(thread, about: paper) else { return }
        await open(copy)
        elsewhere = nil
    }

    /// The question typed (about the attached selection, if any).
    func ask() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let selection = attached ?? ""
        draft = ""
        attached = nil
        run(.ask(question), label: selection.isEmpty ? question : "“\(Self.short(selection))” — \(question)",
            selection: selection)
    }

    func explain(_ selection: String) {
        run(.explain, label: "Explain “\(Self.short(selection))”", selection: selection, effort: "low")
    }

    func summarize() { run(.summary, label: "Summarize this paper") }

    func stop() { task?.cancel() }

    /// A new conversation (the one shown stays in the library).
    func clear() {
        task?.cancel()
        turns = []
        thread = nil
        elsewhere = nil
    }

    private func run(_ action: AiPrompt.Action, label: String, selection: String = "", effort: String = "medium") {
        guard !running else { return }
        // A question about this paper isn't added to a conversation about something else.
        if elsewhere != nil {
            turns = []
            thread = nil
            elsewhere = nil
        }
        let service = AiSettings.service
        let earlier = turns.filter { !$0.running && $0.error == nil && !$0.answer.isEmpty }.suffix(6)
        let history = earlier.flatMap { [("user", $0.sent.isEmpty ? $0.asked : $0.sent), ("assistant", $0.answer)] }
        let turn = Turn(asked: label)
        turns.append(turn)
        running = true
        let paper = paper, document = document()
        let known = paperText
        task = Task { [weak self] in
            // The paper's text, once per paper, read off the main thread.
            let text: String
            if let known {
                text = known
            } else if let document {
                let shared = SharedDocument(document)
                text = await Task.detached(priority: .userInitiated) { AiPrompt.paperText(of: shared.document) }.value
            } else {
                text = ""
            }
            self?.paperText = text
            let prompt = AiPrompt.build(action, title: paper.title, paperText: text, selection: selection)
            self?.update(turn.id) { $0.sent = prompt.text }
            let request = AiRequest(service: service, model: AiSettings.model(for: service),
                                    key: AiSettings.key(for: service), prompt: prompt, history: history,
                                    effort: effort, maxTokens: effort == "low" ? 4000 : 64000)
            var finished = false
            do {
                for try await event in AiClient.stream(request) {
                    switch event {
                    case let .text(part): self?.update(turn.id) { $0.answer += part }
                    case let .finished(model, cutOff):
                        finished = true
                        self?.update(turn.id) { $0.model = model; $0.cutOff = cutOff }
                    }
                }
            } catch {
                self?.update(turn.id) { $0.error = error.localizedDescription }
            }
            self?.update(turn.id) { $0.running = false }
            self?.running = false
            // A finished answer is kept with its question, as the desktop keeps them.
            if finished, let self, let done = self.turns.first(where: { $0.id == turn.id }), !done.answer.isEmpty,
               let store = self.store {
                self.thread = await store.saveTurn(in: self.thread, about: paper, title: label, sent: done.sent,
                                                   display: label, answer: done.answer, selection: selection,
                                                   cutOff: done.cutOff, provider: service.rawValue,
                                                   model: done.model.isEmpty ? request.model : done.model)
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Turn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[index])
    }

    private static func short(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
    }
}

/// A PDF read off the main thread (PDFKit reads pages' text from any thread).
private struct SharedDocument: @unchecked Sendable {
    let document: PDFDocument
    init(_ document: PDFDocument) { self.document = document }
}
