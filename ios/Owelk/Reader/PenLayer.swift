import PDFKit
import PencilKit
import UIKit

/// What Apple Pencil does on a page: draw in one of the desktop's mark colors, or erase whole strokes.
enum PenTool: Equatable {
    case pen(String)
    case eraser

    /// The desktop's mark colors (`ResearchStore::annotationColors`), the default first.
    static let colors = ["#426b9a", "#e0b83f", "#54a878", "#d87797", "#9274c3", "#1d3a5c"]

    /// The mark color nearest to a color (a stroke keeps its ink's color).
    static func hex(nearest color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return colors.min { distance($0, r, g, b) < distance($1, r, g, b) } ?? colors[0]
    }

    private static func distance(_ hex: String, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
        var x: CGFloat = 0, y: CGFloat = 0, z: CGFloat = 0, a: CGFloat = 0
        (UIColor(hex: hex) ?? .black).getRed(&x, green: &y, blue: &z, alpha: &a)
        return (x - r) * (x - r) + (y - g) * (y - g) + (z - b) * (z - b)
    }
}

/// A page's overlay as PDFKit lays it out: the page unturned, in points from its crop box's top left (PDFKit turns
/// the view itself for /Rotate). Owelk keeps places as fractions of the page as shown.
struct OverlayGeometry {
    let crop: CGRect
    let shown: PageGeometry

    init(crop: CGRect, rotation: Int) {
        self.crop = crop
        shown = PageGeometry(box: crop, rotation: rotation)
    }

    init(_ page: PDFPage) { self.init(crop: page.bounds(for: .cropBox), rotation: page.rotation) }

    func fraction(_ point: CGPoint) -> CGPoint {
        shown.fraction(CGPoint(x: crop.minX + point.x, y: crop.maxY - point.y))
    }

    func point(_ fraction: CGPoint) -> CGPoint {
        let page = shown.point(fraction)
        return CGPoint(x: page.x - crop.minX, y: crop.maxY - page.y)
    }
}

/// Apple Pencil's ink over the pages: one PencilKit canvas per page (kept while the paper is open, so Undo reaches
/// pages scrolled away), holding the computers' pen marks and the strokes drawn here. Pencil draws and fingers
/// scroll; with drawing off the canvases let every touch through. What changes is reported per stroke: drawn,
/// erased, or back after Undo.
@MainActor
final class PenLayer: NSObject, @preconcurrency PDFPageOverlayViewProvider, PKCanvasViewDelegate {
    @MainActor
    private final class Sheet {
        let canvas = PKCanvasView()
        let index: Int
        let geometry: OverlayGeometry
        /// Stroke (by its creation date) → mark ID.
        var marks: [Double: String] = [:]
        var erased: Set<String> = []
        var loading = false

        init(index: Int, geometry: OverlayGeometry) {
            self.index = index
            self.geometry = geometry
        }
    }

    private var sheets: [ObjectIdentifier: Sheet] = [:]
    private var strokes: [Int: [Mark]] = [:]
    /// Creation dates for the computers' strokes, which have none: far in the past, one each.
    private var nextDate = -1_000_000.0

    /// A stroke drawn: its page, new mark ID, points (shown-page fractions) and color.
    var drawn: ((Int, String, [CGPoint], String) -> Void)?
    /// Marks erased (true) or back after Undo (false).
    var erased: (([String], Bool) -> Void)?
    /// After any change, for the Undo and Redo buttons.
    var changed: (() -> Void)?

    var tool = PenTool.pen(PenTool.colors[0]) {
        didSet { sheets.values.forEach(apply) }
    }

    var drawing = false {
        didSet { sheets.values.forEach(apply) }
    }

    /// The undo history the canvases share (the reader's).
    var undoManager: UndoManager? { sheets.values.lazy.compactMap { $0.canvas.undoManager }.first }

    /// The computers' pen marks, drawn on the canvases (other marks stay page annotations).
    func show(_ marks: [Mark]) {
        strokes = Dictionary(grouping: marks.filter { $0.kind == "draw" && $0.drawing.count >= 2 }, by: \.page)
        sheets.values.forEach(load)
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        if let sheet = sheets[ObjectIdentifier(page)] { return sheet.canvas }
        guard let document = view.document else { return nil }
        let sheet = Sheet(index: document.index(for: page), geometry: OverlayGeometry(page))
        let canvas = sheet.canvas
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false
        // Pages are paper-white in dark mode too, so ink keeps its own colors.
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = self
        sheets[ObjectIdentifier(page)] = sheet
        apply(sheet)
        load(sheet)
        return canvas
    }

    private func apply(_ sheet: Sheet) {
        switch tool {
        case let .pen(hex): sheet.canvas.tool = PKInkingTool(.monoline, color: UIColor(hex: hex) ?? .black, width: 2)
        case .eraser: sheet.canvas.tool = PKEraserTool(.vector)
        }
        sheet.canvas.isUserInteractionEnabled = drawing
    }

    private func load(_ sheet: Sheet) {
        var drawing = PKDrawing()
        sheet.marks = [:]
        sheet.erased = []
        for mark in strokes[sheet.index] ?? [] {
            let date = Date(timeIntervalSinceReferenceDate: nextDate)
            nextDate -= 1
            sheet.marks[date.timeIntervalSinceReferenceDate] = mark.id
            drawing.strokes.append(Self.stroke(mark.drawing.map(sheet.geometry.point), color: mark.color, date: date))
        }
        sheet.loading = true
        sheet.canvas.drawing = drawing
        sheet.loading = false
    }

    /// A stroke through points on the overlay, 2 pt wide as the desktop draws the pen.
    static func stroke(_ points: [CGPoint], color: UIColor, date: Date) -> PKStroke {
        let samples = points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.01, size: CGSize(width: 2, height: 2),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.monoline, color: color), path: PKStrokePath(controlPoints: samples, creationDate: date))
    }

    func canvasViewDrawingDidChange(_ canvas: PKCanvasView) {
        guard let sheet = sheets.values.first(where: { $0.canvas === canvas }), !sheet.loading else { return }
        var seen = Set<Double>(), back: [String] = []
        for stroke in canvas.drawing.strokes {
            let key = stroke.path.creationDate.timeIntervalSinceReferenceDate
            seen.insert(key)
            if let id = sheet.marks[key] {
                if sheet.erased.remove(id) != nil { back.append(id) }
                continue
            }
            let id = UUID().uuidString.lowercased()
            sheet.marks[key] = id
            // Every 2 pt: as fine as the 2 pt line the desktop draws through them.
            let points = stroke.path.interpolatedPoints(by: .distance(2)).map {
                sheet.geometry.fraction($0.location.applying(stroke.transform))
            }
            drawn?(sheet.index, id, points, PenTool.hex(nearest: stroke.ink.color))
        }
        let gone = sheet.marks.filter { !seen.contains($0.key) && !sheet.erased.contains($0.value) }.map(\.value)
        sheet.erased.formUnion(gone)
        if !back.isEmpty { erased?(back, false) }
        if !gone.isEmpty { erased?(gone, true) }
        changed?()
    }
}
