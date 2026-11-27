#if os(iOS)
    import Foundation
    @testable import PRKit
    import Testing
    import UIKit

    /// The sample PR's long lines in a window of the host app, a phone wide: each file's start and the end of its last
    /// long line, in the light and in the dark, and a README in the largest text. Each keeps a picture,
    /// `long-lines-<file>-<light|dark|largest>-<start|end>.png`: the pictures the UI tests took by scrolling the app.
    /// The end of the line is on screen between the screen's sides, as the app shows it once it is scrolled to.
    @MainActor
    @Suite(.serialized)
    struct DiffLongLinePictureTests {
        private static let screen = CGRect(x: 0, y: 0, width: LongLineTable.phoneWidth, height: 874)

        @Test(arguments: ["json", "readme", "code", "tabs", "minified"], [false, true])
        func aFilesLongLinesAreDrawnToTheirEnds(file: String, isDark: Bool) throws {
            let sample = try #require(LongLineSample.files[file])
            try Self.picture(
                "long-lines-\(file)-\(isDark ? "dark" : "light")", of: sample.diff, tail: sample.tail, isDark: isDark
            )
        }

        @Test func aParagraphIsDrawnToItsEndInTheLargestText() throws {
            let sample = try #require(LongLineSample.files["readme"])
            try Self.picture(
                "long-lines-readme-largest", of: sample.diff, tail: "END-OF-SHORT-PARAGRAPH", isDark: false,
                largestText: true
            )
        }

        /// Lays `diff` out in a window, every long line shown whole, pictures its start, scrolls to the end of the line
        /// that ends in `tail`, checks that end is on screen, and pictures it.
        private static func picture(
            _ name: String, of diff: String, tail: String, isDark: Bool, largestText: Bool = false
        ) throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let table = try LongLineTable(diff: diff, showsWhole: true, largestText: largestText)
            let controller = UIViewController()
            let window = UIWindow(windowScene: scene)
            window.frame = screen
            window.overrideUserInterfaceStyle = isDark ? .dark : .light
            if largestText {
                window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            }
            window.rootViewController = controller
            controller.view.backgroundColor = .systemBackground
            table.container.frame = screen
            controller.view.addSubview(table.container)
            // A new text size crossfades the table: the picture is of the table once it is there.
            let wereAnimated = UIView.areAnimationsEnabled
            UIView.setAnimationsEnabled(false)
            window.isHidden = false
            defer {
                UIView.setAnimationsEnabled(wereAnimated)
                window.isHidden = true
                window.rootViewController = nil
                window.windowScene = nil
            }
            window.layoutIfNeeded()
            if largestText {
                #expect(table.container.metrics.code.pointSize > 30, "the window's text size reached the code")
            }
            #expect(table.container.contentSize.width <= table.container.bounds.width + 0.5, "nothing to scroll sideways")
            try draw(window, named: "\(name)-start")

            // The row that holds the line's last characters: its last piece.
            let line = try #require(table.lines(endingIn: tail).last, "\(tail) ends a line of the file")
            let file = table.document.lines[line].file
            let last = table.container.rows.files[file].rows.lastIndex { row in
                switch row {
                case .line(line), .piece(line, _): true
                default: false
                }
            }
            let row = try #require(last)
            let path = IndexPath(row: row, section: file)
            // Twice: the first lands by the table's guesses of the rows' heights, the second by what it then measured.
            for _ in 0 ..< 2 {
                table.container.table.scrollToRow(at: path, at: .bottom, animated: false)
                window.layoutIfNeeded()
            }
            let cell = try #require(table.container.table.cellForRow(at: path) as? DiffLineCell, "\(tail)'s row is on screen")
            #expect(LongLineTable.ends(cell.label.text ?? "", in: tail), "the row reaches the line's last characters")
            let frame = cell.label.convert(cell.label.bounds, to: window)
            #expect(frame.minX >= 0 && frame.maxX <= screen.maxX, "\(tail): nothing is off the sides, \(frame)")
            #expect(frame.maxY > 0 && frame.maxY <= screen.maxY + 0.5, "\(tail): the line's end is on screen, \(frame)")
            try draw(window, named: "\(name)-end")
        }

        private static func draw(_ window: UIWindow, named name: String) throws {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            var drawn = false
            let picture = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try #require(drawn, "\(name) was drawn")
            try Attachment.record(#require(picture.pngData()), named: "\(name).png")
        }
    }
#endif
