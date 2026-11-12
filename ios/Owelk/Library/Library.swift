import Foundation

/// A paper in the library. Rows of `documents` with the same PDF (the same SHA-256) are one paper, as they become one
/// on the computers when sync merges them.
struct Paper: Identifiable, Hashable {
    /// The PDF's SHA-256, or "doc:<id>" while a paper has no fingerprint yet.
    let id: String
    let sha256: String
    /// The ID this app writes under: the smallest, which is the one every computer keeps after merging.
    let documentId: String
    let title: String
    let authors: String
    let year: String
    let readingState: String
    let favorite: Bool
    let addedAt: String
    let collections: [String]
    let tags: [String]
    /// When it was last opened on any computer (ISO 8601), or "".
    let openedAt: String
    let hasFile: Bool
    /// It has marks (highlights, comments, pen strokes…) from any computer.
    var annotated = false

    var readingLabel: String {
        switch readingState {
        case "reading": "Reading"
        case "read": "Read"
        default: "Unread"
        }
    }
}

/// A note (the desktop's `notes`: Markdown, up to 200,000 characters), with the papers it links to.
struct Note: Identifiable, Hashable {
    let id: String
    let title: String
    let body: String
    /// When it last changed (ISO 8601).
    let updatedAt: String
    /// The papers (`Paper.id`) its body links to (owelk://document/…).
    let papers: [String]

    var displayTitle: String { title.isEmpty ? "Untitled note" : title }
}

struct PaperCollection: Identifiable, Hashable {
    let id: String
    let name: String
    let depth: Int
}

struct PaperTag: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Where a paper was left: Owelk's position JSON, `{page, y, x, zoom, fit}` (see `position()` in qml/PdfCanvas.qml).
/// `page` counts from 0; `y` is how far down that page the top of the view is, as a fraction of its height.
struct ReadingPosition: Equatable {
    var page: Int
    var y: Double
}

/// What the library looks like after merging every computer's changes.
struct Library {
    var papers: [Paper] = []
    var collections: [PaperCollection] = []
    var tags: [PaperTag] = []
    /// Notes not in the Trash, the latest changed first.
    var notes: [Note] = []
    /// documents.id → paper id, for every row ever seen (removed papers too), so annotations and positions saved
    /// under any of a paper's IDs find it.
    var paperOf: [String: String] = [:]

    static let empty = Library()

    static func build(_ state: SyncState, files: Set<String>) -> Library {
        var library = Library()
        var groups: [String: [(Version, Row)]] = [:]
        for entry in state.entries("documents").values {
            guard let row = entry.row else { continue }
            let id = row.string("id")
            guard !id.isEmpty, row.string("kind") != "web" else { continue }
            let sha = row.string("sha256")
            let key = SyncProtocol.isSha256(sha) ? sha : "doc:" + id
            library.paperOf[id] = key
            // Papers taken out of the Library or in its Trash are not listed.
            guard isNull(row["removed_at"]), isNull(row["trashed_at"]) else { continue }
            groups[key, default: []].append((entry.version, row))
        }

        var collectionsOf: [String: Set<String>] = [:]
        var collectionNames: [String: Row] = [:]
        for entry in state.entries("collections").values {
            if let row = entry.row, !row.string("id").isEmpty { collectionNames[row.string("id")] = row }
        }
        for entry in state.entries("collection_documents").values {
            guard let row = entry.row, collectionNames[row.string("collection_id")] != nil,
                  let paper = library.paperOf[row.string("document_id")] else { continue }
            collectionsOf[paper, default: []].insert(row.string("collection_id"))
        }
        var tagNames: [String: String] = [:]
        for entry in state.entries("tags").values {
            if let row = entry.row, !row.string("id").isEmpty { tagNames[row.string("id")] = row.string("name") }
        }
        var tagsOf: [String: Set<String>] = [:]
        for entry in state.entries("document_tags").values {
            guard let row = entry.row, let name = tagNames[row.string("tag_id")],
                  let paper = library.paperOf[row.string("document_id")] else { continue }
            tagsOf[paper, default: []].insert(name)
        }
        var opened: [String: String] = [:]
        for entry in state.entries("recent_documents").values {
            guard let row = entry.row, let paper = library.paperOf[row.string("document_id")] else { continue }
            opened[paper] = max(opened[paper] ?? "", row.string("opened_at"))
        }

        var annotated: Set<String> = []
        for entry in state.entries("highlights").values {
            guard let row = entry.row, isNull(row["deleted_at"]), let paper = library.paperOf[row.string("document_id")]
            else { continue }
            annotated.insert(paper)
        }

        // Which papers each note links to (the desktop keeps the links of a note's body in `links`).
        var linked: [String: [String]] = [:]
        for entry in state.entries("links").values {
            guard let row = entry.row, row.string("from_kind") == "note", row.string("to_kind") == "document",
                  let paper = library.paperOf[row.string("to_id")] else { continue }
            linked[row.string("from_id"), default: []].append(paper)
        }
        library.notes = state.entries("notes").values.compactMap { entry -> Note? in
            guard let row = entry.row, !row.string("id").isEmpty, isNull(row["deleted_at"]) else { return nil }
            return Note(id: row.string("id"), title: row.string("title"), body: row.string("body"),
                        updatedAt: row.string("updated_at"),
                        papers: Array(Set(linked[row.string("id")] ?? [])).sorted())
        }.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }

