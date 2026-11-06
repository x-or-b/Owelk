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

/// PencilKit's monoline ink: a stroke point of size `s` is drawn about `2s − 3.5` pt wide (measured, and checked by
/// `PenTests`), and a tool's width becomes point sizes its own way. So the tool's width is corrected from each stroke
/// drawn, until the ink comes out 2 pt wide, as the desktop draws the pen.
enum InkWidth {
    static let pointSize: CGFloat = 2.75
    static let key = "pen.inkWidth"
    /// Width 2 drew points of about 3.4 on an iPad Air.
    static let first: CGFloat = 1.63

    static func corrected(_ width: CGFloat, drew size: CGFloat) -> CGFloat {
        guard size.isFinite, size > 0 else { return width }
        let factor = min(2, max(0.5, pointSize / size))
        return min(4, max(0.5, width * factor))
    }
}

/// A canvas that keeps no undo history of its own: strokes leave it at once, and the reader's history has them.
private final class InkCanvas: PKCanvasView {
    private let ignored: UndoManager = {
        let manager = UndoManager()
        manager.disableUndoRegistration()
        return manager
    }()

    override var undoManager: UndoManager? { ignored }
}

/// Apple Pencil over the pages. A PencilKit canvas on each page takes the stroke while it is drawn (Pencil only;
/// fingers scroll); lifted, it becomes a pen mark drawn by PDFKit like every other mark, so it looks as on the
/// desktop and stays sharp at any zoom. The eraser takes pen marks under the Pencil. Drawing, erasing and their Undo
/// and Redo go into the reader's history, and each is reported: drawn, or erased (true) and back (false).
@MainActor
final class PenLayer: NSObject, @preconcurrency PDFPageOverlayViewProvider, PKCanvasViewDelegate {
    @MainActor
    private final class Sheet {
        let canvas: PKCanvasView = InkCanvas()
        let page: PDFPage
        let index: Int
        let geometry: OverlayGeometry
        var clearing = false

        init(page: PDFPage, index: Int) {
            self.page = page
            self.index = index
            geometry = OverlayGeometry(page)
        }
    }

    private var sheets: [ObjectIdentifier: Sheet] = [:]
    private var width: CGFloat
    /// Marks taken by the eraser stroke under way.
    private var erasing: [(MarkAnnotation, PDFPage)] = []

    /// The reader's undo history.
    weak var undoManager: UndoManager?
    /// A stroke drawn: its page, new mark ID, points (shown-page fractions) and color.
    var drawn: ((Int, String, [CGPoint], String) -> Void)?
    /// Marks erased (true) or back (false).
    var erased: (([String], Bool) -> Void)?
    /// After any change, for the Undo and Redo buttons.
    var changed: (() -> Void)?

    var tool = PenTool.pen(PenTool.colors[0]) {
        didSet { sheets.values.forEach(apply) }
    }

    var drawing = false {
        didSet { sheets.values.forEach(apply) }
    }

    override init() {
        let saved = CGFloat(UserDefaults.standard.double(forKey: InkWidth.key))
        width = (0.5...4).contains(saved) ? saved : InkWidth.first
        super.init()
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        if let sheet = sheets[ObjectIdentifier(page)] { return sheet.canvas }
        guard let document = view.document else { return nil }
        let sheet = Sheet(page: page, index: document.index(for: page))
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
        return canvas
    }

    private func apply(_ sheet: Sheet) {
        if case let .pen(hex) = tool {
            sheet.canvas.tool = PKInkingTool(.monoline, color: UIColor(hex: hex) ?? .black, width: width)
            sheet.canvas.isUserInteractionEnabled = drawing
        } else {
            // The eraser is the reader's own (`erase(along:in:)`): the canvas lets the Pencil through.
            sheet.canvas.isUserInteractionEnabled = false
        }
    }

    // MARK: Drawing

    func canvasViewDrawingDidChange(_ canvas: PKCanvasView) {
        guard let sheet = sheets.values.first(where: { $0.canvas === canvas }), !sheet.clearing,
              let stroke = canvas.drawing.strokes.last
        else { return }
        let sizes = stroke.path.map(\.size.width).sorted()
        // Every 2 pt: as fine as the 2 pt line the desktop draws through them.
        let points = stroke.path.interpolatedPoints(by: .distance(2)).map {
            sheet.geometry.fraction($0.location.applying(stroke.transform))
        }
        sheet.clearing = true
        canvas.drawing = PKDrawing()
        sheet.clearing = false
        if !sizes.isEmpty {
            width = InkWidth.corrected(width, drew: sizes[sizes.count / 2])
            UserDefaults.standard.set(Double(width), forKey: InkWidth.key)
            sheets.values.forEach(apply)
        }
        let id = UUID().uuidString.lowercased(), color = PenTool.hex(nearest: stroke.ink.color)
        // Drawn as it is written: the same rounded points the computers get.
        guard let row = SyncEngine.strokeRow(id: id, document: "", sha256: "", page: sheet.index, points: points,
                                             color: color, createdAt: ""),
              let mark = Mark(row: row)
        else { return }
        let annotation = MarkAnnotation(mark: mark, geometry: PageGeometry(sheet.page), picture: nil)
        sheet.page.addAnnotation(annotation)
        drawn?(sheet.index, id, points, color)
        undoManager?.registerUndo(withTarget: self) { $0.take([(annotation, sheet.page)]) }
        undoManager?.setActionName("Pen")
        changed?()
    }

    // MARK: Erasing

    /// The eraser moving over the pages through `points` (in `view`): pen marks within reach go.
    func erase(along points: [CGPoint], in view: PDFView) {
        let reach = 8 / max(0.1, view.scaleFactor)
        var samples: [CGPoint] = []
        for (a, b) in zip(points, points.dropFirst() + [points.last ?? .zero]) {
            let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 4))
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                samples.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        for sample in samples {
            guard let page = view.page(for: sample, nearest: false) else { continue }
            let point = view.convert(sample, to: page)
            for case let mark as MarkAnnotation in page.annotations
                where mark.mark.kind == "draw" && mark.touches(point, reach: reach) {
                page.removeAnnotation(mark)
                erasing.append((mark, page))
            }
        }
    }

    /// The eraser lifted: what it took is erased, as one step.
    func finishErasing() {
        let taken = erasing
        erasing = []
        guard !taken.isEmpty else { return }
        erased?(taken.map(\.0.mark.id), true)
        undoManager?.registerUndo(withTarget: self) { $0.give(taken) }
        undoManager?.setActionName("Erase")
        changed?()
    }

    private func take(_ marks: [(MarkAnnotation, PDFPage)]) {
        for (annotation, page) in marks { page.removeAnnotation(annotation) }
        erased?(marks.map(\.0.mark.id), true)
        undoManager?.registerUndo(withTarget: self) { $0.give(marks) }
        changed?()
    }

    private func give(_ marks: [(MarkAnnotation, PDFPage)]) {
        for (annotation, page) in marks { page.addAnnotation(annotation) }
        erased?(marks.map(\.0.mark.id), false)
        undoManager?.registerUndo(withTarget: self) { $0.take(marks) }
        changed?()
    }
}
