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
    /// Apple Pencil draws and erases (fingers still scroll).
    @Published var drawing = false {
        didSet { controller.drawing = drawing }
    }
    @Published private(set) var tool: PenTool
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// The pen's color, kept for the next paper.
    private var color: String
    private var previous = PenTool.eraser
    private var lastSaved: ReadingPosition?

    init(paper: Paper) {
        self.paper = paper
        let saved = UserDefaults.standard.string(forKey: "pen.color") ?? ""
        color = PenTool.colors.contains(saved) ? saved : PenTool.colors[0]
        tool = .pen(color)
        super.init()
        controller.pen.tool = tool
        controller.onPageChange = { [weak self] page in self?.page = page }
        controller.onUndo = { [weak self] in self?.undo() }
        controller.onPencil = { [weak self] action, point in self?.pencil(action, at: point) }
        controller.pen.changed = { [weak self] in
            // PencilKit notes the step in the history after telling of the change.
            DispatchQueue.main.async { self?.refreshHistory() }
        }
    }

    /// Marks can be made on a paper whose PDF is known (its SHA-256), as on the desktop.
    var canDraw: Bool { loaded && SyncProtocol.isSha256(paper.sha256) }

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
        controller.pen.drawn = { [weak self, weak store] page, id, points, color in
            guard let self, let store else { return }
            store.addStroke(id: id, to: self.paper, page: page, points: points, color: color)
        }
        controller.pen.erased = { [weak store] ids, erased in store?.setErased(ids, erased) }
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

    // MARK: Pen

    func choose(_ tool: PenTool) {
        if tool != self.tool { previous = self.tool }
        self.tool = tool
        controller.pen.tool = tool
        if case let .pen(hex) = tool {
            color = hex
            UserDefaults.standard.set(hex, forKey: "pen.color")
        }
    }

    func undo() {
        controller.pen.undoManager?.undo()
        refreshHistory()
    }

    func redo() {
        controller.pen.undoManager?.redo()
        refreshHistory()
    }

    private func refreshHistory() {
        canUndo = controller.pen.undoManager?.canUndo ?? false
        canRedo = controller.pen.undoManager?.canRedo ?? false
    }

    /// Apple Pencil's double tap or squeeze, doing what the reader chose for it in Settings › Apple Pencil.
    private func pencil(_ action: UIPencilPreferredAction, at point: CGPoint?) {
        guard canDraw else { return }
        switch action {
        case .switchEraser:
            if !drawing { drawing = true } else { choose(tool == .eraser ? .pen(color) : .eraser) }
        case .switchPrevious:
            if !drawing { drawing = true } else { choose(previous) }
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            drawing = true
            let palette = UIHostingController(rootView: PenPalette(model: self).padding(12))
            palette.sizingOptions = .preferredContentSize
            controller.presentPalette(palette, at: point)
        default:
            break
        }
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
            .overlay(alignment: .bottom) {
                if model.drawing {
                    PenPalette(model: model)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                        .padding(.bottom, 16)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if model.loaded && !model.drawing {
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
                        model.drawing.toggle()
                    } label: {
                        Label("Draw", systemImage: "pencil.tip.crop.circle")
                    }
                    .foregroundStyle(model.drawing ? Theme.accent : Color.primary)
                    .disabled(!model.canDraw)
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

/// The pen's colors (the desktop's mark colors), the eraser, and Undo and Redo.
struct PenPalette: View {
    @ObservedObject var model: ReaderModel
    private static let names = ["Blue", "Yellow", "Green", "Pink", "Purple", "Navy"]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(PenTool.colors.enumerated()), id: \.element) { index, hex in
                Button {
                    model.choose(.pen(hex))
                } label: {
                    Circle()
                        .fill(Color(uiColor: UIColor(hex: hex) ?? .black))
                        .frame(width: 22, height: 22)
                        .padding(4)
                        .overlay(Circle().strokeBorder(model.tool == .pen(hex) ? Theme.accent : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.names[index])
                .accessibilityAddTraits(model.tool == .pen(hex) ? .isSelected : [])
            }
            Divider().frame(height: 24)
            Button {
                model.choose(.eraser)
            } label: {
                Image(systemName: "eraser").frame(width: 30, height: 30)
            }
            .foregroundStyle(model.tool == .eraser ? Theme.accent : Color.primary)
            .accessibilityLabel("Eraser")
            .accessibilityAddTraits(model.tool == .eraser ? .isSelected : [])
            Divider().frame(height: 24)
            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 30, height: 30)
            }
            .accessibilityLabel("Undo")
            .disabled(!model.canUndo)
            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward").frame(width: 30, height: 30)
            }
            .accessibilityLabel("Redo")
            .disabled(!model.canRedo)
        }
        .tint(.primary)
        .font(.body)
    }
}
