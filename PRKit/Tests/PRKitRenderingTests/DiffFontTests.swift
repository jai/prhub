import CoreText
import Foundation
@testable import PRKit
import PRKitDesign
import SwiftUI
import Testing

/// Platform fonts and the diff layout use the selected face, weight and size.
@MainActor
struct DiffFontTests {
    @Test func todaysDiffKeepsItsMeasures() {
        let metrics = DiffMetrics(.standard, scale: 1)
        #expect(metrics.code.pointSize == 12)
        #expect(metrics.rowHeight == 17)
        #expect(metrics.headerPath.pointSize == 14)
    }

    @Test(arguments: DiffFontFace.allCases.filter { $0.postScriptNames != nil })
    func everyNamedFaceIsInstalled(face: DiffFontFace) throws {
        let names = try #require(face.postScriptNames)
        let font = DiffFont(face: face, size: 12)
        #expect(postScriptName(font.platformFont(points: 12)) == names.regular)
        #expect(postScriptName(font.platformFont(points: 12, isBold: true)) == names.bold)
    }

    /// Code lines up only if every character is as wide as every other: `i` as `W`, `.` as `m`.
    @Test(arguments: DiffFontFace.allCases)
    func everyFaceIsMonospaced(face: DiffFontFace) throws {
        let font = DiffFont(face: face, size: 12)
        for isBold in [false, true] {
            let advances = try advances(of: "iIl1.,:;mMW0 _-+{}", in: font.platformFont(points: 12, isBold: isBold))
            #expect(Set(advances).count == 1, "\(face.name) bold: \(isBold) has advances \(Set(advances))")
        }
    }

    @Test func theFileHeaderIsAStepBiggerAndFollowsTheFont() {
        for size in [CGFloat(9), 12, 20] {
            let metrics = DiffMetrics(DiffFont(face: .sourceCodePro, size: size), scale: 1)
            #expect(metrics.headerPath.pointSize == size + DiffFont.headingStep)
            #expect(metrics.fileHeaderHeight >= ceil(metrics.headerPath.diffLineHeight))
        }
    }

    @Test func textSizeScalesTheCodeAndTheHeader() {
        let large = DiffMetrics(.standard, scale: 1.5)
        #expect(large.code.pointSize == 18)
        #expect(large.headerPath.pointSize == 21)
    }

    #if os(iOS)
        @Test(arguments: [CGFloat(9), 12, 20])
        func theViewedMarkIsATapTargetAtEverySize(size: CGFloat) {
            let metrics = DiffMetrics(DiffFont(face: .menlo, size: size), scale: 1)
            #expect(metrics.viewedTarget >= DiffMetrics.minimumTapTarget)
            #expect(metrics.fileHeaderHeight >= DiffMetrics.minimumTapTarget)
        }
    #endif

    private func postScriptName(_ font: PlatformFont) -> String {
        CTFontCopyPostScriptName(font as CTFont) as String
    }

    private func advances(of text: String, in font: PlatformFont) throws -> [CGFloat] {
        let ctFont = font as CTFont
        let characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        try #require(CTFontGetGlyphsForCharacters(ctFont, characters, &glyphs, characters.count),
                     "Every character in the monospacing sample must have a glyph")
        var sizes = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &sizes, glyphs.count)
        try #require(sizes.allSatisfy { $0.width > 0 }, "Every sample glyph must have a positive advance")
        return sizes.map { ($0.width * 1000).rounded() / 1000 }
    }
}
