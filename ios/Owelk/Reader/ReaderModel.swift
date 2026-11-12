import Combine
import PDFKit
import SwiftUI

/// One open paper: its PDF, search, and where the reader is.
@MainActor
final class ReaderModel: NSObject, ObservableObject, PDFDocumentDelegate {
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
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var searching = false
    @Published private(set) var page = 0
    @Published private(set) var pageCount = 0
    /// The AI beside the paper, and its conversation about it (kept while the paper is open).
    @Published var showsAI = false
    private(set) lazy var ai = AiChat(paper: paper) { [weak self] in self?.controller.document }
    /// A conversation chosen in the library's Chats, shown when the paper opens.
    private let chat: String?
    /// A place a link led to, shown when the paper opens.
    private let link: PaperLink?
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
    /// The pen's color, kept for the next paper (the highlighter's is `TextMarks.color`).
    private var color: String
    private var previous = PenTool.eraser
    /// The pen or highlighter last chosen, which the eraser gives way to.
    private var lastInk: PenTool
    private var lastSaved: ReadingPosition?

    init(paper: Paper, chat: String? = nil, link: PaperLink? = nil) {
        self.paper = paper
        self.chat = chat
        self.link = link
        let saved = UserDefaults.standard.string(forKey: "pen.color") ?? ""
        color = PenTool.colors.contains(saved) ? saved : PenTool.colors[0]
        tool = .pen(color)
        lastInk = .pen(color)
        super.init()
        controller.pen.tool = tool
        controller.onPageChange = { [weak self] page in self?.page = page }
        controller.onUndo = { [weak self] in self?.undo() }
        controller.onPencil = { [weak self] action, point in self?.pencil(action, at: point) }
        controller.onExplain = { [weak self] text in
            self?.showsAI = true
            self?.ai.explain(text)
        }
        controller.onAskAbout = { [weak self] text in
            self?.ai.attached = text
            self?.showsAI = true
        }
        controller.pen.changed = { [weak self] in
            // The step is in the history only once the change has been told.
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
        // Opened from a link: at its place (kept there as the pages are laid out), not where it was left.
        let target = link.map { place(of: $0, in: document) }
        controller.start = target?.position ?? start
        controller.pen.drawn = { [weak self, weak store] page, id, points, color in
            guard let self, let store else { return }
            store.addStroke(id: id, to: self.paper, page: page, points: points, color: color)
        }
        controller.pen.erased = { [weak store] ids, erased in store?.setErased(ids, erased) }
        controller.pen.placed = { [weak self, weak store] rows in
            guard let self, let store else { return }
            store.addMarks(rows, to: self.paper)
        }
        controller.onMarkChanged = { [weak store] id, color, body in store?.updateMark(id, color: color, body: body) }
        controller.document = document
        if let words = target?.words { controller.pdfView.highlightedSelections = [words] }
        controller.show(await marks) { name in
            store.annotationImage(name)
        }
        pageCount = document.pageCount
        page = start?.page ?? 0
        loaded = true
        controller.marksAllowed = canDraw
        await ai.keep(in: store, showing: chat)
        if chat != nil { showsAI = true }
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
        switch tool {
        case let .pen(hex):
            color = hex
            UserDefaults.standard.set(hex, forKey: "pen.color")
            lastInk = tool
        case let .highlighter(hex):
            TextMarks.color = hex
            lastInk = tool
        case .eraser:
            break
        }
    }

    /// The pen with its color.
    func choosePen() { choose(.pen(color)) }

    /// The highlighter with its color (the one highlights made from the menu take too).
    func chooseHighlighter() { choose(.highlighter(TextMarks.color)) }

    /// A color for the pen or highlighter in hand (the last one, while erasing).
    func choose(color hex: String) { choose((tool == .eraser ? lastInk : tool).with(hex)) }

    /// The color shown as chosen: the pen's or highlighter's in hand (the last one's, while erasing).
    var ink: String { (tool == .eraser ? lastInk : tool).ink ?? color }

    var highlighting: Bool {
        if case .highlighter = tool { true } else { false }
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
            if !drawing { drawing = true } else { choose(tool == .eraser ? lastInk : .eraser) }
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

    /// Puts a page's top at the top of the view.
    func go(toPage index: Int) {
        guard let page = controller.document?.page(at: min(max(0, index), pageCount - 1)) else { return }
        controller.go(to: page, y: 0)
    }

    /// A place in this paper a link leads to: its page, with the words it quotes picked out when they are found there.
    func show(_ link: PaperLink) {
        guard let document = controller.document, document.pageCount > 0 else { return }
        let place = place(of: link, in: document)
        controller.pdfView.highlightedSelections = place.words.map { [$0] }
        if let page = document.page(at: place.position.page) { controller.go(to: page, y: place.position.y) }
    }

    /// Where a link leads in a paper: its page, from the top or with the quoted words a little below the top (picked
    /// out in the accent) when they are found there.
    private func place(of link: PaperLink, in document: PDFDocument) -> (position: ReadingPosition, words: PDFSelection?) {
        let index = min(max(0, (link.page ?? 1) - 1), document.pageCount - 1)
        guard let quote = link.quote, let page = document.page(at: index),
              let found = PaperLink.find(quote, onPage: index, of: document) else {
            return (ReadingPosition(page: index, y: 0), nil)
        }
        let bounds = found.bounds(for: page)
        let top = PageGeometry(page).fraction(CGPoint(x: bounds.minX, y: bounds.maxY)).y
        found.color = Theme.accentUI.withAlphaComponent(0.35)
        return (ReadingPosition(page: index, y: min(1, max(0, top - 0.04))), found)
    }

    /// The paper's marks, page by page.
    func annotations() -> [Mark] { controller.allMarks() }

    func go(to mark: Mark) { controller.go(to: mark) }

    func delete(_ mark: Mark) { controller.delete(mark) }

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

}

struct ReaderPages: UIViewControllerRepresentable {
    let model: ReaderModel

    func makeUIViewController(context: Context) -> ReaderViewController { model.controller }
    func updateUIViewController(_ controller: ReaderViewController, context: Context) {}
}

/// A paper filling the screen, with search and page pictures in the bar, and the page number in the
/// corner (a tap goes to a page).
struct ReaderScreen: View {
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var showsSearch = false
    @State private var choosesPage = false
    @State private var showsMarks = false
    @State private var showsNotes = false
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// Another paper a link leads to, opened in place of this one.
    private let openOther: (Paper, PaperLink) -> Void

    init(paper: Paper, chat: String? = nil, link: PaperLink? = nil,
         openOther: @escaping (Paper, PaperLink) -> Void = { _, _ in }) {
        _model = StateObject(wrappedValue: ReaderModel(paper: paper, chat: chat, link: link))
        self.openOther = openOther
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // The pages run under the bar, which blurs them (see `ReaderViewController.pagesUnderTheBar`).
                ReaderPages(model: model).ignoresSafeArea()
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
                // The page being read, also while drawing; a tap goes to another page.
                if model.loaded {
                    Button {
                        choosesPage = true
                    } label: {
                        Text("\(model.page + 1) / \(model.pageCount)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Page \(model.page + 1) of \(model.pageCount)")
                    .accessibilityHint("Go to Page")
                    .popover(isPresented: $choosesPage) {
                        PagePicker(model: model) { choosesPage = false }
                    }
                    .padding(16)
                }
            }
            // The AI in a small window over the paper, moved and sized as the reader likes.
            .overlay {
                if model.showsAI { FloatingAiPanel(model: model) }
            }
            .navigationTitle(model.paper.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Pages first, then back to the library, as Preview has them.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.showsThumbnails.toggle()
                    } label: {
                        Label("Pages", systemImage: "sidebar.left")
                    }
                    .accessibilityAddTraits(model.showsThumbnails ? .isSelected : [])
                    .disabled(!model.loaded)
                }
                // Each in its own glass, as in Preview.
                if #available(iOS 26, *) { ToolbarSpacer(.fixed, placement: .topBarLeading) }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        close()
                    } label: {
                        Label("Library", systemImage: "chevron.backward")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    DrawButton(model: model)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.showsAI.toggle()
                    } label: {
                        Label("AI", systemImage: "sparkles")
                    }
                    .accessibilityAddTraits(model.showsAI ? .isSelected : [])
                    .disabled(!model.loaded)
                }
                if #available(iOS 26, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showsMarks = true
                    } label: {
                        Label("Annotations", systemImage: "highlighter")
                    }
                    .disabled(!model.loaded)
                    .popover(isPresented: $showsMarks) {
                        AnnotationList(model: model) { showsMarks = false }
                    }
                    Button {
                        showsNotes = true
                    } label: {
                        Label("Notes", systemImage: "note.text")
                    }
                    .disabled(!model.loaded)
                    .sheet(isPresented: $showsNotes) {
                        PaperNotes(paper: model.paper)
                            .modifier(links)
                            .environmentObject(store)
                            .presentationSizing(.page)
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
        // Links in the AI's answers and in notes: to a place in this paper, or (after asking) to another paper.
        .modifier(links)
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

    private var links: PaperLinks {
        PaperLinks(reading: model.paper) { link in
            showsNotes = false
            model.show(link)
        } open: { paper, link in
            showsNotes = false
            model.savePosition(to: store)
            openOther(paper, link)
        }
    }
}

