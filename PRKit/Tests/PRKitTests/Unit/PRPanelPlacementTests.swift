@testable import PRKit
import PRKitDesign
import Testing

struct PRPanelPlacementTests {
    @Test func thePanelIsAColumnOnlyWhereARegularWidthHasRoomForTheDiffBesideIt() {
        let room = PanelStyle.columnWidth + PanelStyle.diffWidth
        #expect(PRPanelPlacement.fitting(width: room, isRegularWidth: true) == .column)
        #expect(PRPanelPlacement.fitting(width: room - 1, isRegularWidth: true) == .overlay)
        #expect(PRPanelPlacement.fitting(width: room * 2, isRegularWidth: false) == .overlay)
    }
}
