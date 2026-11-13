import SwiftUI
import UIKit

/// LaTeX math in AI answers and notes, found as the desktop finds it (`takeMath`, src/ResearchStoreNotes.cpp):
/// `$$…$$` and `\[…\]` set apart, `\(…\)` and `$…$` in the line. Prices ($5 and $10), `\$`, code and an unclosed
/// `$$` stay text. Formulas are drawn by MicroTeX (`OwelkMath`), as on the desktop.
enum MathText {
    struct Span: Equatable {
        let latex: String
        /// As written, shown when the formula cannot be drawn.
        let original: String
        let display: Bool
    }

    private static let code = try! NSRegularExpression(
        pattern: #"(?ms)^[ \t]*(```|~~~)[^\n]*\n.*?^[ \t]*\1[ \t]*$|`[^`\n]+`"#)
    // The desktop's pattern; "\w" there is ASCII (Qt's default), so a formula may follow Hangul directly.
    private static let math = try! NSRegularExpression(
        pattern: #"\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\\\(([\s\S]+?)\\\)"#
            + #"|(?<![\\$A-Za-z0-9_])\$(?![\s$])((?:\\.|[^$\\\n])+?)(?<![\s\\])\$(?!\d)"#)

    /// Placeholders stand for formulas while the Markdown is read (private-use characters from U+E000).
    private static let first: UInt32 = 0xE000
    private static let most = 6400

    /// The text with each formula replaced by its placeholder (so `_`, `*` and `\\` inside it are not Markdown and a
    /// set-apart formula on lines of its own keeps one line), and the formulas in order.
    static func masked(_ text: String) -> (text: String, spans: [Span]) {
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        let skip = code.matches(in: text, range: whole).map(\.range)
        var spans: [Span] = []
        var out = ""
        var last = 0
        for match in math.matches(in: text, range: whole) where spans.count < most {
            let range = match.range
            if range.location < last || skip.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }
            var group = 1
            while group < 4, match.range(at: group).location == NSNotFound { group += 1 }
            out += source.substring(with: NSRange(location: last, length: range.location - last))
            out.unicodeScalars.append(Unicode.Scalar(first + UInt32(spans.count))!)
            spans.append(Span(latex: source.substring(with: match.range(at: group)),
                              original: source.substring(with: range), display: group <= 2))
            last = range.location + range.length
        }
        guard !spans.isEmpty else { return (text, []) }
        return (out + source.substring(from: last), spans)
    }

    /// The formula a placeholder stands for.
    static func placeholder(_ character: Character) -> Int? {
        guard character.unicodeScalars.count == 1, let value = character.unicodeScalars.first?.value,
              value >= first, value < first + UInt32(most) else { return nil }
        return Int(value - first)
    }

    /// The em of formulas beside text of `size` points: TeX's fonts read a little small beside the system's.
    static func em(_ size: CGFloat, display: Bool) -> CGFloat { size * (display ? 1.25 : 1.15) }

    /// Text with its formulas drawn in it, on the line's baseline and in the text's colour.
    @MainActor
    static func text(_ attributed: AttributedString, spans: [Span], size: CGFloat) -> Text {
        guard !spans.isEmpty else { return Text(attributed) }
        var parts: [Text] = []
        var start = attributed.startIndex
        var index = start
        while index < attributed.endIndex {
            let next = attributed.characters.index(after: index)
            if let number = placeholder(attributed.characters[index]), number < spans.count {
                if start < index { parts.append(Text(AttributedString(attributed[start..<index]))) }
                parts.append(inline(spans[number], size: size))
                start = next
            }
            index = next
        }
        if start < attributed.endIndex { parts.append(Text(AttributedString(attributed[start..<attributed.endIndex]))) }
        return parts.dropFirst().reduce(parts.first ?? Text("")) { $0 + $1 }
    }

    @MainActor
    private static func inline(_ span: Span, size: CGFloat) -> Text {
        let picture = MathPictures.shared.picture(span.latex, display: span.display, em: em(size, display: span.display))
        guard let image = picture.image else { return Text(span.original) }
        return Text(Image(uiImage: image).renderingMode(.template)).baselineOffset(-picture.depth)
    }

    /// A formula on a line of its own: set apart (centred), or one from the line too wide for the column (at the
    /// start); scrolled sideways when wider than the column.
    @MainActor @ViewBuilder
    static func block(_ span: Span, size: CGFloat) -> some View {
        let picture = MathPictures.shared.picture(span.latex, display: span.display, em: em(size, display: span.display))
        if let image = picture.image {
            ViewThatFits(in: .horizontal) {
                Image(uiImage: image).renderingMode(.template)
                    .frame(maxWidth: .infinity, alignment: span.display ? .center : .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    Image(uiImage: image).renderingMode(.template)
                }
            }
            .padding(.vertical, span.display ? 4 : 0)
            .accessibilityLabel(span.latex)
        } else {
            Text(span.original)
        }
    }

    /// Whether a formula in the line is wider than the column (it then gets a line of its own).
    @MainActor
    static func tooWide(_ span: Span, size: CGFloat, width: CGFloat) -> Bool {
        guard width > 0, !span.display else { return false }
        let picture = MathPictures.shared.picture(span.latex, display: false, em: em(size, display: false))
        return (picture.image?.size.width ?? 0) > width
    }

    /// A line in pieces: its text, and the formulas too wide for the column taken out to lines of their own.
    enum Piece: Hashable {
        case text(String)
        case formula(Int)
    }

    @MainActor
    static func pieces(_ line: String, spans: [Span], size: CGFloat, width: CGFloat) -> [Piece] {
        var pieces: [Piece] = []
        var text = ""
        for character in line {
            if let number = placeholder(character), number < spans.count, tooWide(spans[number], size: size, width: width) {
                if !text.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(.text(text)) }
                pieces.append(.formula(number))
                text = ""
            } else {
                text.append(character)
            }
        }
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(.text(text)) }
        return pieces
    }
}

/// Drawn formulas, kept while there is room (also those that could not be drawn, so an answer still coming in does
/// not try them again with each new word).
@MainActor
final class MathPictures {
    static let shared = MathPictures()

    final class Picture {
        let image: UIImage?
        /// How far the picture reaches below the formula's baseline (points).
        let depth: CGFloat

        init(image: UIImage?, depth: CGFloat) {
            self.image = image
            self.depth = depth
        }
    }

    private let cache: NSCache<NSString, Picture> = {
        let cache = NSCache<NSString, Picture>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    func picture(_ latex: String, display: Bool, em: CGFloat) -> Picture {
        let key = "\(display ? "d" : "i")\(em)|\(latex)" as NSString
        if let found = cache.object(forKey: key) { return found }
        var depth: CGFloat = 0
        let image = OwelkMath.image(ofLatex: latex, display: display, size: em, depth: &depth)
        let picture = Picture(image: image, depth: depth)
        let bytes = image.map { Int($0.size.width * $0.size.height * $0.scale * $0.scale * 4) } ?? 64
        cache.setObject(picture, forKey: key, cost: bytes)
        return picture
    }
}
