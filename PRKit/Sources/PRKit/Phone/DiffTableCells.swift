#if os(iOS)
import PRKitCore
import PRKitDesign
import SwiftUI
import UIKit

final class DiffLineCell: UITableViewCell {
    static let identifier = "line"
    let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        label.lineBreakMode = .byClipping
        label.frame = contentView.bounds.insetBy(dx: 6, dy: 0)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used from a storyboard")
    }
}

/// A file's header: it sticks to the top while its file scrolls, and a tap folds the file. The table is wider than the
/// screen, so `bar` is held to the visible width and moved back as the table scrolls sideways.
final class DiffFileHeader: UITableViewHeaderFooterView {
    static let identifier = "file"
    private let bar = UIView()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))
    private let path = UILabel()
    private let change = UILabel()
    private let viewed = UIButton(type: .system)
    private var isViewed = false
    private var metrics: DiffMetrics?
    var onTap: () -> Void = {}
    var onViewed: (Bool) -> Void = { _ in }

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        contentView.backgroundColor = .clear
        bar.backgroundColor = .secondarySystemBackground
        chevron.tintColor = .secondaryLabel
        // Drawn at its symbol size, never scaled to its box: turned, the box would hand it the row's height.
        chevron.contentMode = .center
        path.lineBreakMode = .byTruncatingHead
        change.textAlignment = .right
        viewed.addTarget(self, action: #selector(viewedTapped), for: .touchUpInside)
        for view in [chevron, path, change, viewed] {
            bar.addSubview(view)
        }
        contentView.addSubview(bar)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        path.isAccessibilityElement = true
        path.accessibilityTraits = .button
        accessibilityElements = [path, viewed]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used from a storyboard")
    }

    func configure(
        _ file: DiffRows.File, section: Int, isCollapsed: Bool, isViewed: Bool, metrics: DiffMetrics
    ) {
        self.metrics = metrics
        chevron.preferredSymbolConfiguration = .init(pointSize: metrics.chevronSymbolSize, weight: .semibold)
        path.font = metrics.headerPath
        change.font = metrics.headerChange
        path.text = file.path
        let text = NSMutableAttributedString(
            string: "+\(file.change.added)", attributes: [.foregroundColor: UIColor.systemGreen]
        )
        text.append(NSAttributedString(
            string: " −\(file.change.removed)", attributes: [.foregroundColor: UIColor.systemRed]
        ))
        change.attributedText = text
        path.accessibilityIdentifier = "file-header-\(section)"
        viewed.accessibilityIdentifier = "file-viewed-\(section)"
        setViewed(isViewed)
        setCollapsed(isCollapsed, animated: false)
    }

    func setViewed(_ isViewed: Bool) {
        self.isViewed = isViewed
        let symbol = UIImage(
            systemName: isViewed ? "checkmark.circle.fill" : "circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: metrics?.viewedSymbolSize ?? 0, weight: .regular)
        )
        viewed.setImage(symbol, for: .normal)
        viewed.tintColor = isViewed ? .systemGreen : .secondaryLabel
        viewed.accessibilityLabel = "Viewed"
        viewed.accessibilityValue = isViewed ? "on" : "off"
    }

    func setCollapsed(_ isCollapsed: Bool, animated: Bool) {
        path.accessibilityValue = isCollapsed ? "collapsed" : "open"
        let turn = { self.chevron.transform = CGAffineTransform(rotationAngle: isCollapsed ? -.pi / 2 : 0) }
        if animated {
            UIView.animate(withDuration: 0.28, animations: turn)
        } else {
            turn()
        }
    }

    /// Where the screen is, in the table's sideways scroll. The viewed mark's tap target is a square the row's height
    /// at the right edge, the same viewed or not, so marking a file never moves the path or the counts.
    func pin(toVisibleWidth width: CGFloat, offsetX: CGFloat) {
        guard let metrics else {
            return
        }
        let height = metrics.fileHeaderHeight
        bar.frame = CGRect(x: offsetX, y: 0, width: width, height: height)
        change.sizeToFit()
        let changeWidth = change.bounds.width
        // Bounds and center, not frame: the chevron is turned when folded, and a turned view's frame is undefined.
        let chevronWidth = metrics.chevronSymbolSize + Space.xs
        chevron.bounds = CGRect(x: 0, y: 0, width: chevronWidth, height: height)
        chevron.center = CGPoint(x: Space.sm + chevronWidth / 2, y: height / 2)
        viewed.frame = CGRect(x: width - metrics.viewedTarget, y: 0, width: metrics.viewedTarget, height: height)
        change.frame = CGRect(x: viewed.frame.minX - changeWidth, y: 0, width: changeWidth, height: height)
        let pathX = Space.sm + chevronWidth + Space.sm
        path.frame = CGRect(x: pathX, y: 0, width: change.frame.minX - pathX - Space.md, height: height)
    }

    @objc private func tapped() {
        onTap()
    }

    @objc private func viewedTapped() {
        onViewed(!isViewed)
    }
}

final class ReportingTableView: UITableView {
    var onContent: (() -> Void)?
    /// A fold or a reload changed how tall the diff is.
    var onContentSize: (() -> Void)?

    override var contentSize: CGSize {
        didSet {
            if contentSize.height != oldValue.height {
                onContentSize?()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !visibleCells.isEmpty {
            onContent?()
            onContent = nil
        }
    }
}

struct DiffTableView: UIViewRepresentable {
    let document: DiffDocument
    let rows: DiffRows
    let viewed: Set<String>
    let jump: DiffJump?
    let composing: Int?
    let topInset: CGFloat
    let font: DiffFont
    let onContent: () -> Void
    let actions: DiffActions

    func makeUIView(context: Context) -> DiffTableContainer {
        DiffTableContainer(
            document: document, rows: rows, viewed: viewed, font: font, onContent: onContent, actions: actions
        )
    }

    func updateUIView(_ uiView: DiffTableContainer, context: Context) {
        // `.scrollDisabled` for a diff inside a page that scrolls, Settings' preview: the page takes the swipe.
        uiView.isScrollEnabled = context.environment.isScrollEnabled
        uiView.table.isScrollEnabled = context.environment.isScrollEnabled
        uiView.update(font: font)
        uiView.update(rows: rows)
        uiView.update(viewed: viewed)
        uiView.update(topInset: topInset)
        uiView.update(composing: composing)
        uiView.update(jump: jump)
    }
}
#endif
