import SwiftUI

/// The notes (the desktop's Markdown notes, synced): the latest changed first, searched by title and text. A swipe
/// moves one to the Trash, as on the desktop.
struct NotesScreen: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var path: [NoteRoute] = []
    @State private var query = ""

    private var notes: [Note] {
        let words = query.split(separator: " ").map(String.init)
        return store.library.notes.filter { note in
            words.allSatisfy { note.title.localizedStandardContains($0) || note.body.localizedStandardContains($0) }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List(notes) { note in
                NavigationLink(value: NoteRoute.note(note.id)) { NoteRow(note: note) }
                    .swipeActions {
                        Button(role: .destructive) {
                            store.trashNote(note.id)
                        } label: {
                            Label("Move to Trash", systemImage: "trash")
                        }
                    }
            }
            .listStyle(.plain)
            .overlay {
                if notes.isEmpty {
                    Text(query.isEmpty ? "No notes yet. Make one with +, or from a paper's Notes." : "No notes match “\(query)”.")
                        .foregroundStyle(.secondary).padding()
                }
            }
            .navigationTitle("Notes")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Notes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        path.append(.new(paper: nil))
                    } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                    .tint(.primary)
                }
            }
            .navigationDestination(for: NoteRoute.self) { route in
                switch route {
                case let .note(id): NoteEditor(noteId: id)
                case let .new(paper): NoteEditor(noteId: nil, paper: paper)
                }
            }
        }
    }
}

enum NoteRoute: Hashable {
    case note(String)
    /// A new note, about a paper when one is given.
    case new(paper: Paper?)
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.displayTitle).font(.body.weight(.medium)).lineLimit(1)
            let snippet = note.body.split(whereSeparator: \.isNewline).joined(separator: " ")
            if !snippet.isEmpty { Text(snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            if let date = ISO8601DateFormatter.withFraction.date(from: note.updatedAt) {
                Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A note to read and write: its title and Markdown text (typed, or written with Apple Pencil through Scribble),
/// saved a moment after each change and when it closes. Preview shows the Markdown. A new note about a paper starts
/// with a link to it, so it is that paper's note on every computer.
struct NoteEditor: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let noteId: String?
    var paper: Paper?
    @State private var id: String?
    @State private var title = ""
    @State private var text = ""
    @State private var started = false
    @State private var previewing = false
    @State private var saving: Task<Void, Never>?
    /// The new note is being made (once).
    @State private var creating = false
    @FocusState private var writing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Title", text: $title)
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            if previewing {
                ScrollView {
                    AnswerText(text: text).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
            } else {
                TextEditor(text: $text)
                    .focused($writing)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 15)
            }
        }
        .navigationTitle(title.isEmpty ? "Note" : title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("View", selection: $previewing) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    saving?.cancel()
                    if let id { store.trashNote(id) }
                    id = nil
                    title = ""
                    text = ""
                    dismiss()
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .tint(.primary)
                .disabled(id == nil)
            }
        }
        .environment(\.openURL, OpenURLAction { url in url.scheme == "owelk" ? .handled : .systemAction })
        .onAppear(perform: start)
        .onChange(of: title) { _, _ in later() }
        .onChange(of: text) { _, _ in later() }
        .onDisappear {
            saving?.cancel()
            save()
        }
    }

    private func start() {
        guard !started else { return }
        started = true
        if let noteId, let note = store.library.notes.first(where: { $0.id == noteId }) {
            id = note.id
            title = note.title
            text = note.body
        } else if let paper {
            title = paper.title
            text = "[\(paper.title)](owelk://document/\(paper.documentId))\n\n"
            writing = true
        } else {
            writing = true
        }
    }

    /// Saved a moment after the last change.
    private func later() {
        guard started else { return }
        saving?.cancel()
        saving = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { save() }
        }
    }

    private func save() {
        if let id {
            store.saveNote(id, title: title, body: text)
            return
        }
        // A new note is made once it has something besides its paper's link.
        let link = paper.map { "[\($0.title)](owelk://document/\($0.documentId))" } ?? ""
        let content = text.replacingOccurrences(of: link, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || (paper == nil && !title.trimmingCharacters(in: .whitespaces).isEmpty), !creating
        else { return }
        creating = true
        let made = (title, text)
        Task {
            id = await store.createNote(title: made.0, body: made.1)
            creating = false
            // Written on while it was being made.
            if let id, (title, text) != made { store.saveNote(id, title: title, body: text) }
        }
    }
}

/// A paper's notes in the reader: the notes that link to it, and a new note about it.
struct PaperNotes: View {
    @EnvironmentObject private var store: LibraryStore
    let paper: Paper
    @State private var path: [NoteRoute] = []

    private var notes: [Note] { store.library.notes.filter { $0.papers.contains(paper.id) } }

    var body: some View {
        NavigationStack(path: $path) {
            List(notes) { note in
                NavigationLink(value: NoteRoute.note(note.id)) { NoteRow(note: note) }
            }
            .listStyle(.plain)
            .overlay {
                if notes.isEmpty {
                    Text("No notes about this paper yet.").foregroundStyle(.secondary).padding()
                }
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        path.append(.new(paper: paper))
                    } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                }
            }
            .navigationDestination(for: NoteRoute.self) { route in
                switch route {
                case let .note(id): NoteEditor(noteId: id)
                case let .new(paper): NoteEditor(noteId: nil, paper: paper)
                }
            }
        }
        .tint(.primary)
    }
}

extension ISO8601DateFormatter {
    /// Qt's `Qt::ISODateWithMs` in UTC, as the computers write times.
    static let withFraction: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()
}
