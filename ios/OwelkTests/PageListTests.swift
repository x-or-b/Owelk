import PDFKit
import XCTest
@testable import Owelk

/// The pages at the side of the reader.
@MainActor
final class PageListTests: XCTestCase {
    /// One picture per page, the page being read marked, and a tap goes to its page. PDFKit's own thumbnail view,
    /// which moved the pages to the current page's top after every pen stroke, page turn and zoom, is not in the reader.
    func testPagesAtTheSide() async throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let document = try XCTUnwrap(PDFDocument(data: renderer.pdfData { context in
            for _ in 0..<6 { context.beginPage() }
        }))
        let controller = ReaderViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 820, height: 1180))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        controller.document = document
        controller.showsThumbnails = true
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))

        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        XCTAssertFalse(views(controller.view).contains { $0 is PDFThumbnailView })
        let side = try XCTUnwrap(views(controller.view).compactMap { $0 as? PageList }.first)
        let list = try XCTUnwrap(views(side).compactMap { $0 as? UICollectionView }.first)
        XCTAssertEqual(list.numberOfItems(inSection: 0), 6)
        XCTAssertEqual(side.current, 0)

        list.delegate?.collectionView?(list, didSelectItemAt: IndexPath(item: 3, section: 0))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.position()?.page, 3, "the page's top at the top")
        XCTAssertEqual(side.current, 3, "and marked")
    }
}
