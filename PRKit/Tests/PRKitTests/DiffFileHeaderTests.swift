import Foundation
import Testing
@testable import PRKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The file header's path at big text sizes: it shrinks before it is cut, never below the code's size, and is cut from
/// the front, so the file's name is what shows. The fit is the phone's and the Mac's; the label is the phone's.
@MainActor
struct DiffFileHeaderTests {
    private static let longPath = "zero-trust/cloudflare/access/deploy_memberships.tf"
    /// Jai's text size, the largest without the accessibility sizes.
    private let metrics = DiffMetrics(.standard, scale: 23.0 / 17.0)

    @Test func aPathThatFitsKeepsTheHeadersSize() {
        let path = "src/cart/store.ts"
        let font = metrics.headerPath(fitting: path, in: width(of: path, in: metrics.headerPath))
        #expect(font.pointSize == metrics.headerPath.pointSize)
    }

    @Test func aPathThatFitsAtTheCodesSizeShrinksToFitWhole() {
        let name = "…deploy_memberships.tf"
        let room = width(of: name, in: bold(metrics.code.pointSize)) + 1
        #expect(width(of: name, in: metrics.headerPath) > room, "cut at the header's size")
        let font = metrics.headerPath(fitting: name, in: room)
        #expect(font.pointSize < metrics.headerPath.pointSize)
        #expect(font.pointSize >= metrics.code.pointSize)
        #expect(width(of: name, in: font) <= room, "the whole file name shows")
    }

    @Test func aPathTooLongEvenAtTheCodesSizeStopsThere() {
        let font = metrics.headerPath(fitting: Self.longPath, in: 100)
        #expect(font.pointSize == metrics.code.pointSize, "as small as it goes; the label cuts it from the front")
    }

    #if os(iOS)
    /// On an iPhone 17's width, at Jai's size: the header's label shows the long path's whole file name.
    @Test func atJaisSizeTheHeaderShowsTheLongPathsFileName() throws {
        let metrics = DiffMetrics(
            .standard, traits: UITraitCollection(preferredContentSizeCategory: .extraExtraExtraLarge)
        )
        let header = DiffFileHeader(reuseIdentifier: DiffFileHeader.identifier)
        let file = DiffRows.File(path: Self.longPath, change: .init(added: 150, removed: 0), rows: [])
        header.configure(file, section: 0, isCollapsed: false, isViewed: false, metrics: metrics)
        header.pin(toVisibleWidth: 402, offsetX: 0)
        let path = try #require(labels(in: header).first { $0.accessibilityIdentifier == "file-header-0" })
        let name = "…" + (Self.longPath as NSString).lastPathComponent
        #expect(width(of: name, in: metrics.headerPath) > path.bounds.width, "the case this is for: cut on main")
        #expect(width(of: name, in: path.font) <= path.bounds.width)
        #expect(path.lineBreakMode == .byTruncatingHead)
    }

    private func labels(in view: UIView) -> [UILabel] {
        view.subviews.flatMap { ($0 as? UILabel).map { [$0] } ?? labels(in: $0) }
    }
    #endif

    private func bold(_ size: CGFloat) -> PlatformFont {
        metrics.font.platformFont(points: size, isBold: true)
    }

    private func width(of text: String, in font: PlatformFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
