import Foundation

/// Runs sync passes off the main thread: reads what the computers wrote, writes what this iPad changed, and keeps the
/// merged rows between launches.
///
/// This app writes where papers were left and when they were opened (`reading_positions`, `recent_documents`),
/// papers added here (`documents` with the PDF in `Papers/`, and their place in a collection or tag), and Apple
/// Pencil's pen strokes and erasures (`highlights`). A row it writes keeps every column it received and changes only
/// the ones it knows, so nothing a newer desktop added is lost.
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
        // Parents first, then oldest first, as the desktop sends them (and by key, so a file is the same each time).
        let changes = pending.values.sorted {
            (SyncProtocol.order(of: $0.table), $0.version.time, SyncState.keyText($0.key))
                < (SyncProtocol.order(of: $1.table), $1.version.time, SyncState.keyText($1.key))
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

    /// Notes that the paper was opened now (the computers' Recent); returns the library with it opened last.
    @discardableResult
    func saveOpened(_ paper: Paper, at date: Date = Date()) -> Library {
        var row = library.newest("recent_documents", for: paper, in: state)?.row ?? [:]
        row["document_id"] = paper.documentId
        row["opened_at"] = Self.timestamp(date)
        stage("recent_documents", key: [paper.documentId], row: row)
        // An unread paper opened is being read, as the desktop's `startReading` has it.
        if paper.readingState == "unread" { setReadingState("reading", of: paper) }
        return library
    }

    // MARK: Pen

    /// A pen stroke drawn here, saved as the desktop saves one (a `draw` mark); `points` are shown-page fractions.
    /// Returns false for a paper without a known PDF or a stroke with too few points.
    @discardableResult
    func addStroke(id: String, to paper: Paper, page: Int, points: [CGPoint], color: String) -> Bool {
        let created = Self.timestamp(Date(timeIntervalSince1970: TimeInterval(clock()) / 1000))
        guard SyncProtocol.isSha256(paper.sha256), page >= 0,
              let row = Self.strokeRow(id: id, document: paper.documentId, sha256: paper.sha256, page: page,
                                       points: points, color: color, createdAt: created)
        else { return false }
        stage("highlights", key: [id], row: row)
        return true
    }

    /// Erases marks, or brings erased ones back (Undo): only `deleted_at` changes, as the desktop's eraser does.
    func setErased(_ ids: [String], _ erased: Bool) {
        let now = Self.timestamp(Date(timeIntervalSince1970: TimeInterval(clock()) / 1000))
        for id in ids {
            guard var row = state.entry("highlights", key: [id])?.row, erased == isNull(row["deleted_at"]) else { continue }
            row["deleted_at"] = erased ? now : NSNull()
            stage("highlights", key: [id], row: row)
        }
    }

    // MARK: Library edits

    /// A paper's rows in the Library (one per copy of its PDF that the computers merged): its details are changed in
    /// each, so the newest says the same whichever it is.
    private func rows(of paper: Paper) -> [Row] {
        state.entries("documents").values.compactMap(\.row).filter {
            library.paperOf[$0.string("id")] == paper.id && isNull($0["removed_at"]) && isNull($0["trashed_at"])
        }
    }

    /// Unread, reading or read, as the desktop's `reading_state`.
    func setReadingState(_ value: String, of paper: Paper) {
        guard ["unread", "reading", "read"].contains(value) else { return }
        for var row in rows(of: paper) where row.string("reading_state") != value {
            row["reading_state"] = value
            stage("documents", key: [row.string("id")], row: row)
        }
    }

    func setFavorite(_ on: Bool, of paper: Paper) {
        for var row in rows(of: paper) where (row.int("favorite") != 0) != on {
            row["favorite"] = on ? 1 : 0
            stage("documents", key: [row.string("id")], row: row)
        }
    }

    /// Puts the paper in a tag or takes it out (under every ID the paper has).
    func setTag(_ tag: String, _ on: Bool, of paper: Paper) {
        member("document_tags", ["document_id", "tag_id"], other: tag, on, of: paper)
    }

    /// Puts the paper in a collection or takes it out.
    func setCollection(_ collection: String, _ on: Bool, of paper: Paper) {
        member("collection_documents", ["collection_id", "document_id"], other: collection, on, of: paper)
    }

    private func member(_ table: String, _ columns: [String], other: String, _ on: Bool, of paper: Paper) {
        let otherColumn = columns.first { $0 != "document_id" }!
        let present = state.entries(table).values.compactMap(\.row).filter {
            $0.string(otherColumn) == other && library.paperOf[$0.string("document_id")] == paper.id
        }
        if on, present.isEmpty {
            let row: Row = ["document_id": paper.documentId, otherColumn: other]
            stage(table, key: columns.map { row[$0]! }, row: row)
        } else if !on {
            for row in present { stage(table, key: columns.map { row[$0]! }, row: nil) }
        }
    }

    /// A tag by its name: the one there is (letter case aside), or a new one. Returns its ID.
    func tag(named name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { return nil }
        if let known = library.tags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return known.id
        }
        let id = newId()
        stage("tags", key: [id], row: ["id": id, "name": name])
        return id
    }

    /// A new collection at the top, as the desktop's `createCollection` saves one. Returns its ID.
    func collection(named name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { return nil }
        let id = newId()
        stage("collections", key: [id], row: [
            "id": id, "name": name, "parent_id": NSNull(),
            "created_at": Self.timestamp(Date(timeIntervalSince1970: TimeInterval(clock()) / 1000)),
        ])
        return id
    }

    // MARK: Notes

    /// A new note, as the desktop's `createNote` saves one (and the links in its body). Returns its ID.
    @discardableResult
    func createNote(title: String, body: String) -> String {
        let id = newId(), now = Self.timestamp(Date(timeIntervalSince1970: TimeInterval(clock()) / 1000))
        stage("notes", key: [id], row: [
            "id": id, "title": Self.noteTitle(title), "body": String(body.prefix(200_000)), "created_at": now,
            "updated_at": now, "deleted_at": NSNull(),
        ])
        linkNote(id, body: body, at: now)
        return id
    }

    /// A note's title and body changed here (any computer's note): `updated_at` with them, and its links.
    func saveNote(_ id: String, title: String, body: String) {
        guard var row = state.entry("notes", key: [id])?.row, isNull(row["deleted_at"]), body.count <= 200_000 else { return }
        let title = Self.noteTitle(title)
        guard row.string("title") != title || row.string("body") != body else { return }
        let now = Self.timestamp(Date(timeIntervalSince1970: TimeInterval(clock()) / 1000))
        row["title"] = title
        row["body"] = body
        row["updated_at"] = now
        stage("notes", key: [id], row: row)
        linkNote(id, body: body, at: now)
    }

    /// Moves a note to the Trash (as the desktop's `deleteNote`), or brings it back.
    func trashNote(_ id: String, _ trashed: Bool) {
        guard var row = state.entry("notes", key: [id])?.row, trashed == isNull(row["deleted_at"]) else { return }
        row["deleted_at"] = trashed ? Self.timestamp(Date(timeIntervalSince1970: TimeInterval(clock()) / 1000)) : NSNull()
        stage("notes", key: [id], row: row)
    }

    private static func noteTitle(_ title: String) -> String {
        String(title.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
    }

    /// The links a note's body makes (owelk://note|highlight|document|ai/<id>), as the desktop's `syncNoteLinks`:
    /// only links that came or went change.
    private func linkNote(_ id: String, body: String, at now: String) {
        let pattern = #"owelk://(note|highlight|document|ai)/([A-Za-z0-9\-]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        var targets = Set<[String]>()
        for match in expression.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let kind = Range(match.range(at: 1), in: body), let target = Range(match.range(at: 2), in: body)
            else { continue }
            let link = [String(body[kind]), String(body[target])]
            if link != ["note", id] { targets.insert(link) }
        }
        var present = Set<[String]>()
        for entry in state.entries("links").values {
            guard let row = entry.row, row.string("from_kind") == "note", row.string("from_id") == id else { continue }
            present.insert([row.string("to_kind"), row.string("to_id")])
        }
        for gone in present.subtracting(targets) {
            stage("links", key: ["note", id, gone[0], gone[1]], row: nil)
        }
        for added in targets.subtracting(present) {
            stage("links", key: ["note", id, added[0], added[1]],
                  row: ["from_kind": "note", "from_id": id, "to_kind": added[0], "to_id": added[1], "created_at": now])
        }
    }

    // MARK: Text marks

    /// Highlights and comments made here on a page's text (rows from `textMarkRow`), saved for the computers. Returns
    /// false for a paper without a known PDF.
    @discardableResult
    func addMarks(_ rows: [Row], to paper: Paper) -> Bool {
        guard SyncProtocol.isSha256(paper.sha256) else { return false }
        let created = Self.timestamp(Date(timeIntervalSince1970: TimeInterval(clock()) / 1000))
        for var row in rows where !row.string("id").isEmpty {
            row["document_id"] = paper.documentId
            row["sha256"] = paper.sha256
            row["created_at"] = created
            stage("highlights", key: [row.string("id")], row: row)
        }
        return true
    }

    /// A mark's color and note changed here (any computer's mark): only those two columns change, as the desktop's
    /// `updateHighlight` does.
    func updateMark(_ id: String, color: String, body: String) {
        guard var row = state.entry("highlights", key: [id])?.row, isNull(row["deleted_at"]),
              PenTool.colors.contains(color), body.count <= 10000,
              row.string("color") != color || row.string("body") != body
        else { return }
        row["color"] = color
        row["body"] = body
        stage("highlights", key: [id], row: row)
    }

    /// A highlight or comment on a page's text, with every column the desktop writes (`saveTextSelection` in
    /// src/ResearchStore.cpp): the text, one rectangle per line as fractions of the page as shown, and the selection's
    /// character range on the page (the desktop only compares it, to find the same highlight made again). A comment
    /// needs its note, as on the desktop.
    static func textMarkRow(id: String, document: String, sha256: String, page: Int, kind: String, color: String,
                            text: String, lines: [CGRect], range: NSRange, body: String, createdAt: String) -> Row? {
        let round = { (value: CGFloat) in Double((value * 100_000).rounded() / 100_000) }
        let clamp = { (value: CGFloat) in min(1, max(0, value)) }
        let boxes: [Row] = lines.compactMap { line in
            guard line.minX.isFinite, line.minY.isFinite, line.maxX.isFinite, line.maxY.isFinite else { return nil }
            let x0 = clamp(line.minX), y0 = clamp(line.minY), x1 = clamp(line.maxX), y1 = clamp(line.maxY)
            guard x1 > x0, y1 > y0 else { return nil }
            return ["x": round(x0), "y": round(y0), "width": round(x1 - x0), "height": round(y1 - y0)]
        }
        let quoted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard page >= 0, !boxes.isEmpty, !quoted.isEmpty, quoted.count <= 100_000, PenTool.colors.contains(color),
              kind == "highlight" || (kind == "comment" && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              body.count <= 10000, range.location != NSNotFound
        else { return nil }
        return [
            "id": id, "document_id": document, "sha256": sha256, "page": page, "kind": kind, "color": color,
            "text": quoted, "body": body, "image": "", "font_size": 0, "drawing": "[]",
            // The desktop's end is past the last character (its fixture: 86 to 194 for 108 characters).
            "start_index": range.location, "end_index": NSMaxRange(range),
            "created_at": createdAt, "deleted_at": NSNull(), "rectangles": JSON.text(boxes),
        ]
    }

    /// A pen mark with every column the desktop writes (`saveAnnotation` in src/ResearchStoreHighlights.cpp): its
    /// points and their box as fractions of the page, 2 to 5,000 of them.
    static func strokeRow(id: String, document: String, sha256: String, page: Int, points: [CGPoint], color: String,
                          createdAt: String) -> Row? {
        let inside = points.filter { $0.x.isFinite && $0.y.isFinite }
            .map { CGPoint(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) }
        guard inside.count >= 2 else { return nil }
        let kept = inside.count <= 5000 ? inside
            : (0..<5000).map { inside[$0 * (inside.count - 1) / 4999] }
        let round = { (value: CGFloat) in Double((value * 100_000).rounded() / 100_000) }
        var box = kept.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        // A straight line still has a box with some size, as the desktop wants one.
        box = box.insetBy(dx: min(0, box.width - 0.001) / 2, dy: min(0, box.height - 0.001) / 2)
        box.origin = CGPoint(x: max(0, min(box.minX, 1 - box.width)), y: max(0, min(box.minY, 1 - box.height)))
        return [
            "id": id, "document_id": document, "sha256": sha256, "page": page, "kind": "draw", "color": color,
            "text": "", "body": "", "image": "", "font_size": 0, "start_index": -1, "end_index": -1,
            "created_at": createdAt, "deleted_at": NSNull(),
            "rectangles": JSON.text([["x": round(box.minX), "y": round(box.minY), "width": round(box.width),
                                      "height": round(box.height)]]),
            "drawing": JSON.text(kept.map { ["x": round($0.x), "y": round($0.y)] }),
        ]
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
        if var listed = library.papers.first(where: { $0.id == paper.sha256 }) {
            // Its PDF gone from the folder (or not there yet): this copy puts it back.
            if !listed.hasFile, (try? folder.savePaper(paper.data, sha256: paper.sha256)) != nil {
                files = (files ?? folder.paperFiles()).union([paper.sha256])
                library = Library.build(state, files: files ?? [])
                listed = library.papers.first { $0.id == paper.sha256 } ?? listed
            }
            file(listed, collection: collection, tag: tag)
            return .already(library.papers.first { $0.id == paper.sha256 } ?? listed)
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

    private func stage(_ table: String, key: [Any], row: Row?) {
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