/// Draw: while drawing, a filled accent circle, as Preview's Markup button.
private struct DrawButton: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        let button = Button {
            model.drawing.toggle()
        } label: {
            Label("Draw", systemImage: "pencil.tip.crop.circle")
        }
        .accessibilityAddTraits(model.drawing ? .isSelected : [])
        .disabled(!model.canDraw)
        if !model.drawing {
            button
        } else if #available(iOS 26, *) {
            button.buttonStyle(.glassProminent).buttonBorderShape(.circle).tint(Theme.accent)
        } else {
            button.buttonStyle(.borderedProminent).buttonBorderShape(.circle).tint(Theme.accent)
        }
    }
}

/// Go to Page: a page number, gone to with Return or Go.
private struct PagePicker: View {
    @ObservedObject var model: ReaderModel
    let done: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var target: Int? {
        Int(text.trimmingCharacters(in: .whitespaces)).flatMap { (1...max(1, model.pageCount)).contains($0) ? $0 : nil }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Page")
            TextField("\(model.page + 1)", text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .focused($focused)
                .onSubmit(go)
            Text("of \(model.pageCount)").foregroundStyle(.secondary).monospacedDigit()
            Button("Go", action: go)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(target == nil)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .onAppear { focused = true }
    }

    private func go() {
        guard let target else { return }
        model.go(toPage: target - 1)
        done()
    }
}

/// The paper's marks, page by page: a tap goes to one, a swipe deletes one (Undo brings it back).
private struct AnnotationList: View {
    @ObservedObject var model: ReaderModel
    let done: () -> Void
    @State private var marks: [Mark] = []

