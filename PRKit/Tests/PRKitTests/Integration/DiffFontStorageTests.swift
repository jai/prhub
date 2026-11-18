import Foundation
@testable import PRKit
import PRKitDesign
import SwiftUI
import Testing

@MainActor
struct DiffFontStorageTests {
    private let preferences = TestPreferences()

    @Test func theDefaultIsTodaysDiff() {
        #expect(DiffFont.standard.face == .system)
        #expect(DiffFont.standard.size == DesignTokens.codeFontSize)
        #expect(AppStorage(diffFontIn: preferences.defaults).wrappedValue == .standard)
    }

    @Test func aChosenFontIsKeptOnTheDevice() {
        let defaults = preferences.defaults
        AppStorage(diffFontIn: defaults).wrappedValue = DiffFont(face: .jetBrainsMono, size: 15)
        #expect(defaults.string(forKey: DiffFont.storageKey) == "jetBrainsMono:15")
        #expect(AppStorage(diffFontIn: defaults).wrappedValue == DiffFont(face: .jetBrainsMono, size: 15))
    }

    @Test(arguments: ["", "menlo", "menlo:", "comicSans:12", "menlo:big", "menlo:8", "menlo:21", "menlo:12:1"])
    func aBadStoredValueReadsAsTheDefault(stored: String) {
        let defaults = preferences.defaults
        defaults.set(stored, forKey: DiffFont.storageKey)
        #expect(AppStorage(diffFontIn: defaults).wrappedValue == .standard)
    }

    @Test func aStoredValueOfAnotherTypeReadsAsTheDefault() {
        let defaults = preferences.defaults
        defaults.set(14, forKey: DiffFont.storageKey)
        #expect(AppStorage(diffFontIn: defaults).wrappedValue == .standard)
    }

    @Test(arguments: DiffFontFace.allCases.filter { $0.bundledFolder != nil })
    func everyBundledFaceShipsRegularBoldAndItsLicence(face: DiffFontFace) throws {
        let files = DiffFontRegistry.fontFiles(of: face)
        #expect(files.count == 2)
        let folder = try #require(files.first?.deletingLastPathComponent())
        let licence = try String(contentsOf: folder.appendingPathComponent("OFL.txt"), encoding: .utf8)
        #expect(licence.contains("SIL Open Font License"))
    }
}
