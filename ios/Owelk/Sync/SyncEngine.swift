import Foundation

/// Runs sync passes off the main thread: reads what the computers wrote, writes what this iPad changed, and keeps the
/// merged rows between launches.
///
/// This app writes only `reading_positions` and `recent_documents`. A row it writes keeps every column it received
/// and changes only the ones it knows, so nothing a newer desktop added is lost.
actor SyncEngine {
    struct Outcome {
        var error: String?
        var received = 0
        var sent = 0
        var computers: [String] = []
        /// A new library, when anything in it changed.
        var library: Library?
    }

    let device: String
    private let storage: URL
    private let clock: () -> Int64
    private var state: SyncState
    private var library = Library.empty
    private var files: Set<String>?
    /// Changes made here and not yet in the folder, by table and key; kept on disk until written.
    private var pending: [String: Change] = [:]
    private var snapshotDue = false
    private var lastSnapshot = Date.distantPast

    /// `storage` is this library's folder in Application Support.
    init(storage: URL, device: String, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.storage = storage
        self.device = device
        self.clock = clock
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        state = (try? Data(contentsOf: storage.appendingPathComponent("state.json"))).flatMap(SyncState.init(snapshot:))
            ?? SyncState()
        if let data = try? Data(contentsOf: storage.appendingPathComponent("pending.jsonl")) {
            for line in data.split(separator: 0x0A) {
                if let change = Change(line: line) { pending[Self.slot(change)] = change }
            }
        }
    }

    /// The library as last merged, before the folder is read (a quick start).
    func cachedLibrary() -> Library {
        if files == nil { library = Library.build(state, files: []) }
        return library
    }

    /// One pass: read every computer's new changes, write this iPad's, list the PDFs that have arrived.
    func pass(_ folder: SyncFolder, library expected: String, about: [String: String]) -> Outcome {
        var outcome = Outcome()
        guard folder.library() == expected else {
            outcome.error = "The sync folder is not available. Check that Synctrain is running."
            return outcome
        }
        let read = folder.read(into: &state)
        outcome.received = read.applied
        if read.applied > 0 { snapshotDue = true }
        let waiting = pending.count
        outcome.error = flush(folder, library: expected, about: about)
        if outcome.error == nil { outcome.sent = waiting }
        let arrived = folder.paperFiles()
        if read.applied > 0 || arrived != files {
            files = arrived
            library = Library.build(state, files: arrived)
            outcome.library = library
        }
        outcome.computers = folder.computers(except: device)
        if snapshotDue && Date().timeIntervalSince(lastSnapshot) > 120 { saveSnapshot() }
        return outcome
    }

    /// Writes this iPad's waiting changes; returns an error to show, or nil.
    @discardableResult
    func flush(_ folder: SyncFolder, library expected: String, about: [String: String]) -> String? {
        guard !pending.isEmpty else { return nil }
        // Only into the library it came from, and only while its folder is there.
        guard folder.library() == expected else { return "The sync folder is not available. Check that Synctrain is running." }
        // Parents first, then oldest first, as the desktop sends them.
        let changes = pending.values.sorted {
            (SyncProtocol.order(of: $0.table), $0.version.time) < (SyncProtocol.order(of: $1.table), $1.version.time)
        }
        do {
            try folder.append(changes.reduce(into: Data()) { $0.append($1.line()) }, device: device, about: about)
        } catch {
            return "Cannot write to the sync folder."
        }
        pending.removeAll()
        savePending()
        return nil
    }

    func position(of paper: Paper) -> ReadingPosition? { library.position(of: paper, in: state) }

    func marks(of paper: Paper) -> [Mark] {
        guard !paper.sha256.isEmpty else { return [] }
        return state.entries("highlights").values.compactMap { entry in
            // Only marks made on this very PDF (the desktop hides the rest too).
            guard let row = entry.row, isNull(row["deleted_at"]), row.string("sha256") == paper.sha256 else { return nil }
            return Mark(row: row)
        }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// Notes where the paper was left; returns false when it was already there.
    @discardableResult
    func savePosition(_ position: ReadingPosition, of paper: Paper) -> Bool {
        let newest = library.newest("reading_positions", for: paper, in: state)
        var row = newest?.row ?? [:]
        var json = JSON.value(row.string("position")) as? Row ?? [:]
        if json["page"] != nil, json.int("page") == position.page, abs(json.double("y") - position.y) < 0.002 { return false }
        json["page"] = position.page
        json["y"] = (position.y * 10000).rounded() / 10000
        // The desktop's own view settings stay as they were: it comes back at its zoom, at this page.
        if json["x"] == nil { json["x"] = 0 }
        if json["zoom"] == nil { json["zoom"] = 1 }
        if json["fit"] == nil { json["fit"] = "width" }
        row["document_id"] = paper.documentId
        row["position"] = JSON.text(json)
        stage("reading_positions", key: [paper.documentId], row: row)
        return true
    }

    /// Notes that the paper was opened now; returns the library with it at the top of Recent.
    @discardableResult
    func saveOpened(_ paper: Paper, at date: Date = Date()) -> Library {
        var row = library.newest("recent_documents", for: paper, in: state)?.row ?? [:]
        row["document_id"] = paper.documentId
        row["opened_at"] = Self.timestamp(date)
        stage("recent_documents", key: [paper.documentId], row: row)
        return library
    }

    /// As Qt's `Qt::ISODateWithMs` writes UTC: 2026-11-05T03:04:05.123Z.
    static func timestamp(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.string(from: date)
    }

    private func stage(_ table: String, key: [Any], row: Row) {
        // Never older than what is here, even with this iPad's clock behind: else the change would lose everywhere.
        let previous = state.entry(table, key: key)?.version.time ?? 0
        let change = Change(table: table, key: key, version: Version(time: max(clock(), previous + 1), device: device), row: row)
        state.apply(change)
        pending[Self.slot(change)] = change
        savePending()
        snapshotDue = true
        library = Library.build(state, files: files ?? [])
    }

    func saveSnapshot() {
        guard snapshotDue, let data = state.snapshot() else { return }
        try? data.write(to: storage.appendingPathComponent("state.json"), options: .atomic)
        snapshotDue = false
        lastSnapshot = Date()
    }

    private func savePending() {
        let data = pending.values.reduce(into: Data()) { $0.append($1.line()) }
        try? data.write(to: storage.appendingPathComponent("pending.jsonl"), options: .atomic)
    }

    private static func slot(_ change: Change) -> String { change.table + "\u{1E}" + SyncState.keyText(change.key) }
}
