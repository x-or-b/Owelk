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

    /// Shown-page fractions → overlay points (turned with the page, so corners swap sides).
    func rect(_ fraction: CGRect) -> CGRect {
        let a = point(CGPoint(x: fraction.minX, y: fraction.minY)), b = point(CGPoint(x: fraction.maxX, y: fraction.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

/// The marks the overlay draws as shapes, which Core Animation keeps sharp at any zoom. PDFKit draws annotations at the
/// page's own resolution (one pixel per point, however far it is zoomed in), so a 2 pt pen line came out in blocks.
/// Text boxes and pictures PDFKit still draws (`MarkAnnotation`). The look is the desktop's: highlights tint at 28%,
/// comments and regions are outlined, the pen is 2 pt wide.
enum MarkShape {
    static func draws(_ kind: String) -> Bool { kind != "text" && kind != "image" }

    static func layer(_ mark: Mark, on geometry: OverlayGeometry) -> CAShapeLayer? {
        guard draws(mark.kind) else { return nil }
        let layer = CAShapeLayer()
        layer.name = mark.id
        let path = CGMutablePath()
        switch mark.kind {
        case "draw":
            path.addPath(MarkAnnotation.stroke(mark.drawing.map(geometry.point)))
            layer.strokeColor = mark.color.cgColor
            layer.fillColor = nil
            layer.lineWidth = 2
            layer.lineCap = .round
            layer.lineJoin = .round
        case "comment", "area":
            for rect in mark.rectangles {
                path.addPath(UIBezierPath(roundedRect: geometry.rect(rect), cornerRadius: 2).cgPath)
            }
            layer.strokeColor = mark.color.cgColor
            layer.fillColor = nil
            layer.lineWidth = 1.5
        default:
            for rect in mark.rectangles { path.addRect(geometry.rect(rect)) }
            layer.fillColor = mark.color.withAlphaComponent(0.28).cgColor
        }
        layer.path = path
        return layer
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
/// It takes only the Pencil: PencilKit's own selection gestures took fingers too, so a finger could not drag the
/// pages while drawing. Fingers pass to the page (scroll, zoom, select).
final class InkCanvas: PKCanvasView {
    private let ignored: UndoManager = {
        let manager = UndoManager()
        manager.disableUndoRegistration()
        return manager
    }()

    override var undoManager: UndoManager? { ignored }

    override func layoutSubviews() {
        super.layoutSubviews()
        Self.pencilOnly(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        Self.pencilOnly(self)
    }

    private static func pencilOnly(_ view: UIView) {
        let finger = UITouch.TouchType.direct.rawValue
        for recognizer in view.gestureRecognizers ?? [] where recognizer.allowedTouchTypes.contains(where: { $0.intValue == finger }) {
            recognizer.allowedTouchTypes = recognizer.allowedTouchTypes.filter { $0.intValue != finger }
        }
        view.subviews.forEach(pencilOnly)
    }
}

/// A page's overlay: its marks' shapes, and while drawing the Pencil's canvas over them. Touches the canvas does not
/// take go through to the page.
private final class SheetView: UIView {
    let marks = CALayer()
    var canvas: PKCanvasView? {
        didSet {
            // The same canvas stays where it is: taking it off mid-use would end what PencilKit is doing.
            guard oldValue !== canvas else { return }
            oldValue?.removeFromSuperview()
            if let canvas {
                canvas.frame = bounds
                addSubview(canvas)
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        layer.addSublayer(marks)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marks.frame = bounds
        CATransaction.commit()
        canvas?.frame = bounds
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// Apple Pencil and the marks over the pages. Each shown page's overlay draws the page's marks as shapes (`MarkShape`),
/// sharp at any zoom, from the `MarkAnnotation`s on the page, which stay there for taps and the eraser. While drawing, a
/// PencilKit canvas on each shown page takes the stroke while it is drawn (Pencil only; fingers scroll); lifted, it
/// becomes a pen mark like every other mark, so it looks as on the desktop. Canvases are made only for drawing and
/// overlays only for pages on screen, so reading scrolls as lightly as without them. The eraser takes pen marks under
/// the Pencil. Drawing, erasing and their Undo and Redo go into the reader's history, and each is reported: drawn, or
/// erased (true) and back (false).
@MainActor
final class PenLayer: NSObject, @preconcurrency PDFPageOverlayViewProvider, PKCanvasViewDelegate {
    @MainActor
    private final class Sheet {
        let view = SheetView()
        var canvas: PKCanvasView? { view.canvas }
        let page: PDFPage
        let index: Int
        let geometry: OverlayGeometry
        var clearing = false
        private var shapes: [ObjectIdentifier: CALayer] = [:]

        init(page: PDFPage, index: Int) {
            self.page = page
            self.index = index
            geometry = OverlayGeometry(page)
        }

        /// The shapes of the marks now on the page.
        func sync() {
            let marks = page.annotations.compactMap { $0 as? MarkAnnotation }.filter { MarkShape.draws($0.mark.kind) }
            let present = Set(marks.map(ObjectIdentifier.init))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (key, shape) in shapes where !present.contains(key) {
                shape.removeFromSuperlayer()
                shapes[key] = nil
            }
            for annotation in marks where shapes[ObjectIdentifier(annotation)] == nil {
                guard let shape = MarkShape.layer(annotation.mark, on: geometry) else { continue }
                view.marks.addSublayer(shape)
                shapes[ObjectIdentifier(annotation)] = shape
            }
            CATransaction.commit()
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
    /// Highlights and comments made here on the text (rows from `TextMarks`).
    var placed: (([Row]) -> Void)?

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
        if let sheet = sheets[ObjectIdentifier(page)] { return sheet.view }
        guard let document = view.document else { return nil }
        let sheet = Sheet(page: page, index: document.index(for: page))
        sheets[ObjectIdentifier(page)] = sheet
        apply(sheet)
        sheet.sync()
        return sheet.view
    }

    /// A page off screen lets its overlay go; PDFKit asks for a new one when the page comes back.
    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let sheet = sheets[ObjectIdentifier(page)], sheet.view === overlayView else { return }
        sheets[ObjectIdentifier(page)] = nil
    }

    private func makeCanvas() -> PKCanvasView {
        let canvas = InkCanvas()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false
        // Pages are paper-white in dark mode too, so ink keeps its own colors.
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = self
        // A canvas is a scroll view under the bar: it must not move its ink to keep clear of the bar.
        canvas.contentInsetAdjustmentBehavior = .never
        return canvas
    }

    /// Draws the marks now on a page (after marks were added to it or taken off).
    func refresh(_ page: PDFPage) { sheets[ObjectIdentifier(page)]?.sync() }

    func refreshAll() { sheets.values.forEach { $0.sync() } }

    /// The canvas over a page while drawing, once PDFKit has shown it.
    func canvas(on page: PDFPage) -> PKCanvasView? { sheets[ObjectIdentifier(page)]?.canvas }

    /// The marks drawn over a page, by ID.
    func shapes(on page: PDFPage) -> [String] {
        (sheets[ObjectIdentifier(page)]?.view.marks.sublayers ?? []).compactMap(\.name).sorted()
    }

    private func apply(_ sheet: Sheet) {
        guard drawing else {
            sheet.view.canvas = nil
            return
        }
        let canvas = sheet.canvas ?? makeCanvas()
        sheet.view.canvas = canvas
        if case let .pen(hex) = tool {
            canvas.tool = PKInkingTool(.monoline, color: UIColor(hex: hex) ?? .black, width: width)
            canvas.isUserInteractionEnabled = true
        } else {
            // The eraser is the reader's own (`erase(along:in:)`): the canvas lets the Pencil through.
            canvas.isUserInteractionEnabled = false
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
        sheet.sync()
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
        var touched: [PDFPage] = []
        for sample in samples {
            guard let page = view.page(for: sample, nearest: false) else { continue }
            let point = view.convert(sample, to: page)
            for case let mark as MarkAnnotation in page.annotations
                where mark.mark.kind == "draw" && mark.touches(point, reach: reach) {
                page.removeAnnotation(mark)
                erasing.append((mark, page))
                if !touched.contains(page) { touched.append(page) }
            }
        }
        touched.forEach(refresh)
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

    // MARK: Marks from the reader

    /// Highlights or comments made on the text: on their pages at once, reported, and one step in the history.
    func place(_ rows: [(Row, PDFPage)], named name: String) {
        let marks = rows.compactMap { row, page in
            Mark(row: row).map { (MarkAnnotation(mark: $0, geometry: PageGeometry(page), picture: nil), page) }
        }
        guard !marks.isEmpty else { return }
        for (annotation, page) in marks { page.addAnnotation(annotation) }
        Set(marks.map { ObjectIdentifier($0.1) }).forEach { sheets[$0]?.sync() }
        placed?(rows.map(\.0))
        undoManager?.registerUndo(withTarget: self) { $0.take(marks) }
        undoManager?.setActionName(name)
        changed?()
    }

    /// Marks deleted from the reader (any computer's): erased, as one step in the history.
    func remove(_ marks: [(MarkAnnotation, PDFPage)]) {
        guard !marks.isEmpty else { return }
        take(marks)
        undoManager?.setActionName("Delete")
    }

    private func take(_ marks: [(MarkAnnotation, PDFPage)]) {
        for (annotation, page) in marks { page.removeAnnotation(annotation) }
        Set(marks.map { ObjectIdentifier($0.1) }).forEach { sheets[$0]?.sync() }
        erased?(marks.map(\.0.mark.id), true)
        undoManager?.registerUndo(withTarget: self) { $0.give(marks) }
        changed?()
    }

    private func give(_ marks: [(MarkAnnotation, PDFPage)]) {
        for (annotation, page) in marks { page.addAnnotation(annotation) }
        Set(marks.map { ObjectIdentifier($0.1) }).forEach { sheets[$0]?.sync() }
        erased?(marks.map(\.0.mark.id), false)
        undoManager?.registerUndo(withTarget: self) { $0.take(marks) }
        changed?()
    }
}
