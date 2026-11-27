import Foundation
@testable import PRKit
import SwiftUI
import Testing

/// The diff's panel over the code, in a phone's window with a bar under it as the tab bar is: the last key line reads
/// clear of the bar once the list is at its end, and so does the Files page's foot. Jai, 2026-11-25, on the phone's
/// Key lines list in dark: the last line was overlapped by the tab bar. In light and dark, at the default text size
/// and the largest. Each keeps its picture.
@MainActor
@Suite(.serialized)
struct PRKeyLinesPanelRenderingTests {
    private static let size = CGSize(width: 393, height: 852)
    /// The bar standing in for the tab bar: a safe area at the window's foot, as tall as a phone's tab bar.
    private static let bar: CGFloat = 83

    /// The panel open over a page, as `PRDiffPage` opens it over the code, with the bar under both.
    private func panel(
        on page: PRNavigatorPage, in scheme: ColorScheme, textSize: DynamicTypeSize
    ) async throws -> DrawnWindow {
        let (session, document) = try await PRSamplePage.session(PRSamplePage.detail())
        session.navigatorPage = page
        let rows = DiffRows(document: document, threads: [])
        let view = Color.clear
            .sidePanel(isPresented: true, close: {}, panel: {
                PRNavigator(session: session, document: document, files: rows.files)
            })
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: Self.bar) }
            .background(Color.groundPage)
        return try DrawnWindow(view, size: Self.size, in: scheme, textSize: textSize)
    }

    /// The lowest row of the picture, in points from its top, with a pixel of `colour` in the panel's columns.
    private func lowest(_ matches: (Pixel) -> Bool, in bitmap: Bitmap, of window: DrawnWindow) -> CGFloat? {
        let scale = window.scale(of: bitmap)
        // The panel is the window's trailing part; its edges and its cards' round corners are left out.
        let columns = Int((Self.size.width * 0.2 + PRStyle.inset * 2) * scale) ..< Int((Self.size.width - PRStyle.inset * 2) * scale)
        for row in (0 ..< bitmap.height).reversed() where columns.contains(where: { matches(bitmap[$0, row]) }) {
            return CGFloat(row + 1) / scale
        }
        return nil
    }

    private func pixel(_ color: Color, in scheme: ColorScheme) -> Pixel {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        return Pixel(color.resolve(in: environment))
    }

    @Test(arguments: [ColorScheme.light, .dark], [DynamicTypeSize.large, .accessibility5])
    func theLastKeyLineEndsAboveTheBar(_ scheme: ColorScheme, _ textSize: DynamicTypeSize) async throws {
        let window = try await panel(on: .keyLines, in: scheme, textSize: textSize)
        defer { window.close() }
        let name = "panel-key-lines-\(scheme)-\(textSize)"
        _ = try await window.picture(named: "\(name)-1-top")
        try window.scroll(by: .infinity)
        let bitmap = try await window.picture(named: "\(name)-2-end")
        #expect(try window.scrolled() > 0, "the list is longer than the panel, and is at its end")

        let card = pixel(.groundCard, in: scheme)
        let foot = try #require(lowest({ $0.isNear(card) }, in: bitmap, of: window), "a key line's card")
        let barTop = Self.size.height - window.footInset - Self.bar
        #expect(foot <= barTop, "the last key line ends at \(foot), above the bar at \(barTop)")
        #expect(foot >= barTop - PRStyle.inset - 2, "and the list is at its end: \(foot)")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func theFilesFootEndsAboveTheBar(_ scheme: ColorScheme) async throws {
        let window = try await panel(on: .files, in: scheme, textSize: .large)
        defer { window.close() }
        let bitmap = try await window.picture(named: "panel-files-\(scheme)")
        let ground = pixel(.groundCard, in: scheme)
        let foot = try #require(lowest({ $0.distance(to: ground) >= 60 }, in: bitmap, of: window), "the foot's words")
        let barTop = Self.size.height - window.footInset - Self.bar
        #expect(foot <= barTop, "the Files page's last line ends at \(foot), above the bar at \(barTop)")
        #expect(foot >= barTop - PRStyle.inset - 8, "and it is the panel's foot: \(foot)")
    }
}
