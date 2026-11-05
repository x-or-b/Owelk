import Combine
import PDFKit
import SwiftUI

/// One open paper: its PDF, outline, search, and where the reader is.
@MainActor
final class ReaderModel: NSObject, ObservableObject, PDFDocumentDelegate {
    struct OutlineItem: Identifiable {
        let id: Int
        let title: String
        let depth: Int
        let page: Int
        let destination: PDFDestination?
    }

    struct SearchResult: Identifiable {
        let id: Int
        let selection: PDFSelection
        let page: Int
        let context: String
    }

    let paper: Paper
    let controller = ReaderViewController()
    @Published private(set) var loaded = false
    @Published private(set) var failure: String?
    @Published private(set) var outline: [OutlineItem] = []
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var searching = false
    @Published private(set) var page = 0
    @Published private(set) var pageCount = 0
    @Published var showsThumbnails = false {
        didSet { controller.showsThumbnails = showsThumbnails }
    }
    private var lastSaved: ReadingPosition?

    init(paper: Paper) {
        self.paper = paper
        super.init()
        controller.onPageChange = { [weak self] page in self?.page = page }
    }

    func load(from store: LibraryStore) async {
        guard !loaded, failure == nil else { return }
        guard let url = store.fileURL(of: paper) else {
            failure = "This PDF has not arrived in the sync folder yet."
            return
        }
        async let position = store.position(of: paper)
        async let marks = store.marks(of: paper)
        // PDFKit opens the file off the main thread; a file provider brings it down first if it has to.
        let document = await Task.detached(priority: .userInitiated) {
            try? coordinatedRead(url) { PDFDocument(url: $0) }
        }.value
        guard let document, document.pageCount > 0 else {
            failure = "This PDF cannot be opened."
            return
        }
        if document.isLocked {
            failure = "This PDF is locked with a password."
            return
        }
        let start = await position
        lastSaved = start
        controller.start = start
        controller.document = document
        controller.show(await marks) { name in
            store.annotationImage(name)
        }
        pageCount = document.pageCount
        page = start?.page ?? 0
        outline = Self.flatten(document)
        loaded = true
        store.opened(paper)
    }

    /// Notes where the reader is, when it moved.
    func savePosition(to store: LibraryStore) {
        guard loaded, let position = controller.position(), position != lastSaved else { return }
        lastSaved = position
        store.save(position, of: paper)
    }

    func go(to item: OutlineItem) {
        if let destination = item.destination {
            controller.pdfView.go(to: destination)
        } else if let page = controller.document?.page(at: item.page) {
            controller.pdfView.go(to: page)
        }
    }

    func go(to result: SearchResult) {
        controller.pdfView.setCurrentSelection(result.selection, animate: false)
        controller.pdfView.go(to: result.selection)
    }

    // MARK: Search

    private var query = ""

    func search(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document = controller.document, text != query else { return }
        query = text
        if document.isFinding { document.cancelFindString() }
        results = []
        controller.pdfView.highlightedSelections = nil
        guard !text.isEmpty else {
            searching = false
            return
        }
        searching = true
        document.delegate = self
        document.beginFindString(text, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    // PDFKit may call these from its search thread.
    nonisolated func didMatchString(_ instance: PDFSelection) {
        Task { @MainActor [weak self] in self?.add(instance) }
    }

    nonisolated func documentDidEndDocumentFind(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.searching = false }
    }

    private func add(_ selection: PDFSelection) {
        guard results.count < 500, let document = controller.document, let page = selection.pages.first else { return }
        let around = selection.copy() as? PDFSelection ?? selection
        around.extend(atStart: 40)
        around.extend(atEnd: 60)
        let context = (around.string ?? selection.string ?? "")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        selection.color = Theme.accentUI.withAlphaComponent(0.35)
        results.append(SearchResult(id: results.count, selection: selection, page: document.index(for: page),
                                    context: context))
        controller.pdfView.highlightedSelections = results.map(\.selection)
    }

    // MARK: Outline

    private static func flatten(_ document: PDFDocument) -> [OutlineItem] {
        var items: [OutlineItem] = []
        func walk(_ node: PDFOutline, _ depth: Int) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                let page = destination?.page.map { document.index(for: $0) } ?? 0
                items.append(OutlineItem(id: items.count, title: child.label ?? "", depth: depth, page: page,
                                         destination: destination))
                walk(child, depth + 1)
            }
        }
        if let root = document.outlineRoot { walk(root, 0) }
        return items
    }
}

