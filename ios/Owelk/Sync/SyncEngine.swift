import Foundation

/// Runs sync passes off the main thread: reads what the computers wrote, writes what this iPad changed, and keeps the
/// merged rows between launches.
///
/// This app writes where papers were left and when they were opened (`reading_positions`, `recent_documents`), and
/// papers added here (`documents` with the PDF in `Papers/`, and their place in a collection or tag). A row it writes
/// keeps every column it received and changes only the ones it knows, so nothing a newer desktop added is lost.
actor SyncEngine {
    enum Added {
        case added(Paper)
        /// The same PDF is in the Library already.
        case already(Paper)
        case failed(String)
    }

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
    private let newId: () -> String
    private var state: SyncState
    private var library = Library.empty
    private var files: Set<String>?
    /// Changes made here and not yet in the folder, by table and key; kept on disk until written.
    private var pending: [String: Change] = [:]
    private var snapshotDue = false
    private var lastSnapshot = Date.distantPast

    /// `storage` is this library's folder in Application Support.
    init(storage: URL, device: String, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         newId: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.storage = storage
        self.device = device
        self.clock = clock
        self.newId = newId
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

    /// The library as it is now, with this iPad's changes in it.
    func current() -> Library { library }

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

    /// Adds a PDF to the library: the file goes to `Papers/` and a row for it to the computers, which copy it into
    /// their own Library and read its details. A PDF the library has already (the same bytes) is not added again; one
    /// that was taken out of the Library or put in its Trash comes back, as it does when the desktop opens it again.
    /// The paper also goes into `collection` and `tag` (IDs) when they are given.
    func add(_ paper: NewPaper, to folder: SyncFolder, library expected: String, collection: String? = nil,
             tag: String? = nil) -> Added {
        guard folder.library() == expected else {
            return .failed("The sync folder is not available. Check that Synctrain is running.")
        }
        if let listed = library.papers.first(where: { $0.id == paper.sha256 }) {
            file(listed, collection: collection, tag: tag)
            return .already(listed)
        }
        do {
            try folder.savePaper(paper.data, sha256: paper.sha256)
        } catch {
            return .failed("Cannot write “\(paper.name)” to the sync folder.")
        }
        files = (files ?? folder.paperFiles()).union([paper.sha256])
        let known = state.entries("documents").values.compactMap(\.row)
            .filter { $0.string("kind") != "web" && $0.string("sha256") == paper.sha256 && !$0.string("id").isEmpty }
        if var row = known.min(by: { $0.string("id") < $1.string("id") }) {
            row["removed_at"] = NSNull()
            row["trashed_at"] = NSNull()
            stage("documents", key: [row.string("id")], row: row)
        } else {
            let id = newId()
            let row: Row = [
                "id": id, "kind": "pdf", "sha256": paper.sha256,
                // Only the name counts: each computer keeps the file where it keeps its papers.
                "url": URL(fileURLWithPath: "/" + paper.name).absoluteString,
                "added_at": Self.timestamp(Date(timeIntervalSince1970: TimeInterval(clock()) / 1000)),
                "title": paper.title, "authors": "", "year": "", "doi": "", "arxiv": "",
                "metadata_origin": "", "metadata_sha256": "", "reading_state": "unread", "favorite": 0,
                "duplicate_ack": "", "excluded_from_index": 0, "removed_at": NSNull(), "trashed_at": NSNull(),
            ]
            stage("documents", key: [id], row: row)
        }
        guard let added = library.papers.first(where: { $0.id == paper.sha256 }) else {
            return .failed("Cannot add “\(paper.name)”.")
        }
        file(added, collection: collection, tag: tag)
        return .added(library.papers.first { $0.id == paper.sha256 } ?? added)
    }

    /// Puts a paper into a collection and a tag it is not in yet.
    private func file(_ paper: Paper, collection: String?, tag: String?) {
        if let collection, !collection.isEmpty, !paper.collections.contains(collection) {
            stage("collection_documents", key: [collection, paper.documentId],
                  row: ["collection_id": collection, "document_id": paper.documentId])
        }
        if let tag, !tag.isEmpty, let name = library.tags.first(where: { $0.id == tag })?.name, !paper.tags.contains(name) {
            stage("document_tags", key: [paper.documentId, tag], row: ["document_id": paper.documentId, "tag_id": tag])
        }
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
