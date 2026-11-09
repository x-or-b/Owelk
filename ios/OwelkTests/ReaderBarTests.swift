import PDFKit
import SwiftUI
import XCTest
@testable import Owelk

private struct Pages: UIViewControllerRepresentable {
    let controller: ReaderViewController
    func makeUIViewController(context: Context) -> ReaderViewController { controller }
    func updateUIViewController(_ controller: ReaderViewController, context: Context) {}
}

/// The reader's pages and the bar above them.
@MainActor
final class ReaderBarTests: XCTestCase {
    /// The pages run under the bar, which is told their scroll view (so Liquid Glass blurs what passes under it), and
    /// a paper opened at its start shows its first page just below the bar.
    func testPagesRunUnderTheBar() async throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let document = try XCTUnwrap(PDFDocument(data: renderer.pdfData { context in
            for _ in 0..<4 { context.beginPage() }
        }))
        let controller = ReaderViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1366, height: 1024))
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            Pages(controller: controller).ignoresSafeArea()
                .navigationTitle("Paper").navigationBarTitleDisplayMode(.inline)
        })
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<10 where controller.viewIfLoaded?.window == nil {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
        }
        controller.document = document
        try await Task.sleep(for: .milliseconds(800))

        let view = controller.pdfView
        let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UIScrollView }.first)
        XCTAssertEqual(view.convert(view.bounds, to: nil).minY, 0, "under the bar")
        XCTAssertGreaterThan(view.safeAreaInsets.top, 40)
        XCTAssertEqual(scroll.contentOffset.y, -scroll.adjustedContentInset.top, "at the top of its range")
        let page = try XCTUnwrap(document.page(at: 0))
        let top = view.convert(PageGeometry(page).point(.zero), from: page).y
        XCTAssertTrue((view.safeAreaInsets.top...view.safeAreaInsets.top + 20).contains(top), "just below the bar: \(top)")
        var holder: UIViewController = controller
        while let parent = holder.parent, !(parent is UINavigationController) { holder = parent }
        XCTAssertTrue(holder.contentScrollView(for: .top) === scroll)
    }
}
