import PDFKit
import UIKit

/// An annotation made on a computer (a row of `highlights`): a highlight, comment, text box, picture, pen stroke or
/// marked region. Places are fractions of the page as shown (rotated), from its top left.
struct Mark: Identifiable {
    let id: String
    let page: Int
    let kind: String
    let color: UIColor
    /// The quoted text (highlights and comments) or a region's caption.
    let text: String
    let body: String
    let rectangles: [CGRect]
    let drawing: [CGPoint]
    let image: String
    let fontSize: CGFloat
    let createdAt: String

    init?(row: Row) {
        id = row.string("id")
        page = row.int("page")
        guard !id.isEmpty, page >= 0 else { return nil }
        kind = row.string("kind").isEmpty ? "highlight" : row.string("kind")
        color = UIColor(hex: row.string("color")) ?? UIColor(red: 0.259, green: 0.42, blue: 0.604, alpha: 1)
        text = row.string("text")
        body = row.string("body")
        rectangles = (JSON.value(row.string("rectangles")) as? [Row] ?? []).map {
            CGRect(x: $0.double("x"), y: $0.double("y"), width: $0.double("width"), height: $0.double("height"))
        }.filter { $0.width.isFinite && $0.height.isFinite && $0.width >= 0 && $0.height >= 0 }
        drawing = (JSON.value(row.string("drawing")) as? [Row] ?? []).map { CGPoint(x: $0.double("x"), y: $0.double("y")) }
        image = row.string("image")
        fontSize = row.double("font_size") > 0 ? row.double("font_size") : 14
        createdAt = row.string("created_at")
        if rectangles.isEmpty && drawing.isEmpty { return nil }
    }

    /// Whether a tap shows something more than the page does.
    var hasNote: Bool {
        switch kind {
        case "text", "image": false
        case "area": !body.isEmpty || !text.isEmpty
        default: !body.isEmpty
        }
    }

    var name: String {
        switch kind {
        case "comment": "Comment"
        case "text": "Text Box"
        case "image": "Image"
        case "draw": "Pen"
        case "area": "Region"
        default: "Highlight"
        }
    }

    /// The shown-page fractions it covers.
    var extent: CGRect {
        let points = drawing.map { CGRect(origin: $0, size: .zero) }
        return (rectangles + points).reduce(CGRect.null) { $0.union($1) }
    }
}

/// A page as Owelk measures it: places are fractions of the page as shown (its crop box, turned by /Rotate), from the
/// top left. `transform` turns shown points (y down) into PDF page space (y up), exactly as `Page::point` in
/// src/AnnotatedPdf.cpp does.
struct PageGeometry {
    let box: CGRect
    let rotation: Int

    init(box: CGRect, rotation: Int) {
        self.box = box
        self.rotation = ((rotation % 360) + 360) % 360
    }

    init(_ page: PDFPage) { self.init(box: page.bounds(for: .cropBox), rotation: page.rotation) }

    var shownSize: CGSize {
        rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }

    var transform: CGAffineTransform {
        let l = box.minX, b = box.minY, w = box.width, h = box.height
        switch rotation {
        case 90: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: l, ty: b)
        case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: l + w, ty: b)
        case 270: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: l + w, ty: b + h)
        default: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: l, ty: b + h)
        }
    }

    /// A shown-page fraction → page space.
    func point(_ fraction: CGPoint) -> CGPoint {
        CGPoint(x: fraction.x * shownSize.width, y: fraction.y * shownSize.height).applying(transform)
    }

    /// Page space → a shown-page fraction.
    func fraction(_ point: CGPoint) -> CGPoint {
        let shown = point.applying(transform.inverted())
        return CGPoint(x: shown.x / max(1, shownSize.width), y: shown.y / max(1, shownSize.height))
    }

    /// Shown fractions → shown points.
    func shown(_ fraction: CGRect) -> CGRect {
        CGRect(x: fraction.minX * shownSize.width, y: fraction.minY * shownSize.height,
               width: fraction.width * shownSize.width, height: fraction.height * shownSize.height)
    }

    func shown(_ fraction: CGPoint) -> CGPoint {
        CGPoint(x: fraction.x * shownSize.width, y: fraction.y * shownSize.height)
    }

    /// A shown-fraction rectangle → its bounds in page space.
    func rect(_ fraction: CGRect) -> CGRect { shown(fraction).applying(transform) }
}

/// A mark drawn on a page in memory, never saved into the PDF. Drawing happens in shown points, so rotated pages, zoom
/// and the desktop's look all match: highlights tint at 28%, comments and regions are outlined, the pen is 2 pt wide.
final class MarkAnnotation: PDFAnnotation {
    let mark: Mark
    let geometry: PageGeometry
    private let picture: UIImage?

    init(mark: Mark, geometry: PageGeometry, picture: UIImage?) {
        self.mark = mark
        self.geometry = geometry
        self.picture = picture
        let pad: CGFloat = mark.kind == "text" ? 2 : 4
        super.init(bounds: geometry.rect(mark.extent).insetBy(dx: -pad, dy: -pad), forType: .square, withProperties: nil)
        isReadOnly = true
        shouldPrint = false
    }

    required init?(coder: NSCoder) { nil }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        UIGraphicsPushContext(context)
        context.saveGState()
        context.concatenate(geometry.transform)
        let color = mark.color
        switch mark.kind {
        case "comment", "area":
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1.5)
            for rect in mark.rectangles {
                context.addPath(UIBezierPath(roundedRect: geometry.shown(rect), cornerRadius: 2).cgPath)
            }
            context.strokePath()
        case "text":
            if let rect = mark.rectangles.first {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                (mark.body as NSString).draw(in: geometry.shown(rect), withAttributes: [
                    .font: UIFont.systemFont(ofSize: mark.fontSize), .foregroundColor: color, .paragraphStyle: style,
                ])
            }
        case "image":
            if let picture, let rect = mark.rectangles.first { picture.draw(in: geometry.shown(rect)) }
        case "draw":
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(2)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(Self.stroke(mark.drawing.map(geometry.shown)))
            context.strokePath()
        default:
            context.setFillColor(color.withAlphaComponent(0.28).cgColor)
            for rect in mark.rectangles { context.fill(geometry.shown(rect)) }
        }
        context.restoreGState()
        UIGraphicsPopContext()
    }

    /// Quadratic segments through the midpoints of the samples, as qml/StrokePath.js draws a stroke.
    static func stroke(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
            return path
        }
        for i in 1..<max(1, points.count - 1) {
            let p = points[i], q = points[i + 1]
            path.addQuadCurve(to: CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2), control: p)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// Whether a point in page space touches the mark, within `reach` page points.
    func touches(_ point: CGPoint, reach: CGFloat) -> Bool {
        let shown = point.applying(geometry.transform.inverted())
        if mark.kind == "draw" {
            let points = mark.drawing.map(geometry.shown)
            return zip(points, points.dropFirst() + [points.last ?? .zero]).contains { a, b in
                Self.distance(shown, a, b) <= reach + 1
            }
        }
        return mark.rectangles.contains { geometry.shown($0).insetBy(dx: -reach, dy: -reach).contains(shown) }
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        let t = length > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }
}

extension UIColor {
    /// "#rrggbb" or "#aarrggbb", as Qt names colors.
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("#") else { return nil }
        text.removeFirst()
        guard let value = UInt64(text, radix: 16), text.count == 6 || text.count == 8 else { return nil }
        let alpha = text.count == 8 ? CGFloat((value >> 24) & 0xFF) / 255 : 1
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}
