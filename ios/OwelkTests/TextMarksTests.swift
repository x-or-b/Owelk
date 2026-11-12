import PDFKit
import XCTest
@testable import Owelk

/// Highlights and comments on the text, made in the reader.
@MainActor
final class TextMarksTests: XCTestCase {
    private func reader() async throws -> (ReaderViewController, UIWindow, PDFDocument) {
        let document = try XCTUnwrap(PDFDocument(url: ConformanceTests.addedPdf))
        let controller = ReaderViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 820, height: 1180))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.document = document
        controller.marksAllowed = true
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        return (controller, window, document)
    }

    /// A selection becomes one row per page with the page's text, a rectangle per line where PDFKit shows the text,
    /// and the characters it covers.
    func testASelectionIsWrittenAsTheDesktopWritesOne() throws {
        let document = try XCTUnwrap(PDFDocument(url: ConformanceTests.addedPdf))
        let selection = try XCTUnwrap(document.findString("second paper", withOptions: []).first)
        let page = try XCTUnwrap(selection.pages.first)
        let rows = TextMarks.rows(for: selection, in: document, kind: "highlight", color: "#e0b83f")
        XCTAssertEqual(rows.count, 1)
        let (row, on) = try XCTUnwrap(rows.first)
        XCTAssertTrue(on === page)
        XCTAssertEqual(row.string("kind"), "highlight")
        XCTAssertEqual(row.string("text"), "second paper")
        XCTAssertEqual(row.int("end_index") - row.int("start_index"), 12)
        let mark = try XCTUnwrap(Mark(row: row))
        XCTAssertEqual(mark.rectangles.count, 1)
        let shown = PageGeometry(page).rect(try XCTUnwrap(mark.rectangles.first))
        let text = selection.bounds(for: page)
        XCTAssertEqual(shown.midX, text.midX, accuracy: 0.5)
        XCTAssertEqual(shown.midY, text.midY, accuracy: 0.5)
        XCTAssertEqual(shown.width, text.width, accuracy: 0.5)

        // Two lines: a rectangle each.
        let from = try XCTUnwrap(document.findString("Echoes", withOptions: []).first)
        let to = try XCTUnwrap(document.findString("iPad.", withOptions: []).first)
        let span = try XCTUnwrap(from.copy() as? PDFSelection)
        span.add(to)
        span.extendForLineBoundaries()
        let both = TextMarks.rows(for: span, in: document, kind: "comment", color: "#426b9a", body: "Why?")
        XCTAssertEqual(both.count, 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(Mark(row: both[0].0)).rectangles.count, 2)
        XCTAssertEqual(both[0].0.string("body"), "Why?")
        XCTAssertTrue(TextMarks.rows(for: span, in: document, kind: "comment", color: "#426b9a", body: " ").isEmpty,
                      "a comment needs its note")
    }

    /// The menu of selected text (UIKit builds it through the responder chain, for the context system, and
    /// `PageView.buildMenu` puts these beside Copy) offers Highlight and Comment… while text is selected, once marks
    /// can be made.
    func testTheSelectionMenuOffersHighlightAndComment() async throws {
        let (controller, window, document) = try await reader()
        defer { window.isHidden = true }
        func offered() -> [String] { (controller.pdfView.selectionActions?() ?? []).compactMap { ($0 as? UIAction)?.title } }
        XCTAssertEqual(offered(), [], "nothing selected")
        let selection = try XCTUnwrap(document.findString("second paper", withOptions: []).first)
        controller.pdfView.setCurrentSelection(selection, animate: false)
        XCTAssertEqual(offered(), ["Highlight", "Comment…"])
        controller.onExplain = { _ in }
        XCTAssertEqual(offered(), ["Highlight", "Comment…", "Explain", "Ask AI…"], "and the AI's")
        controller.marksAllowed = false
        XCTAssertEqual(offered(), ["Explain", "Ask AI…"], "no marks where the paper's PDF is unknown")
    }

    /// With the highlighter, the Pencil going along a line selects the text it passes over, and lifting it highlights
    /// that text in the highlighter's color (once, as one step).
    func testTheHighlighterHighlightsTheTextItPassesOver() async throws {
        let (controller, window, document) = try await reader()
        defer { window.isHidden = true }
        var placed: [Row] = []
        controller.pen.placed = { placed += $0 }
        controller.drawing = true
        controller.pen.tool = .highlighter("#54a878")
        let selection = try XCTUnwrap(document.findString("second paper", withOptions: []).first)
        let page = try XCTUnwrap(selection.pages.first)
        let text = controller.pdfView.convert(selection.bounds(for: page), from: page)
        controller.beginMarking(at: CGPoint(x: text.minX + 2, y: text.midY))
        controller.markText(to: CGPoint(x: text.midX, y: text.midY))
        XCTAssertNotNil(controller.pdfView.currentSelection, "selected as it goes")
        controller.markText(to: CGPoint(x: text.maxX - 2, y: text.midY))
        controller.finishMarking()
        XCTAssertEqual(placed.count, 1)
        XCTAssertEqual(placed.first?.string("kind"), "highlight")
        XCTAssertEqual(placed.first?.string("color"), "#54a878")
        XCTAssertTrue(placed.first?.string("text").contains("second pape") ?? false, placed.first?.string("text") ?? "")
        XCTAssertNil(controller.pdfView.currentSelection)
        controller.finishMarking()
        XCTAssertEqual(placed.count, 1, "lifting again makes nothing")
    }

    /// Highlight puts the mark on the page at once and reports it; Undo takes it off (erased), Redo brings it back.
    /// The list of the paper's marks runs page by page, and deleting from it is one step Undo reverses.
    func testHighlightingIsOneStepAndListed() async throws {
        let (controller, window, document) = try await reader()
        defer { window.isHidden = true }
        var placed: [Row] = [], erased: [([String], Bool)] = []
        controller.pen.placed = { placed += $0 }
        controller.pen.erased = { erased.append(($0, $1)) }
        let history = try XCTUnwrap(controller.undoManager)
        let selection = try XCTUnwrap(document.findString("second paper", withOptions: []).first)
        controller.pdfView.setCurrentSelection(selection, animate: false)
        controller.highlightSelection()
        XCTAssertEqual(placed.count, 1)
        let id = placed[0].string("id")
        XCTAssertNil(controller.pdfView.currentSelection, "the selection is done with")
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(controller.pen.shapes(on: page), [id])
        XCTAssertEqual(controller.allMarks().map(\.id), [id])
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        history.undo()
        XCTAssertEqual(erased.last?.0, [id])
        XCTAssertEqual(erased.last?.1, true)
        XCTAssertTrue(controller.allMarks().isEmpty)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        history.redo()
        XCTAssertEqual(controller.allMarks().map(\.id), [id])
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        let mark = try XCTUnwrap(controller.allMarks().first)
        controller.delete(mark)
        XCTAssertTrue(controller.allMarks().isEmpty)
        XCTAssertEqual(controller.pen.shapes(on: page), [])
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        history.undo()
        XCTAssertEqual(controller.allMarks().map(\.id), [id])
        XCTAssertEqual(placed.count, 1, "made once")

        // Its editor's color and note: drawn again with them, and reported once.
        var changed: [(String, String, String)] = []
        controller.onMarkChanged = { changed.append(($0, $1, $2)) }
        let annotation = try XCTUnwrap(page.annotations.compactMap { $0 as? MarkAnnotation }.first)
        controller.change(annotation, on: page, color: "#54a878", body: "Read the proof")
        controller.change(annotation, on: page, color: "#54a878", body: "Read the proof")
        XCTAssertEqual(changed.map(\.0), [id])
        XCTAssertEqual(changed.first?.1, "#54a878")
        XCTAssertEqual(controller.allMarks().first?.body, "Read the proof")
        XCTAssertEqual(PenTool.hex(nearest: try XCTUnwrap(controller.allMarks().first).color), "#54a878")
        XCTAssertEqual(controller.pen.shapes(on: page), [id])
    }
}
