import PDFKit
import SwiftUI

/// A place in a paper that an answer or a note links to. The desktop writes `owelk://document/<ID>#page=N&q=<words>`
/// (its answers' page citations, its notes' paper links); the iPad's own citations are `owelk-page:N`, in the paper
/// being read.
struct PaperLink: Equatable {
    /// The paper's `documents.id`, or "" for the paper being read.
    let document: String
    /// The page, counted from 1 as written (nil: the paper itself).
    let page: Int?
    /// The words quoted there.
    let quote: String?

    init(document: String, page: Int?, quote: String?) {
        self.document = document
        self.page = page
        self.quote = quote
    }

    init?(_ url: URL) {
        if url.scheme == "owelk-page" {
            guard let page = Int(url.absoluteString.dropFirst("owelk-page:".count)) else { return nil }
            self.init(document: "", page: page, quote: nil)
            return
        }
        let document = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard url.scheme == "owelk", url.host == "document", !document.isEmpty else { return nil }
        var fields: [String: String] = [:]
        for part in (url.fragment(percentEncoded: true) ?? "").split(separator: "&") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard let name = pair.first else { continue }
            fields[String(name)] = pair.count > 1 ? String(pair[1]).removingPercentEncoding ?? "" : ""
        }
        let quote = fields["q"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(document: document, page: fields["page"].flatMap { Int($0) },
                  quote: quote?.isEmpty == false ? quote : nil)
    }

    /// The quoted words on a page (`index` from 0): all of them, or, where the page breaks them differently (lines,
    /// hyphens), their first eight or four words.
    static func find(_ quote: String, onPage index: Int, of document: PDFDocument) -> PDFSelection? {
        guard let page = document.page(at: index) else { return nil }
        let words = quote.split(whereSeparator: \.isWhitespace).map(String.init)
        var tries = [words.joined(separator: " ")]
        for count in [8, 4] where words.count > count { tries.append(words.prefix(count).joined(separator: " ")) }
        for text in tries where !text.isEmpty {
            let found = document.findString(text, withOptions: [.caseInsensitive, .diacriticInsensitive])
            if let match = found.first(where: { $0.pages.contains(page) }) { return match }
        }
        return nil
    }
}

/// Follows links to places in papers, in answers and notes. In the paper being read, the place is shown; a link to
/// another paper asks before leaving this one. In the library (no paper being read) the paper opens at the place.
/// Other links open as usual.
struct PaperLinks: ViewModifier {
    @EnvironmentObject private var store: LibraryStore
    /// The paper being read (nil in the library).
    let reading: Paper?
    let show: (PaperLink) -> Void
    let open: (Paper, PaperLink) -> Void
    @State private var leaving: Leaving?

    struct Leaving {
        let paper: Paper?
        let link: PaperLink
    }

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard let link = PaperLink(url) else { return .systemAction }
                follow(link)
                return .handled
            })
            .alert(title, isPresented: Binding { leaving != nil } set: { if !$0 { leaving = nil } },
                   presenting: leaving) { leaving in
                if let paper = leaving.paper {
                    Button("Cancel", role: .cancel) {}
                    Button("Open") { open(paper, leaving.link) }
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { leaving in
                Text(message(leaving))
            }
    }

    private func follow(_ link: PaperLink) {
        let target = link.document.isEmpty ? reading : store.library.paperOf[link.document].flatMap { id in
            store.library.papers.first { $0.id == id }
        }
        if let target, target.id == reading?.id {
            show(link)
        } else if let target, reading == nil {
            open(target, link)
        } else {
            leaving = Leaving(paper: target, link: link)
        }
    }

    private var title: String {
        guard let leaving else { return "" }
        guard let paper = leaving.paper else { return "Paper Not in the Library" }
        return "Open “\(paper.title)”?"
    }

    private func message(_ leaving: Leaving) -> String {
        guard let paper = leaving.paper else {
            return "This link goes to a paper that isn't in the library on this iPad."
        }
        let place = leaving.link.page.map { "page \($0) of another paper" } ?? "another paper"
        let arrived = paper.hasFile ? "" : " Its PDF hasn't arrived on this iPad yet."
        return "This link goes to \(place). The paper you're reading keeps your place." + arrived
    }
}
