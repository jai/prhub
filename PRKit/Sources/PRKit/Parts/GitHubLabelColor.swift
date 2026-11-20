import SwiftUI

/// A GitHub label's colour, made readable as a chip's words: GitHub lets a label be any colour, so a near-white label
/// (an `ededed` automerge) vanishes on a light page and a near-black one on a dark page. The colour keeps its hue and
/// moves only as far as it must to read at 4.5:1 on the card.
struct GitHubLabelColor: Equatable {
    /// sRGB channels, 0...1.
    let red: Double, green: Double, blue: Double

    /// The most a word may have on a light card (white): 4.5:1.
    static let lightCeiling = 0.18
    /// The least a word may have on a dark card (`#1c1c1e`): 4.5:1.
    static let darkFloor = 0.23

    /// Six hex digits, no `#`; anything else is a mid grey.
    init(hex: String) {
        let value = hex.count == 6 ? UInt32(hex, radix: 16) ?? 0x808080 : 0x808080
        self.init(
            sRGB: Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255
        )
    }

    init(sRGB red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// WCAG relative luminance.
    var luminance: Double {
        0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
    }

    /// Darkened toward black on a light page, lightened toward white on a dark one, until it reads.
    func readable(dark: Bool) -> GitHubLabelColor {
        let current = luminance
        if dark {
            guard current < Self.darkFloor else { return self }
            let mix = (Self.darkFloor - current) / (1 - current)
            return mapped { $0 + mix * (1 - $0) }
        }
        guard current > Self.lightCeiling else { return self }
        let scale = Self.lightCeiling / current
        return mapped { $0 * scale }
    }

    var color: Color {
        Color(self)
    }

    /// Each channel moved in linear light, where luminance adds up.
    private func mapped(_ move: (Double) -> Double) -> GitHubLabelColor {
        GitHubLabelColor(
            sRGB: Self.gamma(move(Self.linear(red))), Self.gamma(move(Self.linear(green))),
            Self.gamma(move(Self.linear(blue)))
        )
    }

    private static func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    private static func gamma(_ channel: Double) -> Double {
        channel <= 0.0031308 ? channel * 12.92 : 1.055 * pow(channel, 1 / 2.4) - 0.055
    }
}

private extension Color {
    init(_ label: GitHubLabelColor) {
        self.init(red: label.red, green: label.green, blue: label.blue)
    }
}
