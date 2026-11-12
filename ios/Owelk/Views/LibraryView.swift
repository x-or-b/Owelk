import SwiftUI
import UniformTypeIdentifiers

/// Which papers the list shows.
enum Shelf: Hashable {
    case all, favorites, reading, annotated
    case collection(String)
    case tag(String)
}

enum PaperOrder: String, CaseIterable, Identifiable {
    case lastOpened = "Last Opened", title = "Title", added = "Date Added"
    var id: String { rawValue }
}

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var choosingFolder: Bool
    @State private var shelf: Shelf? = .all
    @State private var query = ""
    @State private var order = PaperOrder.lastOpened
    @State private var opened: Paper?
    @State private var addingFiles = false
    @State private var searching = false
    /// A paper to open once the web search has closed.
    @State private var openAfterSearch: Paper?
    @State private var dropping = false

    var body: some View {
        NavigationSplitView {
            Sidebar(shelf: $shelf, choosingFolder: $choosingFolder)
        } detail: {
            PaperList(papers: papers, empty: emptyText, opened: $opened)
                .navigationTitle(title)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Titles")
                .refreshable { await store.refresh() }
                .onDrop(of: [.pdf], isTargeted: $dropping) { providers in
                    let (collection, tag) = destination
                    Task { await store.add(await Self.incoming(providers), collection: collection, tag: tag) }
                    return true
                }
                .overlay {
                    if dropping {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent, lineWidth: 2).padding(8)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) { NoticeBar { opened = $0 } }
                .fileImporter(isPresented: $addingFiles, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
                    let (collection, tag) = destination
                    switch result {
                    case let .success(urls): Task { await store.addFiles(urls, collection: collection, tag: tag) }
                    case let .failure(error): store.notice = .init(text: error.localizedDescription, failed: true)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                addingFiles = true
                            } label: {
                                Label("Add PDFs from Files…", systemImage: "folder")
                            }
                            Button {
                                searching = true
                            } label: {
                                Label("Search the Web…", systemImage: "globe")
                            }
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .tint(.primary)
                        .disabled(!store.hasFolder)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Sort By", selection: $order) {
                                ForEach(PaperOrder.allCases) { Text($0.rawValue).tag($0) }
                            }
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                        }
                        .tint(.primary)
                    }
                }
        }
        .fullScreenCover(isPresented: $searching, onDismiss: {
            if let paper = openAfterSearch {
                openAfterSearch = nil
                opened = paper
            }
        }) {
            let (collection, tag) = destination
            WebSearchScreen(collection: collection, tag: tag, openAfter: $openAfterSearch).environmentObject(store)
        }
        .fullScreenCover(item: $opened) { paper in
            ReaderScreen(paper: paper).environmentObject(store)
        }
    }

    private var title: String {
        switch shelf ?? .all {
        case .all: "All Papers"
        case .favorites: "Favorites"
        case .reading: "Reading"
        case .annotated: "Annotated"
        case let .collection(id): store.library.collections.first { $0.id == id }?.name ?? "Collection"
        case let .tag(name): name
        }
    }

    /// The collection or tag (IDs) a paper added now goes into: the one shown.
    private var destination: (collection: String?, tag: String?) {
        switch shelf ?? .all {
        case let .collection(id): (id, nil)
        case let .tag(name): (nil, store.library.tags.first { $0.name == name }?.id)
        default: (nil, nil)
        }
    }

    /// The PDFs dropped on the list. A dropped file's copy lasts only while it is being read, so it is read there.
    private static func incoming(_ providers: [NSItemProvider]) async -> [LibraryStore.Incoming] {
        var items: [LibraryStore.Incoming] = []
        for provider in providers {
            let name = provider.suggestedName ?? "Paper"
            var data = await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
                _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, _ in
                    done.resume(returning: url.flatMap { try? Data(contentsOf: $0) })
                }
            }
            if data == nil { // Some apps offer the bytes only.
                data = await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
                    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { data, _ in
                        done.resume(returning: data)
                    }
                }
            }
            items.append(LibraryStore.Incoming(name: name, data: data))
        }
        return items
    }

    private var emptyText: String {
        if !query.isEmpty { return "No papers match “\(query)”." }
        if store.library.papers.isEmpty {
            return store.syncing ? "Reading the sync folder…" : "No papers yet. Add PDFs with + or drop them here."
        }
        switch shelf ?? .all {
        case .favorites: return "Papers you favorite (swipe right on one, or hold it) appear here."
        case .reading: return "Papers you are reading appear here."
        case .annotated: return "Papers with highlights, comments or pen marks appear here."
        default: return "No papers here."
        }
    }

    private var papers: [Paper] {
        var list = store.library.papers
        switch shelf ?? .all {
        case .all: break
        case .favorites: list = list.filter(\.favorite)
        case .reading: list = list.filter { $0.readingState == "reading" }
        case .annotated: list = list.filter(\.annotated)
        case let .collection(id): list = list.filter { $0.collections.contains(id) }
        case let .tag(name): list = list.filter { $0.tags.contains(name) }
        }
        let words = query.split(separator: " ").map(String.init)
        if !words.isEmpty {
            list = list.filter { paper in
                words.allSatisfy { paper.title.localizedStandardContains($0) || paper.authors.localizedStandardContains($0) }
            }
        }
        switch order {
        case .lastOpened:
            return list.sorted { ($0.openedAt, $0.addedAt, $0.id) > ($1.openedAt, $1.addedAt, $1.id) }
        case .title:
            return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .added:
            return list.sorted { ($0.addedAt, $0.id) > ($1.addedAt, $1.id) }
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var shelf: Shelf?
    @Binding var choosingFolder: Bool
    @State private var showsSettings = false
    /// Change Folder was chosen in Settings: Files opens once Settings has closed.
    @State private var changesFolder = false

    var body: some View {
        List(selection: $shelf) {
            Section {
                Label("All Papers", systemImage: "books.vertical").tag(Shelf.all)
                Label("Favorites", systemImage: "star").tag(Shelf.favorites)
                Label("Reading", systemImage: "book").tag(Shelf.reading)
                Label("Annotated", systemImage: "highlighter").tag(Shelf.annotated)
            }
            if !store.library.collections.isEmpty {
                Section("Collections") {
                    ForEach(store.library.collections) { collection in
                        Label(collection.name, systemImage: "folder")
                            .padding(.leading, CGFloat(collection.depth) * 16)
                            .tag(Shelf.collection(collection.id))
                    }
                }
            }
            if !store.library.tags.isEmpty {
                Section("Tags") {
                    ForEach(store.library.tags) { tag in
                        Label(tag.name, systemImage: "tag").tag(Shelf.tag(tag.name))
                    }
                }
            }
        }
        .navigationTitle("Owelk")
        // Sync is set up once, so it lives in Settings; the foot of the list speaks only while syncing or when a sync
        // failed.
        .safeAreaInset(edge: .bottom) {
            if store.syncing || store.failed {
                HStack(spacing: 6) {
                    if store.syncing { ProgressView().controlSize(.mini) }
                    Text(store.failed ? store.status : "Syncing…")
                        .foregroundStyle(store.failed ? Color.red : Color.secondary)
                        .lineLimit(3)
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.bar)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showsSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .tint(.primary)
            }
        }
        .sheet(isPresented: $showsSettings, onDismiss: {
            if changesFolder {
                changesFolder = false
                choosingFolder = true
            }
        }) {
            SettingsSheet {
                changesFolder = true
                showsSettings = false
            }
        }
    }
}

/// Settings: the sync folder, how the last sync went, Sync Now and Change Folder.
private struct SettingsSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let changeFolder: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Sync") {
                    LabeledContent("Folder", value: store.folderName ?? "None")
                    LabeledContent("Last Sync") {
                        HStack(spacing: 6) {
                            if store.syncing { ProgressView().controlSize(.mini) }
                            Text(store.syncing ? "Syncing…" : store.status)
                                .foregroundStyle(store.failed ? Color.red : Color.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    Button("Sync Now") { Task { await store.refresh() } }
                        .disabled(store.syncing)
                    Button("Change Folder…", action: changeFolder)
                }
                AiSection()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
    }
}

/// A paper's tags or collections being chosen.
private enum Filing: Identifiable {
    case tags(Paper), collections(Paper)

    var id: String {
        switch self {
        case let .tags(paper): "tags " + paper.id
        case let .collections(paper): "collections " + paper.id
        }
    }

    var paper: Paper {
        switch self {
        case let .tags(paper), let .collections(paper): paper
        }
    }
}

private struct PaperList: View {
    @EnvironmentObject private var store: LibraryStore
    let papers: [Paper]
    let empty: String
    @Binding var opened: Paper?
    @State private var filing: Filing?

    var body: some View {
        List(papers) { paper in
            Button {
                opened = paper
            } label: {
                PaperRow(paper: paper)
            }
            .disabled(!paper.hasFile)
            .swipeActions(edge: .leading) {
                Button {
                    store.setFavorite(!paper.favorite, of: paper)
                } label: {
                    Label(paper.favorite ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: paper.favorite ? "star.slash" : "star")
                }
                .tint(Theme.accent)
            }
            .contextMenu {
                Button {
                    store.setFavorite(!paper.favorite, of: paper)
                } label: {
                    Label(paper.favorite ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: paper.favorite ? "star.slash" : "star")
                }
                Picker(selection: Binding(get: { paper.readingState.isEmpty ? "unread" : paper.readingState },
                                          set: { store.setReadingState($0, of: paper) })) {
                    Text("Unread").tag("unread")
                    Text("Reading").tag("reading")
                    Text("Read").tag("read")
                } label: {
                    Label("Reading State", systemImage: "book")
                }
                .pickerStyle(.menu)
                Button {
                    filing = .tags(paper)
                } label: {
                    Label("Tags…", systemImage: "tag")
                }
                Button {
                    filing = .collections(paper)
                } label: {
                    Label("Collections…", systemImage: "folder")
                }
            }
        }
        .sheet(item: $filing) { FilingSheet(filing: $0) }
        .listStyle(.plain)
        .overlay {
            if papers.isEmpty {
                Text(empty).foregroundStyle(.secondary).padding()
            }
        }
    }
}

private struct PaperRow: View {
    let paper: Paper

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(paper.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(paper.hasFile ? .primary : .secondary)
                    .lineLimit(2)
                if paper.favorite {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Favorite")
                }
            }
            let details = [paper.authors, paper.year].filter { !$0.isEmpty }.joined(separator: " · ")
            if !details.isEmpty {
                Text(details).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                Text(paper.readingLabel)
                if !paper.tags.isEmpty { Text(paper.tags.map { "#" + $0 }.joined(separator: " ")).lineLimit(1) }
                if !paper.hasFile { Text("Waiting for the PDF") }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// The AI: the service and its API key (kept in this iPad's Keychain), the model, and how answers are written.
private struct AiSection: View {
    @State private var service = AiSettings.service
    @State private var key = AiSettings.key(for: AiSettings.service)
    @State private var model = AiSettings.model(for: AiSettings.service)
    @State private var language = AiSettings.language
    @State private var level = AiSettings.level

    var body: some View {
        Section {
            Picker("Service", selection: $service) {
                ForEach(AiService.allCases) { Text($0.name).tag($0) }
            }
            SecureField("API Key", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { AiSettings.setKey(key, for: service) }
            if service == .claude {
                Picker("Model", selection: $model) {
                    ForEach(service.models, id: \.id) { Text($0.name).tag($0.id) }
                }
            } else {
                TextField("Model", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Picker("Answer Language", selection: $language) {
                ForEach(AiSettings.languages, id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("Explanations", selection: $level) {
                Text("Easy").tag("easy")
                Text("Brief").tag("brief")
            }
        } header: {
            Text("AI")
        } footer: {
            Text("When you ask, the paper's text and your question go to this service with your key. The key stays on this iPad.")
        }
        .onChange(of: service) { old, new in
            AiSettings.setKey(key, for: old)
            AiSettings.setModel(model, for: old)
            AiSettings.service = new
            key = AiSettings.key(for: new)
            model = AiSettings.model(for: new)
        }
        .onChange(of: key) { _, key in AiSettings.setKey(key, for: service) }
        .onChange(of: model) { _, model in AiSettings.setModel(model, for: service) }
        .onChange(of: language) { _, language in AiSettings.language = language }
        .onChange(of: level) { _, level in AiSettings.level = level }
        .onDisappear { AiSettings.setKey(key, for: service) }
    }
}

/// A paper's tags or collections: a tap puts it in or takes it out, and a new one can be made with it in.
private struct FilingSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let filing: Filing
    @State private var name = ""

    private var tags: Bool { if case .tags = filing { true } else { false } }
    /// The paper as it is now (it changes while the sheet is open).
    private var paper: Paper { store.library.papers.first { $0.id == filing.paper.id } ?? filing.paper }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if tags {
                        ForEach(store.library.tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { tag in
                            row(tag.name, depth: 0, in: paper.tags.contains(tag.name)) {
                                store.setTag(tag.id, !paper.tags.contains(tag.name), of: paper)
                            }
                        }
                    } else {
                        ForEach(store.library.collections) { collection in
                            row(collection.name, depth: collection.depth, in: paper.collections.contains(collection.id)) {
                                store.setCollection(collection.id, !paper.collections.contains(collection.id), of: paper)
                            }
                        }
                    }
                }
                Section {
                    HStack {
                        TextField(tags ? "New Tag" : "New Collection", text: $name)
                            .onSubmit(add)
                        Button("Add", action: add)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle(tags ? "Tags" : "Collections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
    }

    private func row(_ title: String, depth: Int, in member: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack {
                Text(title).padding(.leading, CGFloat(depth) * 16)
                Spacer()
                if member { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityAddTraits(member ? .isSelected : [])
    }

    private func add() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if tags { store.tag(paper, named: name) } else { store.collect(paper, inNew: name) }
        self.name = ""
    }
}

/// What adding papers came to, for a few seconds at the foot of the list; the paper can be opened from it.
struct NoticeBar: View {
    @EnvironmentObject private var store: LibraryStore
    let open: (Paper) -> Void

    var body: some View {
        if let notice = store.notice {
            HStack(spacing: 12) {
                Text(notice.text)
                    .foregroundStyle(notice.failed ? Color.red : Color.primary)
                    .lineLimit(3)
                if let paper = notice.paper, paper.hasFile {
                    Button("Open") {
                        store.notice = nil
                        open(paper)
                    }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                }
                Button {
                    store.notice = nil
                } label: {
                    Image(systemName: "xmark").imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close")
            }
            .font(.callout)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: notice.id) {
                try? await Task.sleep(for: .seconds(6))
                if store.notice?.id == notice.id { withAnimation { store.notice = nil } }
            }
        }
    }
}
