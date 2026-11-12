import PDFKit
import PencilKit
import SwiftUI
import UIKit

/// The page view: PDFKit's own scrolling, zoom and text selection, page pictures at the side (`PageList`), and the
/// computers' marks drawn over the pages. A tap on a mark with a note shows the note. While drawing, Apple Pencil
/// draws and erases (`pen`) and fingers still scroll and zoom; a two-finger tap undoes.
final class ReaderViewController: UIViewController, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    let pdfView = PageView()
    let pen = PenLayer()
    /// The reader's own undo history, which the canvases use.
    private let history = UndoManager()
    private lazy var undoTap = UITapGestureRecognizer(target: self, action: #selector(undoTapped))
    private lazy var eraser = UIPanGestureRecognizer(target: self, action: #selector(erasing(_:)))
    private lazy var marker = UIPanGestureRecognizer(target: self, action: #selector(marking(_:)))
    /// Where the highlighter went down.
    private var markedFrom: (page: PDFPage, point: CGPoint)?
    private var erasedTo: CGPoint?
    /// Apple Pencil's double tap and squeeze, with the action the reader chose in Settings and where the tip hovers.
    var onPencil: ((UIPencilPreferredAction, CGPoint?) -> Void)?
    var onUndo: (() -> Void)?
    private let thumbnails = PageList()
    private let thumbnailColumn = UIView()
    /// The strip under the bar (status bar and bar), over the pages. On iOS 26 it holds Liquid Glass's hard edge effect
    /// for the pages: they pass under it shaded into a band that sets the bar apart and still shows them faintly, as in
    /// Preview. Earlier systems get a blurred band with a hairline.
    private let barBand = UIView()
    private var bandAttached = false
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
            thumbnails.document = newValue
            restored = false
            holding = nil
            waitForDoubleTaps()
            view.setNeedsLayout()
            // A view already on screen keeps its size, so it is not laid out again: the place is set from here.
            DispatchQueue.main.async { [weak self] in self?.pagesLaidOut() }
        }
    }

    var showsThumbnails = false {
        didSet {
            thumbnailColumn.isHidden = !showsThumbnails
            if showsThumbnails {
                view.layoutIfNeeded()
                thumbnails.reveal(animated: false)
            }
        }
    }

    var drawing = false {
        didSet {
            guard drawing != oldValue else { return }
            pen.drawing = drawing
            pdfView.isInMarkupMode = drawing
            undoTap.isEnabled = drawing
            eraser.isEnabled = drawing
            marker.isEnabled = drawing
            // The Pencil draws and erases then; only fingers scroll, zoom, select and open notes. PDFKit's own double
            // tap took the Pencil too, and zoomed the page away when a stroke began with a quick touch.
            if drawing {
                fingersOnly = Self.recognizers(in: pdfView, outside: PKCanvasView.self).filter {
                    $0 !== eraser && $0 !== marker && $0 !== undoTap && !($0 is UIHoverGestureRecognizer)
                }.map { ($0, $0.allowedTouchTypes) }
                let finger = UITouch.TouchType.direct.rawValue
                for (recognizer, touches) in fingersOnly {
                    recognizer.allowedTouchTypes = touches.filter { $0.intValue == finger }
                }
            } else {
                for (recognizer, touches) in fingersOnly { recognizer.allowedTouchTypes = touches }
                fingersOnly = []
            }
        }
    }

    /// PDFKit's recognizers (and the note tap) held to fingers while drawing, with the touches they took before.
    private var fingersOnly: [(UIGestureRecognizer, [NSNumber])] = []

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
        // Selected text in the accent: the screen's tint (the label color) would select white on the white page in
        // dark mode.
        pdfView.tintColor = Theme.accentUI

        thumbnails.backgroundColor = .systemBackground
        thumbnails.chosen = { [weak self] index in
            guard let self, let page = self.pdfView.document?.page(at: index) else { return }
            self.go(to: page, y: 0)
        }
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
        barBand.isUserInteractionEnabled = false
        view.addSubview(barBand)
        if #unavailable(iOS 26) {
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
            blur.frame = barBand.bounds
            blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            barBand.addSubview(blur)
            let hairline = UIView()
            hairline.backgroundColor = .separator
            hairline.frame = CGRect(x: 0, y: barBand.bounds.height - 0.5, width: barBand.bounds.width, height: 0.5)
            hairline.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
            barBand.addSubview(hairline)
        }

        tap.delegate = self
        pdfView.addGestureRecognizer(tap)
        pdfView.selectionActions = { [weak self] in self?.selectionActions() ?? [] }
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
        marker.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        marker.maximumNumberOfTouches = 1
        marker.isEnabled = false
        marker.delegate = self
        pdfView.addGestureRecognizer(marker)
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)
        waitForDoubleTaps()
        pdfView.laidOut = { [weak self] in self?.pagesLaidOut() }
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged,
                                               object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(hold), name: .PDFViewScaleChanged, object: pdfView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.bringSubviewToFront(barBand)
        barBand.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.safeAreaInsets.top)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        pagesUnderTheBar()
    }

    /// The pages run under the bar (the SwiftUI screen ignores the safe area; PDFKit insets its pages by it), and the
    /// bar blurs what passes under it, as Preview's does: the navigation controller is told which scroll view holds
    /// the pages, so Liquid Glass's edge effect follows them.
    private func pagesUnderTheBar() {
        guard let scroll = Self.scrollView(in: pdfView) else { return }
        if #available(iOS 26, *), !bandAttached {
            // SwiftUI's bar shades only SwiftUI's own scroll views, so the band asks for the pages' edge effect itself.
            bandAttached = true
            scroll.topEdgeEffect.style = .hard
            let band = UIScrollEdgeElementContainerInteraction()
            band.scrollView = scroll
            band.edge = .top
            barBand.addInteraction(band)
        }
        var holder: UIViewController = self
        while let parent = holder.parent, !(parent is UINavigationController) { holder = parent }
        if holder.contentScrollView(for: .top) !== scroll { holder.setContentScrollView(scroll, for: .top) }
    }

    /// Once the pages have a size: they are fitted, and the paper opens where it was left.
    private func pagesLaidOut() {
        guard !restored else { return hold() }
        guard pdfView.bounds.height > 0, let document = pdfView.document else { return }
        restored = true
        pagesUnderTheBar()
        // The pages laid out at their fitted size first, so the place is found on them.
        pdfView.layoutDocumentView()
        pdfView.minScaleFactor = pdfView.scaleFactorForSizeToFit * 0.5
        pdfView.maxScaleFactor = pdfView.scaleFactorForSizeToFit * 6
        pdfView.autoScales = true
        guard let start, start.page > 0 || start.y > 0,
              let page = document.page(at: min(start.page, document.pageCount - 1)) else { return toTop() }
        holding = (page, start.y, Date().addingTimeInterval(1.5))
        hold()
        for delay in [0.05, 0.2, 0.5, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.hold() }
        }
    }

    /// The first page just below the bar. PDFKit first places it as far again below, past the top of the scroll range
    /// (it counts the bar's inset twice), where it stays until touched.
    private func toTop() {
        guard let scroll = Self.scrollView(in: pdfView), scroll.contentOffset.y < -scroll.adjustedContentInset.top
        else { return }
        scroll.contentOffset.y = -scroll.adjustedContentInset.top
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
        thumbnails.current = document.index(for: page)
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
        // Pages already shown have their overlays.
        pen.refreshAll()
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: pdfView)
        guard let page = pdfView.page(for: location, nearest: false) else { return }
        let point = pdfView.convert(location, to: page)
        let reach = 10 / max(0.1, pdfView.scaleFactor)
        let marks = page.annotations.reversed().compactMap { $0 as? MarkAnnotation }
        // Marks made where the paper's PDF is known can be changed; others only show their note.
        if marksAllowed, let hit = marks.first(where: { $0.mark.editable && $0.touches(point, reach: reach) }) {
            let editor = MarkEditor(mark: hit.mark) { [weak self, weak hit] color, body in
                guard let self, let hit else { return }
                self.change(hit, on: page, color: color, body: body)
            } delete: { [weak self, weak hit] in
                guard let self, let hit else { return }
                self.pen.remove([(hit, page)])
                self.dismiss(animated: true)
            }
            popover(editor, from: pdfView.convert(hit.bounds, from: page), width: 380)
        } else if let hit = marks.first(where: { $0.mark.hasNote && $0.touches(point, reach: reach) }) {
            popover(MarkNote(mark: hit.mark), from: pdfView.convert(hit.bounds, from: page), width: 380)
        }
    }

    private func popover<Content: View>(_ content: Content, from rect: CGRect, width: CGFloat) {
        guard presentedViewController == nil else { return }
        let host = UIHostingController(rootView: content)
        host.modalPresentationStyle = .popover
        let size = host.sizeThatFits(in: CGSize(width: width, height: 560))
        host.preferredContentSize = CGSize(width: width, height: min(560, max(80, size.height)))
        host.popoverPresentationController?.sourceView = pdfView
        host.popoverPresentationController?.sourceRect = rect
        host.popoverPresentationController?.permittedArrowDirections = [.up, .down, .left, .right]
        present(host, animated: true)
    }

    // MARK: Highlights and comments

    /// Highlights and comments can be made (the paper's PDF is known, as for drawing).
    var marksAllowed = false
    /// A mark's color or note changed here.
    var onMarkChanged: ((String, String, String) -> Void)?

    /// Highlight and Comment… beside Copy, for selected text.
    /// The selected text explained by the AI, or attached to a question for it.
    var onExplain: ((String) -> Void)?
    var onAskAbout: ((String) -> Void)?

    fileprivate func selectionActions() -> [UIMenuElement] {
        guard let selection = pdfView.currentSelection,
              case let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return [] }
        var actions: [UIMenuElement] = []
        if marksAllowed {
            actions += [
                UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in
                    self?.highlightSelection()
                },
                UIAction(title: "Comment…", image: UIImage(systemName: "text.bubble")) { [weak self] _ in
                    self?.commentOnSelection()
                },
            ]
        }
        if onExplain != nil {
            actions += [
                UIAction(title: "Explain", image: UIImage(systemName: "sparkles")) { [weak self] _ in
                    self?.onExplain?(text)
                },
                UIAction(title: "Ask AI…", image: UIImage(systemName: "bubble.left.and.text.bubble.right")) { [weak self] _ in
                    self?.onAskAbout?(text)
                },
            ]
        }
        return actions
    }

    func highlightSelection() {
        guard let selection = pdfView.currentSelection, let document = pdfView.document else { return }
        let rows = TextMarks.rows(for: selection, in: document, kind: "highlight", color: TextMarks.color)
        pen.place(rows, named: "Highlight")
        if !rows.isEmpty { pdfView.clearSelection() }
    }

    func commentOnSelection() {
        guard let selection = pdfView.currentSelection, let page = selection.pages.first else { return }
        let quote = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let anchor = pdfView.convert(selection.bounds(for: page), from: page)
        let composer = CommentComposer(quote: quote) { [weak self] body, color in
            guard let self, let document = self.pdfView.document else { return }
            TextMarks.color = color
            let rows = TextMarks.rows(for: selection, in: document, kind: "comment", color: color, body: body)
            self.pen.place(rows, named: "Comment")
            if !rows.isEmpty { self.pdfView.clearSelection() }
            self.dismiss(animated: true)
        } cancel: { [weak self] in
            self?.dismiss(animated: true)
        }
        popover(composer, from: anchor, width: 400)
    }

    /// A mark's color and note as changed in its editor: the mark is drawn again with them and reported.
    func change(_ annotation: MarkAnnotation, on page: PDFPage, color: String, body: String) {
        let old = annotation.mark
        guard page.annotations.contains(where: { $0 === annotation }),
              PenTool.hex(nearest: old.color) != color || old.body != body else { return }
        TextMarks.color = color
        page.removeAnnotation(annotation)
        page.addAnnotation(MarkAnnotation(mark: old.with(color: color, body: body), geometry: annotation.geometry,
                                          picture: nil))
        pen.refresh(page)
        onMarkChanged?(old.id, color, body)
    }

    // MARK: The paper's marks

    /// Every mark on the paper, page by page from the top of each.
    func allMarks() -> [Mark] {
        guard let document = pdfView.document else { return [] }
        return (0..<document.pageCount).flatMap { index -> [Mark] in
            guard let page = document.page(at: index) else { return [] }
            return page.annotations.compactMap { ($0 as? MarkAnnotation)?.mark }
                .sorted { ($0.extent.minY, $0.extent.minX) < ($1.extent.minY, $1.extent.minX) }
        }
    }

    /// Shows a mark a little below the top of the view.
    func go(to mark: Mark) {
        guard let page = pdfView.document?.page(at: mark.page) else { return }
        go(to: page, y: max(0, mark.extent.minY - 0.04))
    }

    /// Deletes a mark (one step in the history).
    func delete(_ mark: Mark) {
        guard let page = pdfView.document?.page(at: mark.page),
              let annotation = page.annotations.compactMap({ $0 as? MarkAnnotation }).first(where: { $0.mark.id == mark.id })
        else { return }
        pen.remove([(annotation, page)])
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func undoTapped() { onUndo?() }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if gesture === eraser { return pen.tool == .eraser }
        if gesture === marker, case .highlighter = pen.tool { return marksAllowed }
        return gesture !== marker
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

    // MARK: The highlighter

    /// The Pencil passes over the text with the highlighter: the text from where it went down to where it is now is
    /// selected as it goes, and highlighted when it lifts.
    @objc private func marking(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: pdfView), moved = gesture.translation(in: pdfView)
        switch gesture.state {
        case .began:
            // The pan begins a little after the Pencil went down: the text from there.
            beginMarking(at: CGPoint(x: location.x - moved.x, y: location.y - moved.y))
            markText(to: location)
        case .changed:
            markText(to: location)
        case .ended:
            markText(to: location)
            finishMarking()
        default:
            markedFrom = nil
            pdfView.clearSelection()
        }
    }

    func beginMarking(at point: CGPoint) {
        guard let page = pdfView.page(for: point, nearest: true) else { return }
        markedFrom = (page, pdfView.convert(point, to: page))
    }

    func markText(to point: CGPoint) {
        guard let start = markedFrom, let document = pdfView.document,
              let page = pdfView.page(for: point, nearest: true) else { return }
        let selection = document.selection(from: start.page, at: start.point, to: page, at: pdfView.convert(point, to: page))
        if let selection, !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pdfView.setCurrentSelection(selection, animate: false)
        } else {
            pdfView.clearSelection()
        }
    }

    func finishMarking() {
        defer { markedFrom = nil }
        guard markedFrom != nil, let selection = pdfView.currentSelection, let document = pdfView.document,
              case let .highlighter(color) = pen.tool else { return pdfView.clearSelection() }
        pen.place(TextMarks.rows(for: selection, in: document, kind: "highlight", color: color), named: "Highlight")
        pdfView.clearSelection()
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

    private static func recognizers(in view: UIView, outside skipped: UIView.Type? = nil) -> [UIGestureRecognizer] {
        if let skipped, view.isKind(of: skipped) { return [] }
        return (view.gestureRecognizers ?? []) + view.subviews.flatMap { recognizers(in: $0, outside: skipped) }
    }
}

/// PDFKit's view, telling when it has been laid out (its size comes from the stack it is in, after the controller's
/// own layout pass).
final class PageView: PDFView {
    var laidOut: (() -> Void)?
    /// Items beside Copy in the menu of selected text.
    var selectionActions: (() -> [UIMenuElement])?

    override func layoutSubviews() {
        super.layoutSubviews()
        laidOut?()
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context, let items = selectionActions?(), !items.isEmpty else { return }
        builder.insertSibling(UIMenu(options: .displayInline, children: items), afterMenu: .standardEdit)
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
