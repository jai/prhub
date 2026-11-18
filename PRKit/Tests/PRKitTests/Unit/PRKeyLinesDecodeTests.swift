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

    @Test func theSummarysHeadingsSayTheRiskAndCountTheBugs() throws {
        func summary(risk: String, bugs: Int) throws -> PRKeyLines.Summary {
            let bug = #"{"path": "a", "line": 1, "side": "RIGHT", "why": "w"}"#
            let all = Array(repeating: bug, count: bugs).joined(separator: ",")
            let json = #"{"risk": "\#(risk)", "riskWhy": "", "points": [], "bugs": [\#(all)]}"#
            return try JSONDecoder().decode(PRKeyLines.Summary.self, from: Data(json.utf8))
        }
        #expect(try summary(risk: "low", bugs: 0).riskTitle == "Low risk")
        #expect(try summary(risk: "medium", bugs: 0).bugsTitle == "No bugs found")
        #expect(try summary(risk: "high", bugs: 3).bugsTitle == "3 bugs found")
    }

    @Test func theRequirementsLineSaysFitsMismatchOrMultipleAndAnUnknownStateNothing() throws {
        func requirements(_ state: String, gaps: [String] = []) throws -> PRKeyLines.Summary.Requirements? {
            let quoted = gaps.map { "\"\($0)\"" }.joined(separator: ",")
            let json = #"{"risk": "low", "riskWhy": "", "points": [], "bugs": [],"#
                + #" "requirements": {"state": "\#(state)", "tickets": ["CORE-12"], "gaps": [\#(quoted)]}}"#
            return try JSONDecoder().decode(PRKeyLines.Summary.self, from: Data(json.utf8)).requirements
        }
        #expect(try requirements("fits")?.title == "Requirements fit")
        let mismatch = try requirements("mismatch", gaps: ["Skips Fridays"])
        #expect(mismatch?.title == "Requirements mismatch" && mismatch?.gaps == ["Skips Fridays"])
        #expect(try requirements("multiple")?.title == "Multiple ticket support not yet implemented")
        #expect(try requirements("partly")?.title == nil)
        let older = #"{"risk": "low", "riskWhy": "", "points": [], "bugs": []}"#
        #expect(try JSONDecoder().decode(PRKeyLines.Summary.self, from: Data(older.utf8)).requirements == nil)
    }

    @Test func oneKeyLineIsCountedAsOne() {
        #expect(PRKeyLines.counted(1) == "1 key line")
        #expect(PRKeyLines.counted(0) == "0 key lines" && PRKeyLines.counted(3) == "3 key lines")
    }
}
