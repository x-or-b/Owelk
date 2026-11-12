import Foundation

/// The wire format of Owelk's folder sync, as written by `LibrarySync` in the desktop app (src/LibrarySync.cpp,
/// docs/SYNC.md). Each computer appends change lines to its own `devices/<id>/%08d.jsonl`; per row, the newest change
/// wins. A line is `{"d":device,"k":[key values],"r":row or null,"t":table,"v":milliseconds since 1970}`.
enum SyncProtocol {
    static let marker = "owelk-sync.json"
    /// A change file grows to about this size before the next one starts.
    static let segmentLimit = 256 * 1024
    /// The tables this app keeps, with their primary keys (as in the desktop's `tables()`), parents first. Adding a
    /// table here must bump `SyncState.schema`, so every log is read again for it.
    static let tables: [(name: String, keys: [String])] = [
        ("documents", ["id"]), ("tags", ["id"]), ("collections", ["id"]), ("notes", ["id"]), ("highlights", ["id"]),
        ("recent_documents", ["document_id"]), ("reading_positions", ["document_id"]),
        ("collection_documents", ["collection_id", "document_id"]), ("document_tags", ["document_id", "tag_id"]),
        ("links", ["from_kind", "from_id", "to_kind", "to_id"]),
        ("ai_folders", ["id"]), ("ai_threads", ["id"]), ("ai_messages", ["id"]),
    ]
    static func keys(of table: String) -> [String]? { tables.first { $0.name == table }?.keys }
    static func order(of table: String) -> Int { tables.firstIndex { $0.name == table } ?? tables.count }
    static func segmentName(_ sequence: Int) -> String { String(format: "%08d.jsonl", sequence) }
    static func isSha256(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    /// A file name from the folder that may become a path here: no folders, no "../".
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !name.contains(":")
    }
}

typealias Row = [String: Any]

func isNull(_ value: Any?) -> Bool { value == nil || value is NSNull }

/// When a change was made and by which computer. Of two versions of a row the later time wins, and at the same time
/// the larger device ID (the desktop's `applyChange`); the same version again is applied again.
struct Version: Equatable {
    var time: Int64
    var device: String

    func replaces(_ other: Version) -> Bool { time > other.time || (time == other.time && device >= other.device) }
}

/// One change line.
struct Change {
    var table: String
    var key: [Any]
    var version: Version
    /// The whole row, or nil for a removal.
    var row: Row?

    init(table: String, key: [Any], version: Version, row: Row?) {
        self.table = table
        self.key = key
        self.version = version
        self.row = row
    }

    /// A line as the desktop writes it; nil for a damaged line (skipped, as the desktop does).
    init?(line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], !object.isEmpty,
              let table = object["t"] as? String, let key = object["k"] as? [Any]
        else { return nil }
        self.table = table
        self.key = key
        version = Version(time: (object["v"] as? NSNumber)?.int64Value ?? 0, device: object["d"] as? String ?? "")
        row = object["r"] as? Row
    }

    /// The line to append: compact JSON with sorted keys (as Qt writes it), ending in a newline.
    func line() -> Data {
        let object: [String: Any] = ["t": table, "k": key, "v": NSNumber(value: version.time), "d": version.device,
                                     "r": row ?? NSNull()]
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
        data.append(0x0A)
        return data
    }
}

enum JSON {
    /// Compact text with sorted keys, as `QJsonDocument::toJson(Compact)` writes an object.
    static func text(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func value(_ text: String?) -> Any? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

extension Row {
    func string(_ key: String) -> String {
        switch self[key] {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: ""
        }
    }

    func double(_ key: String) -> Double { (self[key] as? NSNumber)?.doubleValue ?? Double(string(key)) ?? 0 }
    func int(_ key: String) -> Int { (self[key] as? NSNumber)?.intValue ?? Int(string(key)) ?? 0 }
}
