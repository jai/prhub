import Foundation
@testable import PRKit
import SwiftUI
import Testing

/// How the PRs list sets its rows apart, drawn off screen in light and dark. On the Mac each PR and its ticket are a card
/// on the list's page, with a band of that page between two cards (DESIGN.md, PR card); on the phone and the iPad a row
/// is the block exactly as it was before cards.
@MainActor
struct PRRowCardRenderingTests {
    private static let width: CGFloat = 400
    private static let scale: CGFloat = 2
    /// How many more draws a view gets to settle.
    private static let draws = 5
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A PR with every signal and its ticket, as the PRs tab draws it.
    private static func block(_ number: Int) -> some View {
        let status = PullRequestStatus(
            repo: "acme/api", number: number, url: "https://github.com/acme/api/pull/\(number)",
            title: "Rate-limit the password reset endpoint", state: .open, checks: .failing, merge: .behind,
            review: .required
        )
        let ticket = PRListTicket(
            key: "API-\(number)", title: "Throttle password reset emails", state: "In Progress", stateType: "started",
            found: true
        )
        return PrListBlock(
            item: PRListItem(
                ticket: ticket, pullRequests: [PRListPullRequest(status: status, author: "hubot", found: true)]
            ),
            id: "\(number)", sentAt: now, now: now, folds: FoldSet()
        )
    }

