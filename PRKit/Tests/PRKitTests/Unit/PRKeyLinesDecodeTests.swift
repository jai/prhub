import Foundation
@testable import PRKit
import Testing

struct PRKeyLinesDecodeTests {
    @Test func aSummaryReadsWithItsRiskBugsAndPointsAndAnOlderAnswerHasNone() throws {
        let json = #"""
        {"items": [], "context": 100, "leftOut": [],
         "summary": {"risk": "high", "riskWhy": "Drops a column.", "points": ["Drops users.email"],
                     "bugs": [{"path": "db/m.sql", "line": 3, "side": "RIGHT", "why": "No backfill."}]}}
        """#
        let lines = try JSONDecoder().decode(PRKeyLines.self, from: Data(json.utf8))
        #expect(lines.summary?.riskTitle == "High risk" && lines.summary?.bugsTitle == "1 bug found")
        #expect(lines.summary?.bugs.first?.asItem.kind == "risk")
        let older = try JSONDecoder().decode(PRKeyLines.self, from: Data(#"{"items": [], "context": 0, "leftOut": []}"#.utf8))
        #expect(older.summary == nil)
    }
}
