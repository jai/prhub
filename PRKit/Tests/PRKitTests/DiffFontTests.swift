import CoreText
import Foundation
import SwiftUI
import Testing
@testable import PRKit
import PRKitDesign

/// The diff's font setting: today's font until someone changes it, kept on the device, and every face it offers
/// installed and monospaced.
@MainActor
struct DiffFontTests {
    private func freshDefaults() -> UserDefaults {
        let name = "DiffFontTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theDefaultIsTodaysDiff() {
        #expect(DiffFont.standard.face == .system)
        #expect(DiffFont.standard.size == DesignTokens.codeFontSize)
        #expect(AppStorage(diffFontIn: freshDefaults()).wrappedValue == .standard)
    }

    @Test func todaysDiffKeepsItsMeasures() {
        let metrics = DiffMetrics(.standard, scale: 1)
        #expect(metrics.code.pointSize == 12)
        #expect(metrics.rowHeight == 17)
        #expect(metrics.headerPath.pointSize == 14)
    }

    @Test func aChosenFontIsKeptOnTheDevice() {
        let defaults = freshDefaults()
        AppStorage(diffFontIn: defaults).wrappedValue = DiffFont(face: .jetBrainsMono, size: 15)
        #expect(defaults.string(forKey: DiffFont.storageKey) == "jetBrainsMono:15")
        #expect(AppStorage(diffFontIn: defaults).wrappedValue == DiffFont(face: .jetBrainsMono, size: 15))
    }

    @Test(arguments: ["", "menlo", "menlo:", "comicSans:12", "menlo:big", "menlo:8", "menlo:21", "menlo:12:1"])
    func aBadStoredValueReadsAsTheDefault(stored: String) {
        let defaults = freshDefaults()
        defaults.set(stored, forKey: DiffFont.storageKey)
        #expect(AppStorage(diffFontIn: defaults).wrappedValue == .standard)
    }

    @Test func aStoredValueOfAnotherTypeReadsAsTheDefault() {
        let defaults = freshDefaults()
        defaults.set(14, forKey: DiffFont.storageKey)
        #expect(AppStorage(diffFontIn: defaults).wrappedValue == .standard)
    }

    @Test func aSizeIsHeldToTheRangeInWholePoints() {
        #expect(DiffFont(face: .menlo, size: 4).size == 9)
        #expect(DiffFont(face: .menlo, size: 40).size == 20)
        #expect(DiffFont(face: .menlo, size: 13.4).size == 13)
    }

    @Test(arguments: DiffFontFace.allCases.filter { $0.bundledFolder != nil })
    func everyBundledFaceShipsRegularBoldAndItsLicence(face: DiffFontFace) throws {
        let files = DiffFontRegistry.fontFiles(of: face)
        #expect(files.count == 2)
        let folder = try #require(files.first?.deletingLastPathComponent())
        let licence = try String(contentsOf: folder.appendingPathComponent("OFL.txt"), encoding: .utf8)
        #expect(licence.contains("SIL Open Font License"))
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
    func everyFaceIsMonospaced(face: DiffFontFace) {
        let font = DiffFont(face: face, size: 12)
        for isBold in [false, true] {
            let advances = advances(of: "iIl1.,:;mMW0 _-+{}", in: font.platformFont(points: 12, isBold: isBold))
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

    private func advances(of text: String, in font: PlatformFont) -> [CGFloat] {
        let ctFont = font as CTFont
        let characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(ctFont, characters, &glyphs, characters.count)
        var sizes = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &sizes, glyphs.count)
        return sizes.map { ($0.width * 1_000).rounded() / 1_000 }
    }
}
