import Foundation

/// Every row this app knows, each with the version that put it there, and how far each change file has been read.
///
/// The iPad keeps no database of its own: it is the merge of every computer's change files, its own included, so it
/// remembers what it wrote after a restart. A snapshot of it is kept between launches; when `schema` changes (a table
/// or column this app reads is added) the snapshot is dropped and every log is read again, as the desktop does after
/// an update.
struct SyncState {
    /// 2: notes and links are read too. 3: and AI chats.
    static let schema = 3

    struct Entry {
        var version: Version
        /// nil once the row was removed.
        var row: Row?
    }

    private(set) var rows: [String: [String: Entry]] = [:]
    /// "<device>/<file>" → bytes applied (up to the end of the last whole line).
    var read: [String: Int] = [:]

    init() {}

    static func keyText(_ values: [Any]) -> String {
        values.map { value -> String in
            switch value {
            case let text as String: text
            case let number as NSNumber: number.stringValue
            default: ""
            }
        }.joined(separator: "\u{1F}")
    }

    /// Applies a change the way the desktop does; returns whether it replaced what was here.
    @discardableResult
    mutating func apply(_ change: Change) -> Bool {
        guard let keys = SyncProtocol.keys(of: change.table), change.key.count == keys.count else { return false }
        // A row's key comes from the row itself; a removal's from "k".
        let values: [Any] = change.row.map { row in keys.map { row[$0] ?? NSNull() } } ?? change.key
        let key = Self.keyText(values)
        if let local = rows[change.table]?[key], !change.version.replaces(local.version) { return false }
        rows[change.table, default: [:]][key] = Entry(version: change.version, row: change.row)
        return true
    }

    func entry(_ table: String, key: [Any]) -> Entry? { rows[table]?[Self.keyText(key)] }
    func entries(_ table: String) -> [String: Entry] { rows[table] ?? [:] }

    // MARK: Snapshot

    func snapshot() -> Data? {
        var tables: [String: Any] = [:]
        for (table, entries) in rows {
            tables[table] = entries.map { key, entry -> [Any] in
                [key, NSNumber(value: entry.version.time), entry.version.device, entry.row ?? NSNull()]
            }
        }
        return try? JSONSerialization.data(withJSONObject: ["schema": Self.schema, "read": read, "rows": tables])
    }

    /// nil when the data is damaged or from another schema (everything is then read again).
    init?(snapshot data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["schema"] as? NSNumber)?.intValue == Self.schema,
              let read = object["read"] as? [String: NSNumber], let tables = object["rows"] as? [String: [[Any]]]
        else { return nil }
        self.read = read.mapValues(\.intValue)
        for (table, list) in tables {
            var entries: [String: Entry] = [:]
            entries.reserveCapacity(list.count)
            for item in list where item.count == 4 {
                guard let key = item[0] as? String, let time = item[1] as? NSNumber, let device = item[2] as? String
                else { continue }
                entries[key] = Entry(version: Version(time: time.int64Value, device: device), row: item[3] as? Row)
            }
            rows[table] = entries
        }
    }
}
