import PDFKit
import SwiftUI
import UIKit

/// The page view: PDFKit's own scrolling, zoom and text selection, page thumbnails at the side, and the computers'
/// marks drawn over the pages. A tap on a mark with a note shows the note.
final class ReaderViewController: UIViewController, UIGestureRecognizerDelegate {
    let pdfView = PageView()
    private let thumbnails = PDFThumbnailView()
    private let thumbnailColumn = UIView()
    private var restored = false
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
    var start: ReadingPosition?
    var onPageChange: ((Int) -> Void)?

    var document: PDFDocument? {
        get { pdfView.document }
        set {
            pdfView.document = newValue
            restored = false
            waitForDoubleTaps()
            view.setNeedsLayout()
        }
    }

    var showsThumbnails = false {
        didSet { thumbnailColumn.isHidden = !showsThumbnails }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.interpolationQuality = .high

        thumbnails.pdfView = pdfView
        thumbnails.layoutMode = .vertical
        thumbnails.thumbnailSize = CGSize(width: 96, height: 128)
        thumbnails.backgroundColor = .systemBackground
        thumbnailColumn.isHidden = true
        thumbnailColumn.addSubview(thumbnails)
        let line = UIView()
        line.backgroundColor = .separator
        thumbnailColumn.addSubview(line)

        let stack = UIStackView(arrangedSubviews: [thumbnailColumn, pdfView])
        stack.axis = .horizontal
        view.addSubview(stack)
        for item in [stack, thumbnails, line] { item.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            thumbnailColumn.widthAnchor.constraint(equalToConstant: 128),
            thumbnails.leadingAnchor.constraint(equalTo: thumbnailColumn.leadingAnchor),
            thumbnails.trailingAnchor.constraint(equalTo: line.leadingAnchor),
            thumbnails.topAnchor.constraint(equalTo: thumbnailColumn.safeAreaLayoutGuide.topAnchor),
            thumbnails.bottomAnchor.constraint(equalTo: thumbnailColumn.bottomAnchor),
            line.trailingAnchor.constraint(equalTo: thumbnailColumn.trailingAnchor),
            line.topAnchor.constraint(equalTo: thumbnailColumn.topAnchor),
            line.bottomAnchor.constraint(equalTo: thumbnailColumn.bottomAnchor),
            line.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])

        tap.delegate = self
        pdfView.addGestureRecognizer(tap)
        waitForDoubleTaps()
        pdfView.laidOut = { [weak self] in self?.pagesLaidOut() }
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged,
                                               object: pdfView)
    }

    /// Once the pages have a size: they are fitted, and the paper opens where it was left.
    private func pagesLaidOut() {
        guard !restored, pdfView.bounds.height > 0, let document = pdfView.document else { return }
        restored = true
        // The pages laid out at their fitted size first, so the place is found on them.
        pdfView.layoutDocumentView()
        pdfView.minScaleFactor = pdfView.scaleFactorForSizeToFit * 0.5
        pdfView.maxScaleFactor = pdfView.scaleFactorForSizeToFit * 6
        pdfView.autoScales = true
        guard let start, start.page > 0 || start.y > 0,
              let page = document.page(at: min(start.page, document.pageCount - 1)) else { return }
        go(to: page, y: start.y)
        // PDFKit settles its scroll view after this pass; the place is set again once it has.
        DispatchQueue.main.async { [weak self] in self?.go(to: page, y: start.y) }
    }

    /// Puts the place `y` down the page at the top of the visible area (below the bar), where `position()` reads it.
    func go(to page: PDFPage, y: Double) {
        let target = PageGeometry(page).point(CGPoint(x: 0, y: y))
        pdfView.go(to: PDFDestination(page: page, at: target))
        guard let scroll = Self.scrollView(in: pdfView) else { return }
        let landed = pdfView.convert(target, from: page).y
        let top = pdfView.safeAreaInsets.top
        let lowest = -scroll.adjustedContentInset.top
        let highest = max(lowest, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        scroll.contentOffset.y = min(highest, max(lowest, scroll.contentOffset.y + landed - top))
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
        for child in view.subviews {
            if let scroll = child as? UIScrollView { return scroll }
            if let scroll = scrollView(in: child) { return scroll }
        }
        return nil
    }

    /// Where the reader is: the page at the top of the view and how far down it the view begins (the desktop's
    /// `position()` looks 28 px below the top for the page and measures from the top).
    func position() -> ReadingPosition? {
        guard let document = pdfView.document, document.pageCount > 0 else { return nil }
        let top = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.minY + pdfView.safeAreaInsets.top)
        guard let page = pdfView.page(for: CGPoint(x: top.x, y: top.y + 28), nearest: true) else { return nil }
        let fraction = PageGeometry(page).fraction(pdfView.convert(top, to: page))
        return ReadingPosition(page: document.index(for: page), y: min(1, max(0, fraction.y)))
    }

    @objc private func pageChanged() {
        guard let page = pdfView.currentPage, let document = pdfView.document else { return }
        onPageChange?(document.index(for: page))
    }

    // MARK: Marks

    func show(_ marks: [Mark], pictures: (String) -> UIImage?) {
        guard let document = pdfView.document else { return }
        for mark in marks where mark.page < document.pageCount {
            guard let page = document.page(at: mark.page) else { continue }
            let picture = mark.kind == "image" ? pictures(mark.image) : nil
            page.addAnnotation(MarkAnnotation(mark: mark, geometry: PageGeometry(page), picture: picture))
        }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: pdfView)
        guard let page = pdfView.page(for: location, nearest: false) else { return }
        let point = pdfView.convert(location, to: page)
        let reach = 10 / max(0.1, pdfView.scaleFactor)
        guard let hit = page.annotations.reversed().compactMap({ $0 as? MarkAnnotation })
            .first(where: { $0.mark.hasNote && $0.touches(point, reach: reach) }) else { return }
        let note = UIHostingController(rootView: MarkNote(mark: hit.mark))
        note.modalPresentationStyle = .popover
        let size = note.sizeThatFits(in: CGSize(width: 380, height: 520))
        note.preferredContentSize = CGSize(width: 380, height: min(520, max(80, size.height)))
        note.popoverPresentationController?.sourceView = pdfView
        note.popoverPresentationController?.sourceRect = pdfView.convert(hit.bounds, from: page)
        note.popoverPresentationController?.permittedArrowDirections = [.up, .down, .left, .right]
        present(note, animated: true)
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// A double tap zooms: a tap on a mark waits until it is clear that it was one tap. PDFKit makes its recognizers
    /// with the document, so this runs again then.
    private func waitForDoubleTaps() {
        for other in Self.recognizers(in: pdfView) where other !== tap
            && (other as? UITapGestureRecognizer)?.numberOfTapsRequired == 2 {
            tap.require(toFail: other)
        }
    }

    private static func recognizers(in view: UIView) -> [UIGestureRecognizer] {
        (view.gestureRecognizers ?? []) + view.subviews.flatMap { recognizers(in: $0) }
    }
}

/// PDFKit's view, telling when it has been laid out (its size comes from the stack it is in, after the controller's
/// own layout pass).
final class PageView: PDFView {
    var laidOut: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        laidOut?()
    }
}

/// A mark's note, read-only: its kind, the quoted text with the mark's ink beside it, and the note itself.
struct MarkNote: View {
    let mark: Mark

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(mark.name).font(.caption).foregroundStyle(.secondary)
                if !mark.text.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1).fill(Color(mark.color)).frame(width: 3)
                        Text(mark.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !mark.body.isEmpty {
                    Text(mark.body).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}
