import SwiftUI
import XCTest
@testable import Owelk

/// LaTeX math in answers and notes: found as the desktop finds it, and drawn by MicroTeX.
@MainActor
final class MathTests: XCTestCase {
    /// The desktop's cases (`tests/ResearchStoreTest.cpp`, markdownHtml): three formulas, the set-apart one on its own
    /// line; prices, code, escaped dollars and an unclosed formula stay text.
    func testFormulasAreFoundAsOnTheDesktop() {
        let (text, spans) = MathText.masked("Energy $E=mc^2$ with $a_1 \\cdot b_2$ and\n\n$$\\frac{a}{b}$$\n\n"
                                            + "Cost $5 and $10, `$PATH`, \\$x\\$ and $$still open")
        XCTAssertEqual(spans, [
            MathText.Span(latex: "E=mc^2", original: "$E=mc^2$", display: false),
            MathText.Span(latex: "a_1 \\cdot b_2", original: "$a_1 \\cdot b_2$", display: false),
            MathText.Span(latex: "\\frac{a}{b}", original: "$$\\frac{a}{b}$$", display: true),
        ])
        XCTAssertTrue(text.hasPrefix("Energy \u{E000} with \u{E001} and\n\n\u{E002}\n\n"))
        XCTAssertTrue(text.hasSuffix("Cost $5 and $10, `$PATH`, \\$x\\$ and $$still open"))
        XCTAssertEqual(MathText.placeholder("\u{E002}"), 2)
        XCTAssertNil(MathText.placeholder("a"))

        let (_, others) = MathText.masked("\\(x^2\\) 값$y$는 \\[\n\\sum_i i\n\\]\n```\n$z$\n```")
        XCTAssertEqual(others.map(\.latex), ["x^2", "y", "\n\\sum_i i\n"])
        XCTAssertEqual(others.map(\.display), [false, false, true])
        XCTAssertTrue(MathText.masked("No math, only $").spans.isEmpty)
    }

    /// Formulas are drawn with ink, in display style when set apart; one that cannot be read or would be enormous is
    /// not drawn (it stays as written).
    func testFormulasAreDrawn() throws {
        var depth: CGFloat = 0
        let x = try XCTUnwrap(OwelkMath.image(ofLatex: "x", display: false, size: 20, depth: &depth))
        XCTAssertTrue(Self.inked(x), "drawn with the TeX fonts")
        XCTAssertEqual(x.renderingMode, .alwaysTemplate)
        let below = try XCTUnwrap(OwelkMath.image(ofLatex: "y_1", display: false, size: 20, depth: &depth))
        XCTAssertGreaterThan(depth, 1, "a subscript reaches below the baseline")
        XCTAssertTrue(Self.inked(below))
        let sum = try XCTUnwrap(OwelkMath.image(ofLatex: "\\sum_{i=1}^n i", display: true, size: 20, depth: &depth))
        let inLine = try XCTUnwrap(OwelkMath.image(ofLatex: "\\sum_{i=1}^n i", display: false, size: 20, depth: &depth))
        XCTAssertGreaterThan(sum.size.height, inLine.size.height, "set apart, the sum is larger")
        XCTAssertNotNil(OwelkMath.image(ofLatex: "\\text{한글} + \\mathbb{R}", display: false, size: 20, depth: &depth))
        XCTAssertNil(OwelkMath.image(ofLatex: "\\rule{2000cm}{1cm}", display: false, size: 20, depth: &depth))
        XCTAssertNotNil(OwelkMath.image(ofLatex: "\\rule{2cm}{1cm}", display: false, size: 20, depth: &depth))
        XCTAssertNil(OwelkMath.image(ofLatex: "  ", display: false, size: 20, depth: &depth))

        // Pictures to look at, when asked for (TEST_RUNNER_OWELK_MATH_PICTURES=<folder>).
        guard let folder = ProcessInfo.processInfo.environment["OWELK_MATH_PICTURES"] else { return }
        let all = #"\sum_{i=1}^n \int_0^\infty \sqrt{\frac{a}{b}}\, \mathbb{R}\, \mathcal{L}\, "#
            + #"\left(\begin{matrix}a&b\\c&d\end{matrix}\right) \alpha\beta\gamma \hat{x} \overline{AB} \text{한글}"#
        let formula = try XCTUnwrap(OwelkMath.image(ofLatex: all, display: true, size: 28, depth: &depth))
        try formula.withRenderingMode(.alwaysOriginal).pngData()?.write(to: URL(fileURLWithPath: folder + "/formula.png"))
        let answer = """
        ## Loss $\\mathcal{L}$
        The energy is $E=mc^2$, and the error $e_i = y_i - \\hat{y}_i$ goes to 0 as $n \\to \\infty$.
        - Each term $\\frac{1}{n}\\sum_i x_i^2$ is **small** (see [p. 3](owelk-page:3)).

        $$
        \\mathcal{L}(\\theta) = \\frac{1}{N}\\sum_{i=1}^{N} \\left\\| f_\\theta(x_i) - y_i \\right\\|^2
        $$

        A very long one in the line: $a_1 + a_2 + a_3 + a_4 + a_5 + a_6 + a_7 + a_8 + a_9 + a_{10} + a_{11} + a_{12} + a_{13}$.
        """
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let view = AnswerText(text: answer).frame(width: 300).padding(12)
                .background(Color(uiColor: .systemBackground)).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            try renderer.uiImage?.pngData()?.write(to: URL(fileURLWithPath: folder + "/answer-\(name).png"))
        }
    }

    private static func inked(_ image: UIImage) -> Bool {
        guard let picture = image.cgImage, let data = picture.dataProvider?.data, let bytes = CFDataGetBytePtr(data)
        else { return false }
        let alpha = picture.alphaInfo == .premultipliedFirst || picture.alphaInfo == .first ? 0 : 3
        for row in 0..<picture.height {
            for column in 0..<picture.width where bytes[row * picture.bytesPerRow + column * 4 + alpha] > 128 {
                return true
            }
        }
        return false
    }
}
