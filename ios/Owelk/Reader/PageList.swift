import PDFKit
import UIKit

/// The pages at the side as small pictures: the page being read is marked, and a tap goes to a page. PDFKit's own
/// thumbnail view (`PDFThumbnailView`) moved the pages to the current page's top whenever it laid itself out (after
/// every pen stroke, page turn and zoom, even while hidden), so the reader keeps its own, which moves nothing.
@MainActor
final class PageList: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    private struct Shared<Value>: @unchecked Sendable { let value: Value }

    private final class Cell: UICollectionViewCell {
        let picture = UIImageView()
        let number = UILabel()
        /// The page's width over its height, as shown.
        var aspect: CGFloat = 0.77

        override init(frame: CGRect) {
            super.init(frame: frame)
            picture.contentMode = .scaleAspectFit
            // Pages are paper-white in dark mode too.
            picture.backgroundColor = .white
            number.font = .preferredFont(forTextStyle: .caption2)
            number.textColor = .secondaryLabel
            number.textAlignment = .center
            contentView.addSubview(picture)
            contentView.addSubview(number)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            let area = CGRect(x: 0, y: 0, width: contentView.bounds.width, height: contentView.bounds.height - 18)
            let width = min(area.width, area.height * aspect), height = width / max(0.1, aspect)
            picture.frame = CGRect(x: area.midX - width / 2, y: area.maxY - height, width: width, height: height)
            number.frame = CGRect(x: 0, y: area.maxY + 2, width: contentView.bounds.width, height: 16)
        }

        func mark(_ current: Bool) {
            picture.layer.borderColor = (current ? Theme.accentUI : UIColor.separator).cgColor
            picture.layer.borderWidth = current ? 2 : 1 / max(1, traitCollection.displayScale)
            number.textColor = current ? Theme.accentUI : .secondaryLabel
        }
    }

    private static let item = CGSize(width: 96, height: 146)
    private let list: UICollectionView
    private let pictures = NSCache<NSNumber, UIImage>()
    private var drawing: Set<Int> = []
    private let queue = DispatchQueue(label: "org.owelk.pad.pages", qos: .userInitiated)

    /// A page tapped.
    var chosen: ((Int) -> Void)?

    var document: PDFDocument? {
        didSet {
            pictures.removeAllObjects()
            drawing = []
            current = 0
            list.reloadData()
        }
    }

    /// The page being read.
    var current = 0 {
        didSet {
            guard current != oldValue else { return }
            for case let cell as Cell in list.visibleCells {
                if let path = list.indexPath(for: cell) { cell.mark(path.item == current) }
            }
            if !isHidden && window != nil { reveal(animated: true) }
        }
    }

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = Self.item
        layout.minimumLineSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        list = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        pictures.countLimit = 80
        list.backgroundColor = .clear
        list.dataSource = self
        list.delegate = self
        list.register(Cell.self, forCellWithReuseIdentifier: "page")
        list.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        list.frame = bounds
        addSubview(list)
    }

    required init?(coder: NSCoder) { nil }

    /// Scrolls the list (only the list) to the page being read, when it is out of sight.
    func reveal(animated: Bool) {
        guard current < list.numberOfItems(inSection: 0) else { return }
        let path = IndexPath(item: current, section: 0)
        if let frame = list.layoutAttributesForItem(at: path)?.frame,
           list.bounds.inset(by: list.adjustedContentInset).contains(frame) { return }
        list.scrollToItem(at: path, at: .centeredVertically, animated: animated)
    }

    func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        document?.pageCount ?? 0
    }

    func collectionView(_ view: UICollectionView, cellForItemAt path: IndexPath) -> UICollectionViewCell {
        let cell = view.dequeueReusableCell(withReuseIdentifier: "page", for: path) as! Cell
        let index = path.item
        cell.number.text = "\(index + 1)"
        cell.accessibilityLabel = "Page \(index + 1)"
        if let page = document?.page(at: index) {
            let size = PageGeometry(page).shownSize
            cell.aspect = size.width / max(1, size.height)
        }
        cell.picture.image = picture(index)
        cell.mark(index == current)
        cell.setNeedsLayout()
        return cell
    }

    func collectionView(_ view: UICollectionView, didSelectItemAt path: IndexPath) {
        view.deselectItem(at: path, animated: false)
        chosen?(path.item)
    }

    /// A page's picture, drawn off the main thread the first time it is asked for.
    private func picture(_ index: Int) -> UIImage? {
        if let picture = pictures.object(forKey: index as NSNumber) { return picture }
        guard !drawing.contains(index), let page = document?.page(at: index) else { return nil }
        drawing.insert(index)
        let scale = max(1, traitCollection.displayScale)
        let size = CGSize(width: Self.item.width * scale, height: (Self.item.height - 18) * scale)
        let shared = Shared(value: page), owner = document.map { Shared(value: $0) }
        queue.async { [weak self] in
            let image = Shared(value: shared.value.thumbnail(of: size, for: .cropBox))
            DispatchQueue.main.async {
                guard let self, self.document === owner?.value else { return }
                self.drawing.remove(index)
                self.pictures.setObject(image.value, forKey: index as NSNumber)
                if let cell = self.list.cellForItem(at: IndexPath(item: index, section: 0)) as? Cell {
                    cell.picture.image = image.value
                }
            }
        }
        return nil
    }
}
