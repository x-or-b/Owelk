import PDFKit
import UIKit

/// What Apple Pencil does on a page: draw in one of the desktop's mark colors, highlight the text it passes over
/// (a highlight on the text, as the desktop's), or erase whole strokes.
enum PenTool: Equatable {
    case pen(String)
    case highlighter(String)
    case eraser

    /// The color of the pen or highlighter.
    var ink: String? {
        switch self {
        case let .pen(hex), let .highlighter(hex): hex
        case .eraser: nil
        }
    }

    /// The same tool with another color (the eraser stays the eraser).
    func with(_ hex: String) -> PenTool {
        switch self {
        case .pen: .pen(hex)
        case .highlighter: .highlighter(hex)
        case .eraser: .eraser
        }
    }

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

/// A page's overlay: its marks' shapes, and the stroke being drawn over them. It takes no touches: the reader's
/// Pencil gestures and the page's own do.
private final class SheetView: UIView {
    let marks = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        layer.addSublayer(marks)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marks.frame = bounds
        CATransaction.commit()
    }
}

/// Apple Pencil and the marks over the pages. Each shown page's overlay draws the page's marks as shapes (`MarkShape`),
/// sharp at any zoom, from the `MarkAnnotation`s on the page, which stay there for taps and the eraser. A stroke is
/// drawn as it goes by the same kind of shape, 2 pt wide as the desktop's pen (PencilKit drew it into tiles two pixels
/// to a point, so it blurred under PDFKit's zoom until it was lifted); lifted, it becomes a pen mark like every other
/// mark. Overlays are made only for pages on screen, so reading scrolls lightly. The eraser takes pen marks under the
/// Pencil. Drawing, erasing and their Undo and Redo go into the reader's history, and each is reported: drawn, or
/// erased (true) and back (false).
@MainActor
final class PenLayer: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    @MainActor
    private final class Sheet {
        let view = SheetView()
        let page: PDFPage
        let index: Int
        let geometry: OverlayGeometry
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

    /// The stroke being drawn: its page, its points in the page's overlay, and the shape showing them.
    private struct Stroke {
        let sheet: Sheet
        let color: String
        let shape: CAShapeLayer
        var points: [CGPoint] = []
    }

    private var sheets: [ObjectIdentifier: Sheet] = [:]
    private var stroke: Stroke?
    /// The highlight the highlighter's text will become, shown while it passes over the text.
    private var previews: [CALayer] = []
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

    var tool = PenTool.pen(PenTool.colors[0])

    var drawing = false {
        didSet { if !drawing { cancelStroke() } }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        if let sheet = sheets[ObjectIdentifier(page)] { return sheet.view }
        guard let document = view.document else { return nil }
        let sheet = Sheet(page: page, index: document.index(for: page))
        sheets[ObjectIdentifier(page)] = sheet
        sheet.sync()
        return sheet.view
    }

    /// A page off screen lets its overlay go; PDFKit asks for a new one when the page comes back.
    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let sheet = sheets[ObjectIdentifier(page)], sheet.view === overlayView else { return }
        if stroke?.sheet === sheet { cancelStroke() }
        sheets[ObjectIdentifier(page)] = nil
    }

    /// Draws the marks now on a page (after marks were added to it or taken off).
    func refresh(_ page: PDFPage) { sheets[ObjectIdentifier(page)]?.sync() }

    func refreshAll() { sheets.values.forEach { $0.sync() } }

    /// The overlay over a page, once PDFKit has shown it.
    func overlay(on page: PDFPage) -> UIView? { sheets[ObjectIdentifier(page)]?.view }

    /// The marks drawn over a page, by ID.
    func shapes(on page: PDFPage) -> [String] {
        (sheets[ObjectIdentifier(page)]?.view.marks.sublayers ?? []).compactMap(\.name).sorted()
    }

    // MARK: The highlighter

    /// Shows rows (from `TextMarks`) as the highlights they will become, in place of what was shown before.
    func preview(_ rows: [(Row, PDFPage)]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previews.forEach { $0.removeFromSuperlayer() }
        previews = rows.compactMap { row, page in
            guard let sheet = sheets[ObjectIdentifier(page)], let mark = Mark(row: row),
                  let shape = MarkShape.layer(mark, on: sheet.geometry) else { return nil }
            shape.name = nil
            sheet.view.layer.addSublayer(shape)
            return shape
        }
        CATransaction.commit()
    }

    func clearPreview() { preview([]) }

    /// How many shapes the preview shows.
    var previewed: Int { previews.count }

    // MARK: Drawing

    /// The pen goes down on a page (false when the page is not shown or the pen is not in hand).
    @discardableResult
    func beginStroke(on page: PDFPage) -> Bool {
        cancelStroke()
        guard drawing, case let .pen(color) = tool, let sheet = sheets[ObjectIdentifier(page)] else { return false }
        let shape = CAShapeLayer()
        shape.strokeColor = (UIColor(hex: color) ?? .black).cgColor
        shape.fillColor = nil
        shape.lineWidth = 2
        shape.lineCap = .round
        shape.lineJoin = .round
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sheet.view.layer.addSublayer(shape)
        CATransaction.commit()
        stroke = Stroke(sheet: sheet, color: color, shape: shape)
        return true
    }

    /// The pen moves through `points` (in `view`, the Pencil's samples since the last time), and is likely to go on
    /// through `predicted`, which is shown but not kept.
    func extendStroke(_ points: [CGPoint], predicted: [CGPoint] = [], in view: UIView) {
        guard var stroke else { return }
        for point in points.map({ stroke.sheet.view.convert($0, from: view) }) {
            // Samples closer than a quarter point add nothing to a 2 pt line.
            if let last = stroke.points.last, hypot(point.x - last.x, point.y - last.y) < 0.25 { continue }
            stroke.points.append(point)
        }
        self.stroke = stroke
        let shown = stroke.points + predicted.map { stroke.sheet.view.convert($0, from: view) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stroke.shape.path = MarkAnnotation.stroke(shown.count == 1 ? shown + [Self.dot(shown[0])] : shown)
        CATransaction.commit()
    }

    /// The pen lifts: the stroke becomes a pen mark (a tap leaves a dot).
    func endStroke() {
        guard let stroke else { return }
        self.stroke = nil
        var points = stroke.points
        if points.count == 1 { points.append(Self.dot(points[0])) }
        let fractions = points.map(stroke.sheet.geometry.fraction)
        let id = UUID().uuidString.lowercased(), sheet = stroke.sheet
        // Drawn as it is written: the same rounded points the computers get.
        guard let row = SyncEngine.strokeRow(id: id, document: "", sha256: "", page: sheet.index, points: fractions,
                                             color: stroke.color, createdAt: ""),
              let mark = Mark(row: row)
        else { return remove(stroke) }
        let annotation = MarkAnnotation(mark: mark, geometry: PageGeometry(sheet.page), picture: nil)
        sheet.page.addAnnotation(annotation)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sheet.sync()
        stroke.shape.removeFromSuperlayer()
        CATransaction.commit()
        drawn?(sheet.index, id, fractions, stroke.color)
        undoManager?.registerUndo(withTarget: self) { $0.take([(annotation, sheet.page)]) }
        undoManager?.setActionName("Pen")
        changed?()
    }

    func cancelStroke() {
        guard let stroke else { return }
        self.stroke = nil
        remove(stroke)
    }

    private func remove(_ stroke: Stroke) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stroke.shape.removeFromSuperlayer()
        CATransaction.commit()
    }

    /// The second point of a dot, so it has length (the desktop wants two points).
    private static func dot(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + 0.3, y: point.y) }

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
