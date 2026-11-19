#if os(iOS)
    import PRKitCore
    import PRKitDesign
    import SwiftUI
    import UIKit

    final class DiffLineCell: UITableViewCell {
        static let identifier = "line"
        let label = UILabel()
        let oldNumber = UILabel()
        let newNumber = UILabel()
        private var numberWidth: CGFloat = 0

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            selectionStyle = .none
            label.lineBreakMode = .byClipping
            for number in [oldNumber, newNumber] {
                number.textAlignment = .right
                number.textColor = .secondaryLabel
                contentView.addSubview(number)
            }
            contentView.addSubview(label)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("not used from a storyboard")
        }

        func configure(line: DiffDocument.Line, text: String, metrics: DiffMetrics, digits: Int) {
            for field in [label, oldNumber, newNumber] {
                field.font = metrics.code
            }
            label.text = text
            oldNumber.text = line.oldLine > 0 ? String(line.oldLine) : ""
            newNumber.text = line.newLine > 0 ? String(line.newLine) : ""
            oldNumber.accessibilityLabel = line.oldLine > 0 ? "Old line \(line.oldLine)" : nil
            newNumber.accessibilityLabel = line.newLine > 0 ? "New line \(line.newLine)" : nil
            numberWidth = metrics.lineNumberWidth(digits: digits)
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let step = numberWidth + DiffStyle.lineNumberGap
            let inset = DiffStyle.lineInset
            oldNumber.frame = CGRect(x: inset, y: 0, width: numberWidth, height: contentView.bounds.height)
            newNumber.frame = oldNumber.frame.offsetBy(dx: step, dy: 0)
            let codeX = inset + step * 2
            label.frame = CGRect(x: codeX, y: 0, width: max(0, contentView.bounds.width - codeX - inset), height: contentView.bounds.height)
        }
    }

    /// A file's header: it sticks to the top while its file scrolls, and a tap folds the file. The table is wider than the
    /// screen, so `bar` is held to the visible width and moved back as the table scrolls sideways. A path too long for
    /// its room scrolls sideways in it, opening on the file's name at its end (Jai's feedback, build 305).
    final class DiffFileHeader: UITableViewHeaderFooterView {
        static let identifier = "file"
        private let bar = UIView()
        private let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))
        /// The path's room: the header's button for accessibility, holding the scroll the path moves in. A scroll view
        /// is always a scroll view to XCUITest and VoiceOver, never a button, and a scrolled label's frame runs off the
        /// screen.
        private let pathRoom = UIView()
        private let pathScroll = UIScrollView()
        private let path = UILabel()
        private let change = UILabel()
        private let viewed = UIButton(type: .system)
        private var isViewed = false
        private var metrics: DiffMetrics?
        /// The width the path's size was fitted to: fitted again only when it changes, not on every sideways scroll.
        private var fittedWidth: CGFloat?
        var onTap: () -> Void = {}
        var onViewed: (Bool) -> Void = { _ in }

        override init(reuseIdentifier: String?) {
            super.init(reuseIdentifier: reuseIdentifier)
            contentView.backgroundColor = .clear
            bar.backgroundColor = .secondarySystemBackground
            chevron.tintColor = .secondaryLabel
            // Drawn at its symbol size, never scaled to its box: turned, the box would hand it the row's height.
            chevron.contentMode = .center
            path.lineBreakMode = .byClipping
            pathScroll.showsHorizontalScrollIndicator = false
            pathScroll.showsVerticalScrollIndicator = false
            pathScroll.alwaysBounceVertical = false
            pathScroll.scrollsToTop = false
            pathScroll.addSubview(path)
            pathRoom.addSubview(pathScroll)
            change.textAlignment = .right
            viewed.addTarget(self, action: #selector(viewedTapped), for: .touchUpInside)
            for view in [chevron, pathRoom, change, viewed] {
                bar.addSubview(view)
            }
            contentView.addSubview(bar)
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
            pathRoom.isAccessibilityElement = true
            pathRoom.accessibilityTraits = .button
            accessibilityElements = [pathRoom, viewed]
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
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
            fittedWidth = nil
            let text = NSMutableAttributedString(
                string: "+\(file.change.added)", attributes: [.foregroundColor: UIColor.systemGreen]
            )
            text.append(NSAttributedString(
                string: " −\(file.change.removed)", attributes: [.foregroundColor: UIColor.systemRed]
            ))
            change.attributedText = text
            pathRoom.accessibilityLabel = file.path
            pathRoom.accessibilityIdentifier = "file-header-\(section)"
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
            pathRoom.accessibilityValue = isCollapsed ? "collapsed" : "open"
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
            let room = max(0, change.frame.minX - pathX - Space.md)
            pathRoom.frame = CGRect(x: pathX, y: 0, width: room, height: height)
            pathScroll.frame = pathRoom.bounds
            if fittedWidth != room {
                fittedWidth = room
                path.font = metrics.headerPath(fitting: path.text ?? "", in: room)
                let width = max(room, ceil(path.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: height)).width))
                path.frame = CGRect(x: 0, y: 0, width: width, height: height)
                pathScroll.contentSize = path.frame.size
                pathScroll.contentOffset = CGPoint(x: width - room, y: 0)
            }
        }

        @objc private func tapped() {
            onTap()
        }

        @objc private func viewedTapped() {
            onViewed(!isViewed)
        }
    }

    /// A row SwiftUI draws (a thread, a draft, a key line's note), moved by the table's sideways scroll so it stays on
    /// screen. Kept here, not only set from outside: the cell lays its content view out again on its own, and a frame set
    /// under a transform is undefined, so the move comes off for the layout and goes back after it.
    final class DiffHostedCell: UITableViewCell {
        var offsetX: CGFloat = 0 {
            didSet {
                if offsetX != oldValue {
                    setNeedsLayout()
                }
            }
        }

        override func layoutSubviews() {
            contentView.transform = .identity
            super.layoutSubviews()
            contentView.transform = CGAffineTransform(translationX: offsetX, y: 0)
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

        func makeUIView(context _: Context) -> DiffTableContainer {
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