    var body: some View {
        Group {
            if marks.isEmpty {
                Text("No annotations yet. Select text to highlight or comment on it, or draw with Apple Pencil.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
            } else {
                List {
                    ForEach(marks) { mark in
                        Button {
                            model.go(to: mark)
                            done()
                        } label: {
                            AnnotationRow(mark: mark)
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { offsets in
                        for index in offsets { model.delete(marks[index]) }
                        marks.remove(atOffsets: offsets)
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 380, minHeight: marks.isEmpty ? 120 : 460)
        .onAppear { marks = model.annotations() }
    }
}

private struct AnnotationRow: View {
    let mark: Mark

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1).fill(Color(uiColor: mark.color)).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(mark.name).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("p. \(mark.page + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if !mark.text.isEmpty { Text(mark.text).font(.callout).lineLimit(3) }
                if !mark.body.isEmpty { Text(mark.body).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
            }
        }
        .padding(.vertical, 2)
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

/// The pen and the highlighter, their colors (the desktop's mark colors), the eraser, and Undo and Redo.
struct PenPalette: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        HStack(spacing: 12) {
            tool("Pen", "pencil.tip", chosen: { if case .pen = $0 { true } else { false } }, model.choosePen)
            tool("Highlighter", "highlighter", chosen: { if case .highlighter = $0 { true } else { false } },
                 model.chooseHighlighter)
            Divider().frame(height: 24)
            InkChoice(color: Binding(get: { model.ink }, set: { model.choose(color: $0) }))
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

    private func tool(_ name: String, _ symbol: String, chosen: (PenTool) -> Bool,
                      _ choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            Image(systemName: symbol).frame(width: 30, height: 30)
        }
        .foregroundStyle(chosen(model.tool) ? Theme.accent : Color.primary)
        .accessibilityLabel(name)
        .accessibilityAddTraits(chosen(model.tool) ? .isSelected : [])
    }
}
