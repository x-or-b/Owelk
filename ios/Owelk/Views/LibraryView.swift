import SwiftUI

/// Which papers the list shows.
enum Shelf: Hashable {
    case all, recent
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

    var body: some View {
        NavigationSplitView {
            Sidebar(shelf: $shelf, choosingFolder: $choosingFolder)
        } detail: {
            PaperList(papers: papers, empty: emptyText, opened: $opened)
                .navigationTitle(title)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Titles")
                .refreshable { await store.refresh() }
                .toolbar {
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
        .fullScreenCover(item: $opened) { paper in
            ReaderScreen(paper: paper).environmentObject(store)
        }
    }

    private var title: String {
        switch shelf ?? .all {
        case .all: "All Papers"
        case .recent: "Recent"
        case let .collection(id): store.library.collections.first { $0.id == id }?.name ?? "Collection"
        case let .tag(name): name
        }
    }

    private var emptyText: String {
        if !query.isEmpty { return "No papers match “\(query)”." }
        if store.library.papers.isEmpty { return store.syncing ? "Reading the sync folder…" : "No papers yet." }
        return shelf == .recent ? "Papers opened on any computer appear here." : "No papers here."
    }

    private var papers: [Paper] {
        var list = store.library.papers
        switch shelf ?? .all {
        case .all: break
        case .recent: list = list.filter { !$0.openedAt.isEmpty }
        case let .collection(id): list = list.filter { $0.collections.contains(id) }
        case let .tag(name): list = list.filter { $0.tags.contains(name) }
        }
        let words = query.split(separator: " ").map(String.init)
        if !words.isEmpty {
            list = list.filter { paper in
                words.allSatisfy { paper.title.localizedStandardContains($0) || paper.authors.localizedStandardContains($0) }
            }
        }
        if shelf == .recent {
            return Array(list.sorted { $0.openedAt > $1.openedAt }.prefix(30))
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

    var body: some View {
        List(selection: $shelf) {
            Section {
                Label("All Papers", systemImage: "books.vertical").tag(Shelf.all)
                Label("Recent", systemImage: "clock").tag(Shelf.recent)
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
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if store.syncing { ProgressView().controlSize(.mini) }
                    Text(store.status.isEmpty ? " " : store.status)
                        .foregroundStyle(store.failed ? Color.red : Color.secondary)
                        .lineLimit(3)
                }
                if let name = store.folderName {
                    Text("Folder: \(name)").foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    choosingFolder = true
                } label: {
                    Label("Sync Folder", systemImage: "folder.badge.gearshape")
                }
                .tint(.primary)
            }
        }
    }
}

private struct PaperList: View {
    let papers: [Paper]
    let empty: String
    @Binding var opened: Paper?

    var body: some View {
        List(papers) { paper in
            Button {
                opened = paper
            } label: {
                PaperRow(paper: paper)
            }
            .disabled(!paper.hasFile)
        }
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
            Text(paper.title)
                .font(.body.weight(.medium))
                .foregroundStyle(paper.hasFile ? .primary : .secondary)
                .lineLimit(2)
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
