import Foundation
import PDFKit

/// What is asked of the AI about a paper, built as the desktop builds it (`buildAiPrompt` in src/ai/AiContext.cpp):
/// the system prompt with the answer's language and the reader's level, the paper's text (cached by the service, so
/// later questions about the paper cost less), and the request itself.
struct AiPrompt {
    enum Action {
        /// A question about the paper (or the selection with it).
        case ask(String)
        /// Help understanding the selected passage.
        case explain
        /// Key idea, method and limits, in three lines.
        case summary
    }

    var system: String
    /// The paper (title and text with page markers): the same for every question about it.
    var context: String
    var text: String

    /// The desktop's budget for the paper's text, in characters.
    static let budget = 60000

    static func build(_ action: Action, title: String, paperText: String, selection: String = "",
                      pageText: String = "", pageNumber: Int = 0, language: String = AiSettings.language,
                      level: String = AiSettings.level) -> AiPrompt {
        let target = languageName(language)
        var system = "You are a research reading assistant inside Owelk, a paper reader. Help the reader understand "
            + "the paper from the material provided. Ground answers in that material; when it does not contain the "
            + "answer, say so and separate general knowledge from what the paper states. Keep technical terms, symbols "
            + "and citations exact. Use concise Markdown. Write math as LaTeX: $...$ inline and $$...$$ on its own line "
            + "for display."
        if case let .ask(question) = action, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            system += " Answer in the language of the reader's request."
        } else if target.isEmpty {
            system += " Answer in the language of the paper."
        } else {
            system += " Answer in \(target); keep technical terms in their original form where that is clearer."
        }
        if level == "brief" {
            system += " Be brief, for a reader who knows the basics of the field: the key point first, then only what "
                + "is needed to follow it; define unfamiliar symbols in a few words and skip examples unless asked."
        } else {
            system += " Write for a student new to this field (an undergraduate or first-year graduate student): plain "
                + "words and short sentences; define each symbol and technical term the first time it appears; give the "
                + "intuition before the formal statement; and add a small concrete example, with simple numbers or an "
                + "everyday analogy, where it helps. Do not assume background the paper does not explain; when you add "
                + "it, say that it is background knowledge."
        }
        if !paperText.isEmpty || !pageText.isEmpty {
            system += " When a statement draws on the paper, cite its place right after it as [p. N: \"exact words\"], "
                + "where N is the page number marked in the material and the words are a short phrase (about 4 to 12 "
                + "words) copied exactly from that page."
        }

        var cut = false
        var context: [String] = []
        if !title.isEmpty { context.append("<paper>\nTitle: \(title)\n</paper>") }
        if !paperText.isEmpty { context.append("<paper_text>\n\(clip(paperText, budget, &cut))\n</paper_text>") }
        var parts: [String] = []
        if !selection.isEmpty { parts.append("<selection>\n\(clip(selection, 20000, &cut))\n</selection>") }
        if !pageText.isEmpty, paperText.isEmpty {
            parts.append("<page number=\"\(pageNumber)\">\n\(clip(pageText, 20000, &cut))\n</page>")
        }
        var task: String
        switch action {
        case let .ask(question):
            let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
            task = question.isEmpty ? "Help me understand this material." : question
        case .explain:
            task = "Help me understand the selected passage: what it says, what each symbol and term in it means, and "
                + "why it matters in this paper."
        case .summary:
            task = "Summarize the paper for the reader's notes in exactly three Markdown list items, keeping these "
                + "English labels:\n- Key idea: …\n- Method: …\n- Limits: …\nOne sentence each, in "
                + "\(target.isEmpty ? "the paper's language" : target); keep technical terms as the paper writes them. "
                + "No other text."
        }
        if cut { task += "\n\n(Some material was shortened to fit; mention it if the answer depends on the missing part.)" }
        parts.append(task)
        return AiPrompt(system: system, context: context.joined(separator: "\n\n"), text: parts.joined(separator: "\n\n"))
    }

    /// The reader's preferred language by name ("" for the paper's own), as the desktop's `aiLanguageName`.
    static func languageName(_ language: String) -> String {
        let names = ["ko": "Korean", "en": "English", "ja": "Japanese", "zh": "Simplified Chinese", "de": "German",
                     "fr": "French", "es": "Spanish"]
        return language == "source" ? "" : names[language] ?? "Korean"
    }

    private static func clip(_ text: String, _ budget: Int, _ cut: inout Bool) -> String {
        guard text.count > budget else { return text }
        cut = true
        return String(text.prefix(budget)) + "\n[…truncated]"
    }

    /// A paper's text page by page, each marked "[Page N]" as the desktop marks it, so answers can cite places.
    static func paperText(of document: PDFDocument) -> String {
        (0..<document.pageCount).compactMap { index -> String? in
            guard let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return "[Page \(index + 1)] " + text
        }.joined(separator: "\n")
    }

    /// An answer's citations of the paper, [p. 3: "exact words"], [p. 3] or [pp. 3-4], as links to their page.
    static func linkingPages(_ answer: String) -> String {
        // Not one the desktop has linked already ([p. 3](owelk://document/…)).
        let pattern = #"\[(pp?)\. (\d+)(?:[-–]\d+)?(?::\s*"[^"\]]*")?\](?!\()"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return answer }
        var result = answer
        for match in expression.matches(in: answer, range: NSRange(answer.startIndex..., in: answer)).reversed() {
            guard let whole = Range(match.range, in: result), let number = Range(match.range(at: 2), in: result) else {
                continue
            }
            let page = String(result[number])
            let label = String(result[whole]).dropFirst().dropLast().replacingOccurrences(of: "[", with: "(")
                .replacingOccurrences(of: "]", with: ")")
            result.replaceSubrange(whole, with: "[\(label)](owelk-page:\(page))")
        }
        return result
    }
}
