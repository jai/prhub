#if os(iOS)
    @testable import PRKit
    import Testing
    import UIKit

    /// A file header's viewed mark on the phone, laid out as the diff lays it out: a 44 pt tap target in every face at the
    /// smallest, default and largest sizes Settings offers; a tap on it is the mark's, not the header's fold; and marking
    /// it moves nothing in the header.
    @MainActor
    struct DiffViewedMarkTests {
        private static let file = DiffRows.File(
            path: "src/checkout/CheckoutError.tsx", change: .init(added: 12, removed: 3), rows: []
        )
        /// An iPhone 17's width.
        private static let width: CGFloat = 402

        private func header(_ font: DiffFont, isViewed: Bool = false) -> DiffFileHeader {
            let header = DiffFileHeader(reuseIdentifier: DiffFileHeader.identifier)
            let metrics = DiffMetrics(font, traits: UITraitCollection(preferredContentSizeCategory: .large))
            header.frame = CGRect(x: 0, y: 0, width: Self.width, height: metrics.fileHeaderHeight)
            header.configure(Self.file, section: 0, isCollapsed: false, isViewed: isViewed, metrics: metrics)
            // As the table does before it shows a header: its content view takes the header's size. Unlaid, the content
            // view is 0 × 0 and every point misses what is in it.
            header.layoutIfNeeded()
            header.pin(toVisibleWidth: Self.width, offsetX: 0)
            return header
        }

        private func viewed(in header: DiffFileHeader) throws -> UIButton {
            try #require(views(in: header).compactMap { $0 as? UIButton }.first {
                $0.accessibilityIdentifier == "file-viewed-0"
            })
        }

        @Test(arguments: DiffFontFace.allCases, [CGFloat(9), 12, 20])
        func theViewedMarkIsA44PointTarget(face: DiffFontFace, size: CGFloat) throws {
            let mark = try viewed(in: header(DiffFont(face: face, size: size)))
            #expect(mark.bounds.width >= DiffMetrics.minimumTapTarget, "\(face.rawValue) \(size)")
            #expect(mark.bounds.height >= DiffMetrics.minimumTapTarget, "\(face.rawValue) \(size)")
        }

        @Test func aTapOnTheMarkIsTheMarksAndMarkingItMovesNothing() throws {
            let font = DiffFont(face: .system, size: 12)
            let open = header(font)
            let mark = try viewed(in: open)
            let center = mark.convert(CGPoint(x: mark.bounds.midX, y: mark.bounds.midY), to: open)
            #expect(open.hitTest(center, with: nil) === mark, "the tap is the mark's, not the header's fold")

            let marked = header(font, isViewed: true)
            #expect(frames(in: marked) == frames(in: open), "the path, the counts and the mark stay put")
        }

        /// The header's words and its mark, where they sit in it.
        private func frames(in header: DiffFileHeader) -> [CGRect] {
            views(in: header).filter { $0 is UILabel || $0 is UIButton }.map { $0.convert($0.bounds, to: header) }
        }

        private func views(in view: UIView) -> [UIView] {
            view.subviews.flatMap { [$0] + views(in: $0) }
        }
    }
#endif