struct ReaderPages: UIViewControllerRepresentable {
    let model: ReaderModel

    func makeUIViewController(context: Context) -> ReaderViewController { model.controller }
    func updateUIViewController(_ controller: ReaderViewController, context: Context) {}
}

/// A paper filling the screen, with its contents, search and page thumbnails in the bar.
struct ReaderScreen: View {
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var showsOutline = false
    @State private var showsSearch = false
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    init(paper: Paper) { _model = StateObject(wrappedValue: ReaderModel(paper: paper)) }

    var body: some View {
        NavigationStack {
            ZStack {
                ReaderPages(model: model).ignoresSafeArea(edges: [.bottom, .horizontal])
                if let failure = model.failure {
                    ContentUnavailableView(failure, systemImage: "doc")
                } else if !model.loaded {
                    ProgressView()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if model.loaded {
                    Text("\(model.page + 1) / \(model.pageCount)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(16)
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle(model.paper.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        close()
                    } label: {
                        Label("Library", systemImage: "chevron.backward")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        model.showsThumbnails.toggle()
                    } label: {
                        Label("Pages", systemImage: "sidebar.left")
                    }
                    .disabled(!model.loaded)
                    Button {
                        showsOutline = true
                    } label: {
                        Label("Contents", systemImage: "list.bullet.indent")
                    }
                    .disabled(model.outline.isEmpty)
                    .popover(isPresented: $showsOutline) {
                        OutlineList(model: model) { showsOutline = false }
                    }
                    Button {
                        showsSearch = true
                    } label: {
                        Label("Find", systemImage: "magnifyingglass")
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(!model.loaded)
                    .popover(isPresented: $showsSearch) {
                        SearchPanel(model: model)
                    }
                }
            }
            .tint(.primary)
        }
        .task { await model.load(from: store) }
        .onReceive(timer) { _ in model.savePosition(to: store) }
        .onChange(of: phase) { _, phase in
            if phase != .active { model.savePosition(to: store) }
        }
    }

    private func close() {
        model.savePosition(to: store)
        dismiss()
    }
}

private struct OutlineList: View {
    @ObservedObject var model: ReaderModel
    let done: () -> Void

    var body: some View {
        List(model.outline) { item in
            Button {
                model.go(to: item)
                done()
            } label: {
                HStack {
                    Text(item.title).lineLimit(2)
                    Spacer()
                    Text("\(item.page + 1)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.leading, CGFloat(item.depth) * 14)
            }
            .foregroundStyle(.primary)
        }
        .listStyle(.plain)
        .frame(minWidth: 340, minHeight: 420)
    }
}

private struct SearchPanel: View {
    @ObservedObject var model: ReaderModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in Paper", text: $text)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { model.search(text) }
                if model.searching { ProgressView() }
            }
            .padding(12)
            Divider()
            if model.results.isEmpty {
                Text(model.searching || text.isEmpty ? " " : "No matches")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                List(model.results) { result in
                    Button {
                        model.go(to: result)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Page \(result.page + 1)").font(.caption).foregroundStyle(.secondary)
                            Text(result.context).font(.callout).lineLimit(2)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 380, height: model.results.isEmpty ? 120 : 460)
        .onAppear { focused = true }
        .onChange(of: text) { _, value in
            if value.isEmpty { model.search("") }
        }
    }
}
