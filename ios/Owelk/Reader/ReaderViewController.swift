import PDFKit
import SwiftUI
import UIKit

/// The page view: PDFKit's own scrolling, zoom and text selection, page thumbnails at the side, and the computers'
/// marks drawn over the pages. A tap on a mark with a note shows the note. While drawing, Apple Pencil draws and
/// erases (`pen`) and fingers still scroll and zoom; a two-finger tap undoes.
final class ReaderViewController: UIViewController, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    let pdfView = PageView()
    let pen = PenLayer()
    /// The reader's own undo history, which the canvases use.
    private let history = UndoManager()
    private lazy var undoTap = UITapGestureRecognizer(target: self, action: #selector(undoTapped))
    private lazy var eraser = UIPanGestureRecognizer(target: self, action: #selector(erasing(_:)))
    private var erasedTo: CGPoint?
    /// Apple Pencil's double tap and squeeze, with the action the reader chose in Settings and where the tip hovers.
    var onPencil: ((UIPencilPreferredAction, CGPoint?) -> Void)?
    var onUndo: (() -> Void)?
    private let thumbnails = PDFThumbnailView()
    private let thumbnailColumn = UIView()
    private var restored = false
    /// Where the paper was left, held while PDFKit is still fitting its pages (it moves to a page's top when it
    /// rescales), until the reader touches the page or a moment has passed.
    private var holding: (page: PDFPage, y: Double, until: Date)?
    private var placing = false
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
    var start: ReadingPosition?
    var onPageChange: ((Int) -> Void)?

    var document: PDFDocument? {
        get { pdfView.document }
        set {
            pdfView.document = newValue
            restored = false
            holding = nil
            waitForDoubleTaps()
            view.setNeedsLayout()
            // A view already on screen keeps its size, so it is not laid out again: the place is set from here.
            DispatchQueue.main.async { [weak self] in self?.pagesLaidOut() }
        }
    }

    var showsThumbnails = false {
        didSet { thumbnailColumn.isHidden = !showsThumbnails }
    }

    var drawing = false {
        didSet {
            pen.drawing = drawing
            pdfView.isInMarkupMode = drawing
            undoTap.isEnabled = drawing
            eraser.isEnabled = drawing
            // The Pencil draws and erases then; only fingers move the pages.
            let touches = drawing ? [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                : [UITouch.TouchType.direct, .pencil, .indirectPointer].map { NSNumber(value: $0.rawValue) }
            if let scroll = Self.scrollView(in: pdfView) {
                scroll.panGestureRecognizer.allowedTouchTypes = touches
                scroll.pinchGestureRecognizer?.allowedTouchTypes = touches
            }
            // Pencil taps make dots while drawing; fingers still open notes.
            tap.allowedTouchTypes = drawing ? [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                : [UITouch.TouchType.direct, .pencil, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        }
    }

    override var undoManager: UndoManager? { history }

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
        pdfView.pageOverlayViewProvider = pen
        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        undoTap.isEnabled = false
        undoTap.delegate = self
        pdfView.addGestureRecognizer(undoTap)
        pen.undoManager = history
        eraser.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        eraser.maximumNumberOfTouches = 1
        eraser.isEnabled = false
        eraser.delegate = self
        pdfView.addGestureRecognizer(eraser)
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)
        waitForDoubleTaps()
        pdfView.laidOut = { [weak self] in self?.pagesLaidOut() }
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged,
                                               object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(hold), name: .PDFViewScaleChanged, object: pdfView)
    }

    /// Once the pages have a size: they are fitted, and the paper opens where it was left.
    private func pagesLaidOut() {
        guard !restored else { return hold() }
        guard pdfView.bounds.height > 0, let document = pdfView.document else { return }
        restored = true
        // The pages laid out at their fitted size first, so the place is found on them.
        pdfView.layoutDocumentView()
        pdfView.minScaleFactor = pdfView.scaleFactorForSizeToFit * 0.5
        pdfView.maxScaleFactor = pdfView.scaleFactorForSizeToFit * 6
        pdfView.autoScales = true
        guard let start, start.page > 0 || start.y > 0,
              let page = document.page(at: min(start.page, document.pageCount - 1)) else { return }
        holding = (page, start.y, Date().addingTimeInterval(1.5))
        hold()
        for delay in [0.05, 0.2, 0.5, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.hold() }
        }
    }

    /// Puts the paper back where it was left, while that is still wanted.
    @objc private func hold() {
        guard let target = holding, !placing else { return }
        let scroll = Self.scrollView(in: pdfView)
        let touched = scroll.map { $0.isTracking || $0.isDragging || $0.isDecelerating || $0.isZooming } ?? false
        if Date() > target.until || touched || pdfView.document == nil {
            holding = nil
            return
        }
        if let now = position(), pdfView.document?.index(for: target.page) == now.page, abs(now.y - target.y) < 0.003 {
            return
        }
        placing = true
        go(to: target.page, y: target.y)
        placing = false
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

    @objc private func undoTapped() { onUndo?() }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        gesture === eraser ? pen.tool == .eraser : true
    }

    @objc private func erasing(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: pdfView)
        switch gesture.state {
        case .began:
            pen.erase(along: [location], in: pdfView)
            erasedTo = location
        case .changed:
            pen.erase(along: [erasedTo ?? location, location], in: pdfView)
            erasedTo = location
        case .ended, .cancelled, .failed:
            pen.finishErasing()
            erasedTo = nil
        default:
            break
        }
    }

    // MARK: Apple Pencil

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        onPencil?(UIPencilInteraction.preferredTapAction, tap.hoverPose.map { interaction.view?.convert($0.location, to: view) ?? $0.location })
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        onPencil?(UIPencilInteraction.preferredSqueezeAction, squeeze.hoverPose.map {
            interaction.view?.convert($0.location, to: view) ?? $0.location
        })
    }

    /// A small palette beside the Pencil's tip (or below the bar when it is not hovering).
    func presentPalette(_ palette: UIViewController, at point: CGPoint?) {
        guard presentedViewController == nil else { return }
        palette.modalPresentationStyle = .popover
        let place = point ?? CGPoint(x: view.bounds.midX, y: view.safeAreaInsets.top + 8)
        palette.popoverPresentationController?.sourceView = view
        palette.popoverPresentationController?.sourceRect = CGRect(origin: place, size: .zero).insetBy(dx: -12, dy: -12)
        palette.popoverPresentationController?.permittedArrowDirections = [.up, .down, .left, .right]
        present(palette, animated: true)
    }

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
