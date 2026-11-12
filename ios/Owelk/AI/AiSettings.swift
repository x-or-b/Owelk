import Foundation
import Security

/// The AI service the reader asks, as on the desktop (Settings › AI): Claude API or OpenAI API, each with the
/// reader's own API key (kept in this iPad's Keychain, never in the sync folder).
enum AiService: String, CaseIterable, Identifiable {
    case claude, openai

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude API"
        case .openai: "OpenAI API"
        }
    }

    /// The models offered (the desktop's list for Claude; OpenAI takes any model name), the default first.
    var models: [(id: String, name: String)] {
        switch self {
        case .claude:
            [("claude-opus-5-5", "Claude Opus 5.5"), ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
             ("claude-haiku-5-5", "Claude Haiku 5.5"), ("claude-fable-5-1", "Claude Fable 5.1")]
        case .openai:
            [("gpt-5", "GPT-5")]
        }
    }
}

/// What the reader chose for AI answers: the service, its model, the answer's language and the reader's level.
enum AiSettings {
    private static let defaults = UserDefaults.standard

    static var service: AiService {
        get { AiService(rawValue: defaults.string(forKey: "ai.service") ?? "") ?? .claude }
        set { defaults.set(newValue.rawValue, forKey: "ai.service") }
    }

    static func model(for service: AiService) -> String {
        let saved = (defaults.string(forKey: "ai.model." + service.rawValue) ?? "").trimmingCharacters(in: .whitespaces)
        return saved.isEmpty ? service.models[0].id : saved
    }

    static func setModel(_ model: String, for service: AiService) {
        defaults.set(String(model.trimmingCharacters(in: .whitespaces).prefix(120)), forKey: "ai.model." + service.rawValue)
    }

    /// The answer's language for one-click actions, as the desktop's `aiLanguage` ("source": the paper's own).
    static var language: String {
        get { defaults.string(forKey: "ai.language") ?? "ko" }
        set { defaults.set(newValue, forKey: "ai.language") }
    }

    static let languages: [(id: String, name: String)] = [
        ("ko", "Korean"), ("en", "English"), ("ja", "Japanese"), ("zh", "Simplified Chinese"), ("source", "Paper's Language"),
    ]

    /// "easy" (a student new to the field) or "brief" (a reader who knows the basics), as the desktop's.
    static var level: String {
        get { defaults.string(forKey: "ai.level") == "brief" ? "brief" : "easy" }
        set { defaults.set(newValue == "brief" ? "brief" : "easy", forKey: "ai.level") }
    }

    static func key(for service: AiService) -> String { Keychain.read(service.rawValue) ?? "" }

    static func setKey(_ key: String, for service: AiService) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { Keychain.delete(service.rawValue) } else { Keychain.save(key, for: service.rawValue) }
    }
}

/// API keys in this iPad's Keychain (this device only, readable once it has been unlocked).
enum Keychain {
    private static let serviceName = "org.owelk.pad.ai"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: serviceName,
         kSecAttrAccount as String: account]
    }

    static func save(_ value: String, for account: String) {
        let data = Data(value.utf8)
        let found = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard found == errSecItemNotFound else { return }
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read(_ account: String) -> String? {
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
