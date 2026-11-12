import Foundation

/// One request to the AI service, as the desktop sends it (src/ai/AiProviders.cpp).
struct AiRequest {
    var service: AiService
    var model: String
    var key: String
    var prompt: AiPrompt
    /// Earlier turns of the conversation, as plain text.
    var history: [(role: String, text: String)] = []
    /// Reading help is routine work: medium, or low for quick explanations.
    var effort = "medium"
    var maxTokens = 64000
}

/// What comes back: the answer's text as it is written, then how it ended.
enum AiEvent: Equatable {
    case text(String)
    case finished(model: String, cutOff: Bool)
}

struct AiError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

enum AiClient {
    /// The service's answer as it streams.
    static func stream(_ request: AiRequest, session: URLSession = .shared) -> AsyncThrowingStream<AiEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: try urlRequest(request))
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = Data()
                        for try await byte in bytes where body.count < 20000 { body.append(byte) }
                        throw AiError(message: errorMessage(request.service, status: status, body: body))
                    }
                    var reader = AiStreamReader(service: request.service, model: request.model)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        for event in try reader.read(json) {
                            continuation.yield(event)
                            if case .finished = event {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    throw AiError(message: "The answer stopped before it finished. Ask again.")
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch let error as AiError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: AiError(message: "Cannot reach \(request.service.name): \(error.localizedDescription)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func urlRequest(_ request: AiRequest) throws -> URLRequest {
        guard !request.key.isEmpty else {
            throw AiError(message: "Add your \(request.service.name) key in Settings (the gear in the library).")
        }
        let model = request.model
        var body: [String: Any]
        var url: URL
        var headers = ["Content-Type": "application/json"]
        switch request.service {
        case .claude:
            url = URL(string: "https://api.anthropic.com/v1/messages")!
            var content: [[String: Any]] = []
            // The paper first, with its own cache mark: later questions about it read it from the cache.
            if !request.prompt.context.isEmpty {
                content.append(["type": "text", "text": request.prompt.context, "cache_control": ["type": "ephemeral"]])
            }
            content.append(["type": "text", "text": request.prompt.text])
            let messages: [[String: Any]] = request.history.map { ["role": $0.role, "content": $0.text] }
                + [["role": "user", "content": content]]
            body = ["model": model, "max_tokens": request.maxTokens, "stream": true, "system": request.prompt.system,
                    "messages": messages, "cache_control": ["type": "ephemeral"]]
            // A safety decline is retried server-side on the model Anthropic recommends for that category.
            let fallbacks = model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-sonnet-5-5")
                || model.hasPrefix("claude-fable-5")
            if fallbacks { body["fallbacks"] = "default" }
            if model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-sonnet-5") || model.hasPrefix("claude-fable") {
                body["output_config"] = ["effort": request.effort]
            }
            headers["x-api-key"] = request.key
            headers["anthropic-version"] = "2026-10-21"
            if fallbacks { headers["anthropic-beta"] = "server-side-fallback-2026-07-01" }
        case .openai:
            url = URL(string: "https://api.openai.com/v1/responses")!
            let text = [request.prompt.context, request.prompt.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let input: [[String: Any]] = request.history.map { ["role": $0.role, "content": $0.text] }
                + [["role": "user", "content": [["type": "input_text", "text": text]]]]
            body = ["model": model, "instructions": request.prompt.system, "stream": true, "input": input,
                    "max_output_tokens": min(request.maxTokens, 32000)]
            if model.hasPrefix("gpt-5") || model.hasPrefix("o") { body["reasoning"] = ["effort": request.effort] }
            headers["Authorization"] = "Bearer " + request.key
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: 600)
        urlRequest.httpMethod = "POST"
        for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    static func errorMessage(_ service: AiService, status: Int, body: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let detail = (json?["error"] as? [String: Any])?["message"] as? String
        switch status {
        case 401: return "\(service.name) rejected the API key. Check it in Settings."
        case 429: return "\(service.name) rate limit reached. Try again shortly."
        case 529: return "\(service.name) is temporarily overloaded. Try again shortly."
        default: return "\(service.name): " + (detail ?? "The service reported an error (\(status)).")
        }
    }
}

/// Reads a service's stream of server-sent events (one JSON object per `data:` line): the text as it comes, and how
/// it ended. A declined answer is discarded, as on the desktop.
struct AiStreamReader {
    let service: AiService
    var model: String
    private var stopReason = ""
    private var written = false

    init(service: AiService, model: String) {
        self.service = service
        self.model = model
    }

    mutating func read(_ json: [String: Any]) throws -> [AiEvent] {
        let type = json["type"] as? String ?? ""
        switch service {
        case .claude:
            switch type {
            case "message_start":
                model = (json["message"] as? [String: Any])?["model"] as? String ?? model
            case "content_block_delta":
                let delta = json["delta"] as? [String: Any] ?? [:]
                if delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                    written = true
                    return [.text(text)]
                }
            case "message_delta":
                if let reason = (json["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = reason }
            case "message_stop":
                if stopReason == "refusal" {
                    throw AiError(message: "Claude declined this request. Rephrase it or try another model.")
                }
                return [.finished(model: model, cutOff: stopReason == "max_tokens")]
            case "error":
                let message = (json["error"] as? [String: Any])?["message"] as? String
                throw AiError(message: "Claude: " + (message ?? "The service reported an error."))
            default:
                break
            }
        case .openai:
            switch type {
            case "response.output_text.delta":
                if let text = json["delta"] as? String {
                    written = true
                    return [.text(text)]
                }
            case "response.completed":
                model = (json["response"] as? [String: Any])?["model"] as? String ?? model
                return [.finished(model: model, cutOff: false)]
            case "response.incomplete" where written:
                return [.finished(model: model, cutOff: true)]
            case "response.failed", "response.incomplete":
                let error = (json["response"] as? [String: Any])?["error"] as? [String: Any]
                throw AiError(message: "OpenAI: " + (error?["message"] as? String ?? "The answer could not be finished."))
            case "error":
                throw AiError(message: "OpenAI: " + (json["message"] as? String ?? "The service reported an error."))
            default:
                break
            }
        }
        return []
    }
}
