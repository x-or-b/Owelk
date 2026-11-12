import PDFKit
import XCTest
@testable import Owelk

/// What the iPad asks the AI and how it reads the answer (no request is sent).
final class AiTests: XCTestCase {
    func testThePromptIsTheDesktops() throws {
        let document = try XCTUnwrap(PDFDocument(url: ConformanceTests.addedPdf))
        let text = AiPrompt.paperText(of: document)
        XCTAssertTrue(text.hasPrefix("[Page 1] "))
        let summary = AiPrompt.build(.summary, title: "Echoes", paperText: text, language: "ko", level: "easy")
        XCTAssertTrue(summary.system.contains("Answer in Korean"))
        XCTAssertTrue(summary.system.contains("a student new to this field"))
        XCTAssertTrue(summary.system.contains("[p. N: \"exact words\"]"))
        XCTAssertTrue(summary.context.contains("Title: Echoes"))
        XCTAssertTrue(summary.context.contains("<paper_text>\n[Page 1]"))
        XCTAssertTrue(summary.text.contains("- Key idea: …"))

        let asked = AiPrompt.build(.ask("왜 이 방법인가요?"), title: "", paperText: text, selection: "the walls",
                                   language: "en", level: "brief")
        XCTAssertTrue(asked.system.contains("Answer in the language of the reader's request."))
        XCTAssertTrue(asked.system.contains("Be brief"))
        XCTAssertTrue(asked.text.hasPrefix("<selection>\nthe walls\n</selection>"))
        XCTAssertTrue(asked.text.hasSuffix("왜 이 방법인가요?"))

        let long = AiPrompt.build(.explain, title: "", paperText: String(repeating: "a", count: 70000))
        XCTAssertTrue(long.context.contains("[…truncated]"))
        XCTAssertTrue(long.text.contains("Some material was shortened"))
    }

    func testPageCitationsOpenTheirPage() {
        XCTAssertEqual(AiPrompt.linkingPages(#"It holds [p. 3: "the walls echo"]."#),
                       #"It holds [p. 3: "the walls echo"](owelk-page:3)."#)
        XCTAssertEqual(AiPrompt.linkingPages("See [pp. 4-5] and [p. 7]."),
                       "See [pp. 4-5](owelk-page:4) and [p. 7](owelk-page:7).")
        XCTAssertEqual(AiPrompt.linkingPages("[1] stays"), "[1] stays")
    }

    func testRequestsAreTheDesktops() throws {
        let prompt = AiPrompt(system: "S", context: "PAPER", text: "Q")
        let claude = try AiClient.urlRequest(AiRequest(service: .claude, model: "claude-opus-5-5", key: "k", prompt: prompt,
                                                       history: [("user", "a"), ("assistant", "b")]))
        XCTAssertEqual(claude.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(claude.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(claude.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(claude.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(claude.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["system"] as? String, "S")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertNil(body["thinking"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)
        let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "PAPER")
        XCTAssertNotNil(content.first?["cache_control"], "the paper is cached")
        XCTAssertEqual(content.last?["text"] as? String, "Q")

        let haiku = try AiClient.urlRequest(AiRequest(service: .claude, model: "claude-haiku-5-5", key: "k", prompt: prompt))
        let small = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(haiku.httpBody)) as? [String: Any])
        XCTAssertNil(small["fallbacks"])
        XCTAssertNil(haiku.value(forHTTPHeaderField: "anthropic-beta"))

        let openai = try AiClient.urlRequest(AiRequest(service: .openai, model: "gpt-5", key: "k", prompt: prompt))
        XCTAssertEqual(openai.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(openai.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(openai.httpBody)) as? [String: Any])
        XCTAssertEqual(request["instructions"] as? String, "S")
        XCTAssertEqual((request["reasoning"] as? [String: Any])?["effort"] as? String, "medium")

        XCTAssertThrowsError(try AiClient.urlRequest(AiRequest(service: .claude, model: "m", key: "", prompt: prompt))) {
            XCTAssertTrue(($0 as? AiError)?.message.contains("Settings") ?? false)
        }
    }

    func testStreamsAreRead() throws {
        var claude = AiStreamReader(service: .claude, model: "claude-opus-5-5")
        XCTAssertEqual(try claude.read(["type": "message_start", "message": ["model": "claude-opus-5-5"]]), [])
        XCTAssertEqual(try claude.read(["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Hi"]]),
                       [.text("Hi")])
        XCTAssertEqual(try claude.read(["type": "content_block_delta", "delta": ["type": "thinking_delta", "thinking": "…"]]), [])
        XCTAssertEqual(try claude.read(["type": "message_delta", "delta": ["stop_reason": "max_tokens"]]), [])
        XCTAssertEqual(try claude.read(["type": "message_stop"]), [.finished(model: "claude-opus-5-5", cutOff: true)])

        var declined = AiStreamReader(service: .claude, model: "m")
        _ = try declined.read(["type": "message_delta", "delta": ["stop_reason": "refusal"]])
        XCTAssertThrowsError(try declined.read(["type": "message_stop"]))

        var openai = AiStreamReader(service: .openai, model: "gpt-5")
        XCTAssertEqual(try openai.read(["type": "response.output_text.delta", "delta": "Yo"]), [.text("Yo")])
        XCTAssertEqual(try openai.read(["type": "response.completed", "response": ["model": "gpt-5-2025"]]),
                       [.finished(model: "gpt-5-2025", cutOff: false)])
        var failed = AiStreamReader(service: .openai, model: "gpt-5")
        XCTAssertThrowsError(try failed.read(["type": "response.failed", "response": ["error": ["message": "bad"]]]))
    }

    func testAnswersAreDrawnLineByLine() {
        XCTAssertEqual(AnswerText.lines("A\n\n\n- b\n\nc"), ["A", "", "- b", "", "c"])
        let linked = AnswerText.inline(#"See [p. 2: "x y"]"#)
        XCTAssertTrue(linked.runs.contains { $0.link?.absoluteString == "owelk-page:2" })
    }

    /// The AI's window: at first at the top right, then where it was left, always inside the reader and no smaller than
    /// it can be used.
    func testTheWindowStaysInside() {
        let area = CGSize(width: 1366, height: 938)
        let first = FloatingAiPanel.frame(in: area, at: nil, width: 400, height: 560)
        XCTAssertEqual(first, CGRect(x: 950, y: 16, width: 400, height: 560))
        let moved = FloatingAiPanel.frame(in: area, at: CGPoint(x: 2000, y: -300), width: 400, height: 560)
        XCTAssertEqual(moved.maxX, area.width - 8)
        XCTAssertEqual(moved.minY, 8)
        let tiny = FloatingAiPanel.frame(in: area, at: CGPoint(x: 100, y: 100), width: 10, height: 10)
        XCTAssertEqual(tiny.size, FloatingAiPanel.smallest)
        let huge = FloatingAiPanel.frame(in: area, at: .zero, width: 5000, height: 5000)
        XCTAssertEqual(huge.size, CGSize(width: area.width - 16, height: area.height - 16))
    }
}
