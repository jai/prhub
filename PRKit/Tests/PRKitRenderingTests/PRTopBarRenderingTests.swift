#if os(iOS)
    import Foundation
    @testable import PRKit
    import SwiftUI
    import Testing
    import UIKit

    /// A PR's page scrolled under its title: none of the page's words can be read there. Jai's picture (2026-11-26, an
    /// iPad, the PR beside the list): the description had scrolled up under the title, and neither could be read. The
    /// page is drawn under its bar in a window of the host app and scrolled up under the bar a little at a time; after
    /// each step the bar beside the title, where the page's words pass, is one flat colour. In light and dark, and in
    /// the largest text. Each keeps its pictures.
    ///
    /// On iOS only: the bar is the system's, and a Mac window's toolbar is solid already (`titleClearOfThePage`).
    @MainActor
    @Suite(.serialized)
    struct PRTopBarRenderingTests {
        private static let size = CGSize(width: 393, height: 852)
        /// How far apart the lightest and darkest points beside the title may be, of 1: on a screen, words there were
        /// 0.078 and more, a solid bar 0.024 at most.
        private static let flat = 0.04

        private static let body = (1 ... 8)
            .map { "Paragraph \($0): a failed payment now shows a Retry button, and a retry goes through retryPayment." }
            .joined(separator: "\n\n")

        enum Look: String, CaseIterable {
            case light, dark
            case largestLight = "largest-light"

            var scheme: ColorScheme {
                self == .dark ? .dark : .light
            }

            var textSize: DynamicTypeSize {
                self == .largestLight ? .accessibility5 : .large
            }
        }

        @Test(arguments: Look.allCases)
        func noWordsShowUnderThePRsTitle(_ look: Look) async throws {
            let name = look.rawValue
            let detail = try PRSamplePage.detail(
                opened: .now.addingTimeInterval(-3 * 86400), tickets: [PRSamplePage.ticket], body: Self.body
            )
            let (session, _) = try await PRSamplePage.session(detail)
            // The page under its title, as `PRScreen` shows it.
            let page = NavigationStack {
                PRDescriptionView(session: session, detail: detail, showDiff: {}, reviewChanges: {})
                    .navigationTitle(session.label)
                    .inlineNavigationTitle()
            }
            .environment(\.loadsAuthorAvatars, false)
            let window = try DrawnWindow(page, size: Self.size, in: look.scheme, textSize: look.textSize)
            defer { window.close() }
            let atRest = try await window.picture(named: "top-bar-\(name)-1-top")

            // Beside the title, which is centred in a bar with no Back: the bar's leading fifth, where the page's
            // title and its cards pass under. Clear of the bar's own edges.
            let bar = window.views(UINavigationBar.self).first.map { $0.convert($0.bounds, to: window.window) }
                ?? CGRect(x: 0, y: window.window.safeAreaInsets.top, width: Self.size.width, height: 44)
            let beside = CGRect(x: 16, y: bar.minY + 6, width: Self.size.width / 5, height: bar.height - 12)
            try #require(beside.height >= 16, "a bar to look at: \(bar)")
            #expect(spread(in: beside, of: atRest, in: window) <= Self.flat, "at rest the bar is one colour")

            var worst = 0.0
            for _ in 0 ..< 10 {
                try window.scroll(by: 20)
                let picture = try await window.picture()
                worst = max(worst, spread(in: beside, of: picture, in: window))
            }
            _ = try await window.picture(named: "top-bar-\(name)-2-scrolled")
            #expect(try window.scrolled() >= 80, "the page's heading has scrolled up under the title")
            #expect(worst <= Self.flat, "\(name): the page's words show beside the title, under it: \(worst)")
        }

        /// How far apart the lightest and darkest points in `rect` of the window's `picture` are, of 1, leaving out
        /// the odd point in a hundred at each end.
        private func spread(in rect: CGRect, of picture: Bitmap, in window: DrawnWindow) -> Double {
            let scale = window.scale(of: picture)
            let columns = Int(rect.minX * scale) ..< min(Int(rect.maxX * scale), picture.width)
            let rows = Int(rect.minY * scale) ..< min(Int(rect.maxY * scale), picture.height)
            var greys: [Int] = []
            for row in rows {
                for column in columns {
                    let pixel = picture[column, row]
                    greys.append((pixel.red + pixel.green + pixel.blue) / 3)
                }
            }
            greys.sort()
            guard greys.count > 1 else {
                return 1
            }
            let cut = greys.count / 100
            return Double(greys[greys.count - 1 - cut] - greys[cut]) / 255
        }
    }
#endif
