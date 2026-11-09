import PDFKit
import UIKit

/// Highlights and comments on a selection of a page's text, as the desktop saves them (`saveTextSelection` in
/// src/ResearchStore.cpp): one row per page the selection crosses, with that page's text, a rectangle per line as
/// fractions of the page as shown, and the selection's character range on the page.
enum TextMarks {
    /// The color a highlight or comment made here gets: the last one chosen, at first the desktop's default ink.
    static let colorKey = "highlight.color"

    static var color: String {
        get {
            let saved = UserDefaults.standard.string(forKey: colorKey) ?? ""
            return PenTool.colors.contains(saved) ? saved : PenTool.colors[0]
        }
        set { if PenTool.colors.contains(newValue) { UserDefaults.standard.set(newValue, forKey: colorKey) } }
    }

    static func rows(for selection: PDFSelection, in document: PDFDocument, kind: String, color: String,
                     body: String = "") -> [(Row, PDFPage)] {
        // Lines by page, in the order of the pages.
        var pages: [PDFPage] = []
        var lines: [ObjectIdentifier: [PDFSelection]] = [:]
        for line in selection.selectionsByLine() {
            guard let page = line.pages.first, !(line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else { continue }
            if lines[ObjectIdentifier(page)] == nil { pages.append(page) }
            lines[ObjectIdentifier(page), default: []].append(line)
        }
        return pages.sorted { document.index(for: $0) < document.index(for: $1) }.compactMap { page in
            let onPage = lines[ObjectIdentifier(page)] ?? []
            let geometry = PageGeometry(page)
            let boxes = onPage.map { line -> CGRect in
                let bounds = line.bounds(for: page)
                let a = geometry.fraction(CGPoint(x: bounds.minX, y: bounds.minY))
                let b = geometry.fraction(CGPoint(x: bounds.maxX, y: bounds.maxY))
                return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            }
            let text = onPage.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: "\n")
            guard let row = SyncEngine.textMarkRow(
                id: UUID().uuidString.lowercased(), document: "", sha256: "", page: document.index(for: page),
                kind: kind, color: color, text: text, lines: boxes, range: range(of: selection, on: page),
                body: body, createdAt: "")
            else { return nil }
            return (row, page)
        }
    }

    /// The characters of the page the selection covers (from its first to past its last).
    static func range(of selection: PDFSelection, on page: PDFPage) -> NSRange {
        let ranges = (0..<selection.numberOfTextRanges(on: page)).map { selection.range(at: $0, on: page) }
            .filter { $0.location != NSNotFound && $0.length > 0 }
        guard let first = ranges.map(\.location).min(), let end = ranges.map(NSMaxRange).max() else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: first, length: end - first)
    }
}
