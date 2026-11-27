import Foundation
@testable import PRKit
import PRKitCore
import SwiftUI
import Testing
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// The repo's labels in the panel over a PR's page, drawn in a window that is never shown, in light and dark: the
/// sample repo's eight labels (`PRSampleSet.sampleLabels`) each as a row with its chip in its own colour, the one the
/// sample PR comes with ticked, and the line that says so where the person may not change them. Each keeps a picture,
/// `labels-<what>-<scheme>.png`.
///
/// A picture can't be read for its words or pressed: which labels are ticked and that a press changes nothing where
/// they can't be changed is `PRLabelsTests`', and `PRKitLabelsUITests` puts one on and takes one off on a real screen.
@MainActor
struct PRLabelsPanelRenderingTests {
    private static let size = CGSize(width: 340, height: 640)

    /// The panel as drawn, and how many of its pixels are a point.
    private struct Drawn {
        let bitmap: Bitmap
        let scale: CGFloat
        let scheme: ColorScheme

        func pixel(_ points: CGFloat) -> Int {
            Int((points * scale).rounded())
        }

        /// The first row from `top` down where a label's chip is written in its colour, right of the ticks.
        func chipRow(_ label: PRRepoLabels.Label, from top: Int = 0) -> Int? {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let color = Pixel(GitHubLabelColor(hex: label.color).readable(dark: scheme == .dark).color.resolve(in: environment))
            return (min(top, bitmap.height) ..< bitmap.height).first { row in
                (pixel(36) ..< bitmap.width).count { bitmap[$0, row].distance(to: color) <= 30 } >= 4
            }
        }

        /// How much ink the tick has in the row whose chip starts at `row`: the pixels unlike the panel's ground, in
        /// the tick's column, from just over the chip to under the row's second line.
        func tickInk(atChip row: Int) -> Int {
            let ground = bitmap[pixel(4), row]
            let rows = max(row - pixel(8), 0) ..< min(row + pixel(34), bitmap.height)
            return rows.reduce(0) { sum, row in
                sum + (pixel(8) ..< pixel(36)).count { bitmap[$0, row].distance(to: ground) >= 60 }
            }
        }
    }

    /// The sample PR's panel with the repo's labels read, drawn in a window of its own that is never on screen:
    /// `ImageRenderer` draws no scroll view and no field.
    private func panel(_ name: String?, canEdit: Bool, in scheme: ColorScheme) async throws -> Drawn {
        let session = try SamplePR.session(labels: PRRepoLabels(labels: PRSampleSet.sampleLabels, canEdit: canEdit))
        await session.loadLabels()
        #expect(session.labelEditing.load == .ready(PRRepoLabels(labels: PRSampleSet.sampleLabels, canEdit: canEdit)))
        let content = PRLabelsPanel(session: session)
            .frame(width: Self.size.width, height: Self.size.height)
            .environment(\.colorScheme, scheme)
        #if os(iOS)
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let controller = UIHostingController(rootView: content.ignoresSafeArea())
            controller.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: Self.size)
            window.rootViewController = controller
            controller.additionalSafeAreaInsets = .zero
            window.isHidden = false
            defer {
                window.isHidden = true
                window.rootViewController = nil
                window.windowScene = nil
            }
            window.layoutIfNeeded()
            // The list's rows are made lazily, a turn of the run loop after the window is laid out.
            try await Task.sleep(for: .milliseconds(100))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            var drawn = false
            let picture = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try #require(drawn, "the panel was drawn")
            let image = try #require(picture.cgImage)
        #else
            let host = NSHostingView(rootView: content)
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            // The list's rows are made lazily, a turn of the run loop after the window is laid out.
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let image = try #require(rep.cgImage)
        #endif
        if let name {
            try SamplePR.keep(image, named: "labels-\(name)-\(scheme)")
        }
        let bitmap = try Bitmap(image)
        return Drawn(bitmap: bitmap, scale: CGFloat(bitmap.width) / Self.size.width, scheme: scheme)
    }

    private func label(_ name: String) throws -> PRRepoLabels.Label {
        try #require(PRSampleSet.sampleLabels.first { $0.name == name })
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func theListShowsTheReposLabelsInTheirColoursWithThePRsTicked(_ scheme: ColorScheme) async throws {
        let panel = try await panel("list", canEdit: true, in: scheme)

        // Every label of the repo, one under the other in the Worker's order, each chip in its own colour.
        var top = 0
        var rows: [String: Int] = [:]
        for label in PRSampleSet.sampleLabels {
            let row = try #require(panel.chipRow(label, from: top), "\(label.name)'s chip, under the one before it")
            rows[label.name] = row
            top = row + panel.pixel(20)
        }
        #expect(rows.count == 8)

        // Under the heading and the field that narrows the list.
        let first = try #require(rows["bug"])
        #expect(first >= panel.pixel(PRStyle.rowHeight + 60), "room for the field over the first row: \(first) px")

        // "sample" is on the PR and no other is: its tick is unlike the open circle the others share.
        let open = try panel.tickInk(atChip: #require(rows["bug"]))
        let alsoOpen = try panel.tickInk(atChip: #require(rows["documentation"]))
        let ticked = try panel.tickInk(atChip: #require(rows["sample"]))
        #expect(open > 0, "an open circle leads a label that is off")
        #expect(abs(open - alsoOpen) <= max(open / 10, 2), "the same on each: \(open), \(alsoOpen)")
        #expect(abs(ticked - open) > open / 3, "the PR's own label is ticked: \(ticked) against \(open)")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func labelsThatCanNotBeChangedSaySoOverTheSameList(_ scheme: ColorScheme) async throws {
        let changed = try await panel(nil, canEdit: true, in: scheme)
        let read = try await panel("read-only", canEdit: false, in: scheme)
        let bug = try label("bug")
        let above = try #require(changed.chipRow(bug)), below = try #require(read.chipRow(bug))
        #expect(below - above >= read.pixel(Space.sm + 10), "a line of words over the list says why: \(below - above) px")

        // The list under it is the same: every label, and the PR's own ticked.
        let sample = try label("sample")
        let open = read.tickInk(atChip: below)
        let ticked = try read.tickInk(atChip: #require(read.chipRow(sample, from: below)))
        #expect(open > 0 && abs(ticked - open) > open / 3, "the PR's own label is ticked: \(ticked) against \(open)")
        #expect(try read.chipRow(label("wontfix"), from: #require(read.chipRow(sample, from: below)) + read.pixel(20)) != nil)
    }
}
