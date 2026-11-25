import Foundation
@testable import PRKit
import SwiftUI
import Testing

// The red clock under the avatar of a review past its SLA, drawn as the PRs list draws a row on the phone and the
// iPad. Jai, 2026-11-25: "We lost the SLA overdue red clock in PR Hub, it seems, in the list of PRs. I can't tell
// which are over SLA."
//
// In the app's own test host only: the tones are the host's colour sets, so under `swift test` on the Mac the mark is
// clear and nothing can be measured. The Mac's card has the same check on a real window (`PRHubMacListUITests`).
#if os(iOS)
    @MainActor
    struct PRPastSLAMarkRenderingTests {
        private static let width: CGFloat = 400
        private static let scale: CGFloat = 2
        private static let now = Date(timeIntervalSince1970: 1_800_000_000)

        /// A row of the PRs list for a review due `dueHoursAgo` hours ago (in the future when negative), or with no due
        /// time at all.
        private static func row(dueHoursAgo: Double?) -> some View {
            let status = PullRequestStatus(
                repo: "acme/api", number: 88, url: "https://github.com/acme/api/pull/88",
                title: "Rate-limit the password reset endpoint", state: .open, checks: .passing, merge: .clean,
                review: .required
            )
            let pullRequest = PRListPullRequest(
                status: status, author: "hubot", jaiReviewRequested: true, found: true,
                reviewDueAt: dueHoursAgo.map { now.addingTimeInterval(-$0 * 3600) }
            )
            return PrListBlock(item: PRListItem(pullRequests: [pullRequest]), id: "88", sentAt: now, now: now, folds: FoldSet())
                .prListRow(isSelected: false)
                .background(Color.groundList)
        }

        /// Drawn in a window of the host app, not by `ImageRenderer`, which draws a row's button as a placeholder.
        private func render(_ name: String, _ view: some View, in scheme: ColorScheme) throws -> Bitmap {
            let content = view
                .frame(width: Self.width)
                .environment(\.colorScheme, scheme)
                .environment(\.loadsAuthorAvatars, false)
                .ignoresSafeArea()
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let controller = UIHostingController(rootView: content)
            controller.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            let size = controller.sizeThatFits(in: CGSize(width: Self.width, height: .infinity))
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = controller
            controller.additionalSafeAreaInsets = .zero
            window.isHidden = false
            defer {
                window.isHidden = true
                window.rootViewController = nil
                window.windowScene = nil
            }
            window.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = Self.scale
            var drawn = false
            let picture = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try #require(drawn, "the row was drawn")
            try Attachment.record(#require(picture.pngData()), named: "\(name)-\(scheme).png")
            return try Bitmap(#require(picture.cgImage))
        }

        /// The pixels in the row's avatar column that are the bad tone: the mark's clock and its age.
        private func redInAvatarColumn(_ bitmap: Bitmap, in scheme: ColorScheme) -> [(column: Int, row: Int)] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let red = Pixel(Color.toneBad.resolve(in: environment))
            let inset = Space.lg
            let columns = Int(inset * Self.scale) ..< Int((inset + PrListGrid.avatar) * Self.scale)
            var found: [(column: Int, row: Int)] = []
            for row in 0 ..< bitmap.height {
                for column in columns where bitmap[column, row].distance(to: red) <= 24 {
                    found.append((column, row))
                }
            }
            return found
        }

        @Test(arguments: [ColorScheme.light, .dark])
        func aReviewPastItsSLAHasTheRedClockAndItsAgeUnderTheAvatar(_ scheme: ColorScheme) throws {
            let late = try render("past-sla", Self.row(dueHoursAgo: 26), in: scheme)
            let red = redInAvatarColumn(late, in: scheme)
            #expect(red.count >= 40, "the red clock and its age are drawn under the avatar: \(red.count) red pixels")
            // Under the avatar, not over it: below the block's top padding and the avatar.
            let underAvatar = Int((Space.md + PrListGrid.avatar) * Self.scale)
            #expect((red.map(\.row).min() ?? 0) >= underAvatar, "the mark starts under the avatar")
            // A clock and a line of text: the mark is taller than it is a dot.
            let rows = Set(red.map(\.row))
            #expect((rows.max() ?? 0) - (rows.min() ?? 0) >= Int(16 * Self.scale), "a clock with its age under it")
        }

        @Test(arguments: [ColorScheme.light, .dark])
        func aReviewNotYetDueOrWithNoDueTimeHasNoClock(_ scheme: ColorScheme) throws {
            for due in [-2.0, nil] {
                let row = try render(due == nil ? "no-due-time" : "not-yet-due", Self.row(dueHoursAgo: due), in: scheme)
                #expect(redInAvatarColumn(row, in: scheme).isEmpty, "no red under the avatar, due \(String(describing: due))")
            }
        }
    }
#endif
