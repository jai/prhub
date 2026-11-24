@testable import PRKit
import SwiftUI
import Testing

/// The Mac's PR card (DESIGN.md, PR card): what its states do to it, and the page it lifts off. On the main actor: a
/// system colour resolved off it waits on the main thread for good.
@MainActor
struct PRRowCardTests {
    @Test func atRestACardIsItsGroundAlone() {
        let look = PRRowCardLook()
        #expect(!look.isLifted)
        #expect(!look.showsMark)
    }

    @Test func underThePointerTheGroundLiftsAndNothingIsMarked() {
        let look = PRRowCardLook(isHovered: true)
        #expect(look.isLifted)
        #expect(!look.showsMark, "the accent's edge says a PR is open, not that the pointer is over it")
    }

    @Test(arguments: [false, true])
    func theOpenPRsCardIsLiftedAndMarkedWhereverThePointerIs(isHovered: Bool) {
        let look = PRRowCardLook(isHovered: isHovered, isSelected: true)
        #expect(look.isLifted)
        #expect(look.showsMark)
    }

    #if os(macOS)
        /// DESIGN.md's `ground-list-mac`, light and dark, is what the Mac's list draws its page with.
        @Test(arguments: [ColorScheme.light, .dark])
        func theMacsListPageIsTheDesignsToken(_ scheme: ColorScheme) {
            let token = scheme == .dark ? ColorTokens.groundListMacDark : ColorTokens.groundListMac
            #expect(hex(Color.groundList, in: scheme) == token)
        }

        /// The fault cards fix: the Mac's window and a block on it are one colour, so the band of the page between two
        /// rows could not be seen. A card's ground is a step off the list's page in every channel.
        @Test(arguments: [ColorScheme.light, .dark])
        func aCardsGroundIsAStepOffTheListsPage(_ scheme: ColorScheme) {
            let page = hex(Color.groundList, in: scheme)
            let card = hex(Color.groundCard, in: scheme)
            for shift in [16, 8, 0] {
                let step = abs(Int((page >> shift) & 0xFF) - Int((card >> shift) & 0xFF))
                #expect(step >= 8, "page \(String(page, radix: 16)), card \(String(card, radix: 16))")
            }
        }

        /// A colour as the screen has it in `scheme`, 0xRRGGBB.
        private func hex(_ color: Color, in scheme: ColorScheme) -> UInt32 {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let resolved = color.resolve(in: environment)
            let byte = { (part: Float) in UInt32((min(max(part, 0), 1) * 255).rounded()) }
            return byte(resolved.red) << 16 | byte(resolved.green) << 8 | byte(resolved.blue)
        }
    #endif
}