        library.papers = groups.map { key, rows in
            // The latest edit of the paper's details; the smallest ID to write under.
            let newest = rows.max { !$0.0.replaces($1.0) }!.1
            let titled = rows.sorted { $0.0.replaces($1.0) }.first { !$0.1.string("title").isEmpty }?.1 ?? newest
            return Paper(id: key, sha256: SyncProtocol.isSha256(key) ? key : "",
                         documentId: rows.map { $0.1.string("id") }.min()!,
                         title: displayTitle(titled), authors: newest.string("authors"), year: newest.string("year"),
                         readingState: newest.string("reading_state"), favorite: newest.int("favorite") != 0,
                         addedAt: newest.string("added_at"), collections: Array(collectionsOf[key] ?? []).sorted(),
                         tags: Array(tagsOf[key] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                         openedAt: opened[key] ?? "", hasFile: files.contains(key), annotated: annotated.contains(key))
        }

        // Collections nest by parent_id; a parent that is gone leaves its children at the top.
        var children: [String: [Row]] = [:]
        for row in collectionNames.values {
            let parent = row.string("parent_id")
            children[collectionNames[parent] == nil ? "" : parent, default: []].append(row)
        }
        func walk(_ parent: String, _ depth: Int, _ seen: Set<String>) {
            let rows = (children[parent] ?? []).sorted {
                $0.string("name").localizedStandardCompare($1.string("name")) == .orderedAscending
            }
            for row in rows where !seen.contains(row.string("id")) {
                library.collections.append(PaperCollection(id: row.string("id"), name: row.string("name"), depth: depth))
                walk(row.string("id"), depth + 1, seen.union([row.string("id")]))
            }
        }
        walk("", 0, [])
        library.tags = tagNames.map { PaperTag(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return library
    }

    /// A paper's title, or its file's name until one is known (as the desktop shows it).
    static func displayTitle(_ row: Row) -> String {
        let title = row.string("title").trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let name = URL(string: row.string("url"))?.deletingPathExtension().lastPathComponent ?? ""
        return name.isEmpty ? "Untitled" : name
    }

    /// The newest row of a table keyed by document_id that belongs to the paper, under any of its IDs.
    func newest(_ table: String, for paper: Paper, in state: SyncState) -> SyncState.Entry? {
        state.entries(table).values.filter { entry in
            guard let row = entry.row else { return false }
            return paperOf[row.string("document_id")] == paper.id
        }.max { $1.version.replaces($0.version) }
    }

    func position(of paper: Paper, in state: SyncState) -> ReadingPosition? {
        guard let row = newest("reading_positions", for: paper, in: state)?.row,
              let position = JSON.value(row.string("position")) as? Row else { return nil }
        return ReadingPosition(page: max(0, position.int("page")), y: min(1, max(0, position.double("y"))))
    }
}
