#if os(iOS)
import Testing
import UIKit
@testable import PRKit

/// The file header's path at big text sizes: it shrinks before it is cut, never below the code's size, and is cut from
/// the front, so the file's name is what shows. On an iPhone 17's width.
@MainActor
struct DiffFileHeaderTests {
    private static let width: CGFloat = 402
    private static let longPath = "zero-trust/cloudflare/access/deploy_memberships.tf"

    @Test func aPathThatFitsKeepsTheHeadersSize() throws {
        let metrics = DiffMetrics(.standard, traits: UITraitCollection(preferredContentSizeCategory: .large))
        let path = try pathLabel("src/cart/store.ts", metrics: metrics)
        #expect(path.font.pointSize == metrics.headerPath.pointSize)
    }

    /// Jai's text size, the largest without the accessibility sizes, and the largest of all.
    @Test(arguments: [UIContentSizeCategory.extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge])
    func aLongPathShowsItsWholeFileNameWhenItFitsAtTheCodesSize(size: UIContentSizeCategory) throws {
        let metrics = DiffMetrics(.standard, traits: UITraitCollection(preferredContentSizeCategory: size))
        let path = try pathLabel(Self.longPath, metrics: metrics)
        let name = "…" + (Self.longPath as NSString).lastPathComponent
        let floor = metrics.font.platformFont(points: metrics.code.pointSize, isBold: true)
        #expect(path.font.pointSize >= metrics.code.pointSize, "never smaller than the code")
        if width(of: name, in: floor) <= path.bounds.width {
            #expect(width(of: name, in: metrics.headerPath) > path.bounds.width, "the case this is for: it is cut today")
            #expect(path.font.pointSize < metrics.headerPath.pointSize)
            #expect(width(of: name, in: path.font) <= path.bounds.width, "the whole file name shows")
        } else {
            #expect(path.font.pointSize == metrics.code.pointSize, "as small as it goes, then cut from the front")
            #expect(path.lineBreakMode == .byTruncatingHead)
        }
    }

    @Test func atJaisSizeTheLongPathsFileNameFits() throws {
        let metrics = DiffMetrics(
            .standard, traits: UITraitCollection(preferredContentSizeCategory: .extraExtraExtraLarge)
        )
        let path = try pathLabel(Self.longPath, metrics: metrics)
        let name = "…" + (Self.longPath as NSString).lastPathComponent
        #expect(width(of: name, in: path.font) <= path.bounds.width)
    }

    private func pathLabel(_ path: String, metrics: DiffMetrics) throws -> UILabel {
        let header = DiffFileHeader(reuseIdentifier: DiffFileHeader.identifier)
        let file = DiffRows.File(path: path, change: .init(added: 150, removed: 0), rows: [])
        header.configure(file, section: 0, isCollapsed: false, isViewed: false, metrics: metrics)
        header.pin(toVisibleWidth: Self.width, offsetX: 0)
        return try #require(labels(in: header).first { $0.accessibilityIdentifier == "file-header-0" })
    }

    private func labels(in view: UIView) -> [UILabel] {
        view.subviews.flatMap { ($0 as? UILabel).map { [$0] } ?? labels(in: $0) }
    }

    private func width(of text: String, in font: UIFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
#endif