    /// The view as it draws once it has settled: drawn until two draws in a row are the same and not empty. A process's
    /// first draw can come back unfinished: on a slow Mac the renderer stops waiting for its images, and on 2026-11-25
    /// that blank first draw failed two releases (run 45609673448, `block.bytes` all zero).
    private func render(_ view: some View, in scheme: ColorScheme) throws -> Bitmap {
        let renderer = ImageRenderer(
            content: view
                .frame(width: Self.width)
                .environment(\.colorScheme, scheme)
                .environment(\.loadsAuthorAvatars, false)
        )
        renderer.scale = Self.scale
        var last = try Bitmap(#require(renderer.cgImage))
        for _ in 0 ..< Self.draws {
            let next = try Bitmap(#require(renderer.cgImage))
            if next.bytes == last.bytes, next.bytes.contains(where: { $0 != 0 }) {
                return next
            }
            last = next
        }
        Issue.record("the view did not draw the same twice, or drew nothing, in \(Self.draws + 1) draws")
        return last
    }

    private func pixel(_ points: CGFloat) -> Int {
        Int((points * Self.scale).rounded())
    }

    #if os(macOS)
        /// The fault cards fix (Jai, 2026-11-24: "How do we make the rows stand out and look nice on dark mode here"):
        /// the Mac's window and a block on it are one colour, so nothing could be seen between two rows.
        @Test(arguments: [ColorScheme.light, .dark])
        func onTheMacEachRowIsACardWithABandOfTheListsPageBetween(_ scheme: ColorScheme) throws {
            let list = VStack(spacing: Space.sm) {
                Self.block(1).prListRow(isSelected: false)
                Self.block(2).prListRow(isSelected: false)
            }
            .background(Color.groundList)
            let bitmap = try render(list, in: scheme)
            // The two cards are one height, so a quarter of the way down is the middle of the first.
            let middle = bitmap.height / 4

            let page = bitmap[pixel(Space.lg / 2), middle]
            let token = scheme == .dark ? ColorTokens.groundListMacDark : ColorTokens.groundListMac
            #expect(page.isNear(Pixel(token)), "beside a card is the list's page, \(page)")

            // Down a card's inset, past its corner and short of its avatar: a card, the page, a card.
            let column = (0 ..< bitmap.height).map { bitmap[pixel(Space.lg + Radius.md + Space.xxs), $0] }
            let card = column[middle]
            #expect(card.distance(to: page) >= 24, "a card's ground \(card) is a step off the page \(page)")
            let bands = Self.runs(in: column) { $0.isNear(page) }
            #expect(bands.count == 1, "one band of the page, between the two cards: \(bands)")
            #expect(abs((bands.first?.count ?? 0) - pixel(Space.sm)) <= 1, "the band is Space.sm: \(bands)")
            #expect(Self.runs(in: column) { $0.isNear(card) }.count == 2, "a card above the band and one below")

            // A card's corner is cut, so the page shows at its very corner; its edge is a hairline off its ground.
            for row in [0, bitmap.height - 1] {
                #expect(bitmap[pixel(Space.lg), row].isNear(page), "a corner, row \(row)")
            }
            let edge = bitmap[pixel(Space.lg), middle]
            #expect(edge.distance(to: card) >= 12, "a hairline \(edge) edges the card \(card)")
        }

        /// The look for the PR that is open beside the list. The Mac opens a PR over the list today, so nothing is
        /// selected there yet; the look is ready for a list beside the PR.
        @Test(arguments: [ColorScheme.light, .dark])
        func theOpenPRsCardIsLiftedAndMarkedDownItsLeadingEdge(_ scheme: ColorScheme) throws {
            let rest = try render(Self.block(1).prListRow(isSelected: false).background(Color.groundList), in: scheme)
            let open = try render(Self.block(1).prListRow(isSelected: true).background(Color.groundList), in: scheme)
            #expect(open.height == rest.height, "being open moves nothing")
            let middle = rest.height / 2
            let inset = pixel(Space.lg + Radius.md + Space.xxs)
            let mark = pixel(Space.lg + Space.xxs)

            #expect(open[inset, middle].distance(to: rest[inset, middle]) >= 3, "the open card's ground is lifted")
            #expect(open[mark, middle].distance(to: open[inset, middle]) >= 60, "the accent runs down its leading edge")
            #expect(rest[mark, middle].isNear(rest[inset, middle]), "a card at rest has no mark")
        }

        /// A tone's words (Checks fail, Changes requested, Out of date) keep 4.5:1 on a card, at rest and under the
        /// pointer: the reason the page went darker instead of the card going lighter.
        @Test(arguments: [ColorScheme.light, .dark])
        func aTonesWordsKeepTheirContrastOnACardAtRestAndUnderThePointer(_ scheme: ColorScheme) throws {
            let tokens = try Self.designColors()
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let card = Color.groundCard.resolve(in: environment)
            let lifted = Color.groundHover.resolve(in: environment).over(card)
            for tone in ["tone-good", "tone-bad", "tone-waiting"] {
                let name = scheme == .dark ? "\(tone)-dark" : tone
                let words = try Pixel(#require(tokens[name], "DESIGN.md has no \(name)"))
                #expect(words.contrast(with: Pixel(card)) >= 4.5, "\(name) on a card at rest, \(Pixel(card))")
                #expect(words.contrast(with: Pixel(lifted)) >= 4.5, "\(name) under the pointer, \(Pixel(lifted))")
            }
        }

        /// DESIGN.md's opaque colour tokens by name: "tone-bad-dark" is 0xF85149.
        private static func designColors() throws -> [String: UInt32] {
            var repo = URL(filePath: #filePath)
            for _ in 0 ..< 4 {
                repo.deleteLastPathComponent()
            }
            let design = try String(contentsOf: repo.appending(path: "DESIGN.md"), encoding: .utf8)
            var colors: [String: UInt32] = [:]
            for line in design.split(separator: "\n") {
                // `  tone-bad-dark: "#F85149"`
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, parts[1].hasPrefix("\"#"), parts[1].hasSuffix("\""), parts[1].count == 9 else {
                    continue
                }
                colors[parts[0]] = UInt32(parts[1].dropFirst(2).dropLast(), radix: 16)
            }
            return colors
        }

        /// The runs of consecutive pixels that `matches` holds for, each as its range of rows.
        private static func runs(in column: [Pixel], where matches: (Pixel) -> Bool) -> [Range<Int>] {
            var runs: [Range<Int>] = []
            var start: Int?
            for (row, pixel) in column.enumerated() {
                if matches(pixel) {
                    start = start ?? row
                } else if let from = start {
                    runs.append(from ..< row)
                    start = nil
                }
            }
            if let from = start {
                runs.append(from ..< column.count)
            }
            return runs
        }
    #else
        /// Cards are the Mac's. On the phone and the iPad a row of the list draws pixel for pixel what the block alone
        /// draws, and the list's page is the page.
        @Test(arguments: [ColorScheme.light, .dark])
        func offTheMacARowIsTheBlockAsItWas(_ scheme: ColorScheme) throws {
            let block = try render(Self.block(1), in: scheme)
            let row = try render(Self.block(1).prListRow(isSelected: false), in: scheme)
            #expect(row.width == block.width && row.height == block.height)
            // Compared here, not in the expectation: a failure would print every byte of both pictures.
            let isTheBlock = row.bytes == block.bytes
            #expect(isTheBlock, "a row on the phone is its block, with no card around it")

            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            #expect(Color.groundList.resolve(in: environment) == Color.groundPage.resolve(in: environment))
        }
    #endif
}

/// One pixel, sRGB.
struct Pixel: CustomStringConvertible {
    let red: Int
    let green: Int
    let blue: Int

    init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 0xRRGGBB.
    init(_ hex: UInt32) {
        self.init(red: Int((hex >> 16) & 0xFF), green: Int((hex >> 8) & 0xFF), blue: Int(hex & 0xFF))
    }

    init(_ color: Color.Resolved) {
        let byte = { (part: Float) in Int((min(max(part, 0), 1) * 255).rounded()) }
        self.init(red: byte(color.red), green: byte(color.green), blue: byte(color.blue))
    }

    var description: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// How far apart two pixels are, over the three channels.
    func distance(to other: Pixel) -> Int {
        abs(red - other.red) + abs(green - other.green) + abs(blue - other.blue)
    }

    /// The same colour, give or take the rounding of a draw.
    func isNear(_ other: Pixel) -> Bool {
        distance(to: other) <= 6
    }

    /// WCAG 2's relative luminance.
    private var luminance: Double {
        let linear = { (channel: Int) in
            let part = Double(channel) / 255
            return part <= 0.04045 ? part / 12.92 : pow((part + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2's contrast ratio, 1 to 21.
    func contrast(with other: Pixel) -> Double {
        let (lighter, darker) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (lighter + 0.05) / (darker + 0.05)
    }
}

private extension Color.Resolved {
    /// This colour laid over an opaque `ground`, as the screen composites it.
    func over(_ ground: Color.Resolved) -> Color.Resolved {
        Color.Resolved(
            red: red * opacity + ground.red * (1 - opacity), green: green * opacity + ground.green * (1 - opacity),
            blue: blue * opacity + ground.blue * (1 - opacity)
        )
    }
}

/// A drawn view's pixels, sRGB, top row first.
struct Bitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        self.bytes = bytes
    }

    subscript(column: Int, row: Int) -> Pixel {
        let offset = (row * width + column) * 4
        return Pixel(red: Int(bytes[offset]), green: Int(bytes[offset + 1]), blue: Int(bytes[offset + 2]))
    }
}
