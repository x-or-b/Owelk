import SwiftUI
import WebKit

/// Web search engines, as the desktop's built-in ones (qml/WebSearch.js): `%s` stands for the words.
enum SearchEngine: String, CaseIterable, Identifiable {
    case scholar = "Google Scholar", arxiv = "arXiv", google = "Google", duckDuckGo = "DuckDuckGo"

    var id: String { rawValue }

    var template: String {
        switch self {
        case .scholar: "https://scholar.google.com/scholar?q=%s"
        case .arxiv: "https://arxiv.org/search/?query=%s&searchtype=all"
        case .google: "https://www.google.com/search?q=%s"
        case .duckDuckGo: "https://duckduckgo.com/?q=%s"
        }
    }

    /// The engine's own page, where a new search starts (as a new web tab does on the desktop).
    var home: URL {
        switch self {
        case .scholar: URL(string: "https://scholar.google.com")!
        case .arxiv: URL(string: "https://arxiv.org")!
        case .google: URL(string: "https://www.google.com")!
        case .duckDuckGo: URL(string: "https://duckduckgo.com")!
        }
    }

    func search(_ words: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = words.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    /// What was typed in the address field: an address, a DOI or arXiv ID (opened where it lives), or words to search.
    func address(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.range(of: #"^10\.\d{4,9}/\S+$"#, options: .regularExpression) != nil {
            return URL(string: "https://doi.org/" + text)
        }
        if text.range(of: #"^\d{4}\.\d{4,5}(v\d+)?$"#, options: .regularExpression) != nil {
            return URL(string: "https://arxiv.org/abs/" + text)
        }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
           url.host != nil {
            return url
        }
        if !text.contains(" "), let url = URL(string: "https://" + text), let host = url.host,
           host.split(separator: ".").last.map({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }) == true {
            return url
        }
        return search(text)
    }

    /// The PDF of an arXiv abstract page, as the desktop's `arxivPdf`.
    static func arxivPdf(_ url: URL?) -> URL? {
        guard let text = url?.absoluteString,
              let match = text.range(of: #"^https?://(www\.)?arxiv\.org/abs/[^?#]+"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let id = text[match].split(separator: "/", omittingEmptySubsequences: false).dropFirst(4).joined(separator: "/")
        return id.isEmpty ? nil : URL(string: "https://arxiv.org/pdf/" + id)
    }
}

/// A web page for finding papers, as the desktop's web tab: a page that shows a PDF can be added to the Library, and a
/// PDF a link downloads is added at once. Sign-ins (a university's access to publishers) stay between launches.
@MainActor
final class WebPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView
    @Published private(set) var url: URL?
    @Published private(set) var loading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// The PDF the page shows, when it shows one.
    @Published private(set) var pdf: URL?
    @Published private(set) var downloads = 0
    /// A downloaded file, to add to the Library.
    var received: ((LibraryStore.Incoming) -> Void)?
    /// Something to say that is not about a paper (a download that failed, a file that is not a PDF).
    var problem: ((String) -> Void)?

    private var responsePdf: URL?
    private var destinations: [ObjectIdentifier: URL] = [:]
    private var observations: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
            webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.loading = view.isLoading } },
            webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.url = view.url } },
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
        ]
    }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }

    /// Adds the PDF the page shows; it is fetched again with the page's sign-ins.
    func addShownPdf() {
        guard let pdf else { return }
        downloads += 1
        webView.startDownload(using: URLRequest(url: pdf)) { [weak self] download in download.delegate = self }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data"].contains(scheme) {
            UIApplication.shared.open(url) // mailto: and the like go to their own apps.
            return decisionHandler(.cancel)
        }
        decisionHandler(action.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        // A file the page hands over rather than shows: downloaded, and added when it is a PDF.
        if !response.canShowMIMEType || disposition.lowercased().hasPrefix("attachment") {
            return decisionHandler(.download)
        }
        if response.isForMainFrame {
            responsePdf = response.response.mimeType?.lowercased() == "application/pdf" ? response.response.url : nil
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pdf = responsePdf
        responsePdf = nil
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloads += 1
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloads += 1
        download.delegate = self
    }

    /// Links that open a new window open here.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }

    // MARK: Downloads

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = SyncProtocol.isPlainName(suggestedFilename) ? suggestedFilename : "Paper.pdf"
        let url = folder.appendingPathComponent(name)
        destinations[ObjectIdentifier(download)] = url
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloads = max(0, downloads - 1)
        guard let url = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        if let data, data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil {
            received?(LibraryStore.Incoming(name: url.lastPathComponent, data: data))
        } else {
            problem?("“\(url.lastPathComponent)” is not a PDF; only PDFs go into the Library.")
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads = max(0, downloads - 1)
        if let url = destinations.removeValue(forKey: ObjectIdentifier(download)) {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        problem?("The download did not finish: \(error.localizedDescription)")
    }
}

private struct WebView: UIViewRepresentable {
    let page: WebPage
    func makeUIView(context: Context) -> WKWebView { page.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// Finding papers on the web: the address field searches the chosen engine (or opens an address, DOI or arXiv ID).
struct WebSearchScreen: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var page = WebPage()
    @AppStorage("web.engine") private var engineName = SearchEngine.scholar.rawValue
    @State private var address = ""
    @FocusState private var typing: Bool
    /// Where added papers go (the collection or tag shown in the library), and the paper to open after closing.
    let collection: String?
    let tag: String?
    @Binding var openAfter: Paper?

    private var engine: SearchEngine { SearchEngine(rawValue: engineName) ?? .scholar }

    var body: some View {
        NavigationStack {
            WebView(page: page)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    if page.loading {
                        ProgressView(value: page.progress).tint(Theme.accent).progressViewStyle(.linear)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { bar }
                .overlay(alignment: .bottom) {
                    NoticeBar { paper in
                        openAfter = paper
                        dismiss()
                    }
                    .padding(.bottom, page.pdf != nil || SearchEngine.arxivPdf(page.url) != nil ? 56 : 0)
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .onAppear {
            page.received = { [collection, tag] incoming in
                Task { await store.add([incoming], collection: collection, tag: tag) }
            }
            page.problem = { store.notice = .init(text: $0, failed: true) }
            if page.url == nil { page.load(engine.home) }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button("Done") { dismiss() }
            Button { page.webView.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                .disabled(!page.canGoBack)
            Button { page.webView.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                .disabled(!page.canGoForward)
        }
        ToolbarItem(placement: .principal) {
            TextField("Search \(engine.rawValue) or type an address", text: $address)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($typing)
                .frame(minWidth: 320, idealWidth: 560, maxWidth: 640)
                .onSubmit {
                    if let url = engine.address(address) { page.load(url) }
                    typing = false
                }
                .onChange(of: typing) { _, now in if now { address = page.url?.absoluteString ?? "" } }
                .onChange(of: page.url) { _, url in if !typing { address = url?.absoluteString ?? "" } }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("Search With", selection: $engineName) {
                    ForEach(SearchEngine.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
            } label: {
                Label("Search Engine", systemImage: "magnifyingglass")
            }
            .onChange(of: engineName) { _, _ in page.load(engine.home) }
            Button {
                if page.loading { page.webView.stopLoading() } else { page.webView.reload() }
            } label: {
                Label(page.loading ? "Stop" : "Reload", systemImage: page.loading ? "xmark" : "arrow.clockwise")
            }
        }
    }

    /// A page that shows a PDF: add it. An arXiv abstract: open its PDF.
    @ViewBuilder
    private var bar: some View {
        if page.pdf != nil || SearchEngine.arxivPdf(page.url) != nil || page.downloads > 0 {
            HStack(spacing: 12) {
                if page.downloads > 0 {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").foregroundStyle(.secondary)
                } else if page.pdf != nil {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text("This page is a PDF.").foregroundStyle(.secondary)
                } else {
                    Text("An arXiv paper.").foregroundStyle(.secondary)
                }
                Spacer()
                if let pdf = SearchEngine.arxivPdf(page.url), page.pdf == nil {
                    Button("Open PDF") { page.load(pdf) }.buttonStyle(.bordered).tint(.primary)
                }
                if page.pdf != nil {
                    Button("Add to Library") { page.addShownPdf() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .disabled(page.downloads > 0)
                }
            }
            .font(.callout)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }
}
