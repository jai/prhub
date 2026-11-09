import Foundation
import Testing
@testable import PRKit

/// The checks' list as a big web app's PR has it: one job name in several workflows, and a job's matrix legs beside the
/// job's own check.
struct PRCheckGroupsTests {
    private func check(
        _ name: String, _ workflow: String?, _ state: String = "success", required: Bool = false
    ) -> String {
        let workflow = workflow.map { "\"\($0)\"" } ?? "null"
        return #"{"name":"\#(name)","state":"\#(state)","url":"u/\#(name)","required":\#(required),"#
            + #""workflow":\#(workflow)}"#
    }

    private func groups(_ checks: [String]) throws -> [PullRequestDetail.CheckGroup] {
        try PullRequestDetail.decode(Data("""
        {"url":"u","head":"h","base":"main","headBranch":"b","author":null,"isAuthor":false,"body":"","additions":0,
        "deletions":0,"changedFiles":0,"reviewDecision":null,"mergeState":"BLOCKED","labels":[],
        "checks":[\(checks.joined(separator: ","))],
        "comments":{"nodes":[]},"reviews":{"nodes":[]},"reviewThreads":{"nodes":[]},"title":null}
        """.utf8)).checkGroups
    }

    @Test func aNameInTwoWorkflowsSaysItsWorkflow() throws {
        let shown = try groups([
            check("detect-changes", "Test Coverage"), check("detect-changes", "Deploy PR to Staging Preview"),
            check("opt-in", "Environment Harness"),
        ])
        #expect(shown.map(\.name) == ["detect-changes", "detect-changes", "opt-in"])
        #expect(shown.map(\.detail) == ["Deploy PR to Staging Preview", "Test Coverage", nil])
    }

    @Test func aJobsLegsAreOneLineWithTheirCountAndWorstState() throws {
        let legs = (1...8).map { check("frontend visual proof (web \($0)/8)", "Playwright Visual Proof") }
        let shown = try groups(
            legs + [
                check("frontend visual proof", "Playwright Visual Proof"),
                check("frontend visual proof (web 9/8)", "Playwright Visual Proof", "failure"),
                check("build (frontend)", "Test Coverage"),
            ]
        )
        let proof = try #require(shown.first { $0.name == "frontend visual proof" })
        #expect(proof.isGroup)
        #expect(proof.job?.name == "frontend visual proof")
        #expect(proof.legs.count == 9)
        #expect(proof.legs.map(\.label).prefix(2) == ["web 9/8", "web 1/8"], "a failing leg first, then by name")
        #expect(proof.state == "failure")
        #expect(proof.detail == "9 legs")
        #expect(shown.first?.name == "frontend visual proof", "the failing group leads")
        #expect(shown.contains { $0.name == "build (frontend)" && !$0.isGroup }, "one leg on its own stays a check")
    }

    @Test func legsWithNoJobCheckStillGroupAndRequiredCarries() throws {
        let shown = try groups([
            check("run-tests (frontend 1/2)", "Test Coverage", required: true),
            check("run-tests (frontend 2/2)", "Test Coverage", "pending"),
            check("a (x) / a (x)", "Test Coverage"),
        ])
        let tests = try #require(shown.first { $0.isGroup })
        #expect(tests.name == "run-tests")
        #expect(tests.job == nil)
        #expect(tests.state == "pending")
        #expect(tests.required == true)
        #expect(tests.url == nil)
        #expect(shown.contains { $0.name == "a (x) / a (x)" && !$0.isGroup }, "a name with more brackets is no leg")
    }

    @Test func aDetailSavedBeforeWorkflowsGroupsTheSame() throws {
        let saved = try groups([
            #"{"name":"e2e (1)","state":"success","url":null,"required":false}"#,
            #"{"name":"e2e (2)","state":"success","url":null,"required":false}"#,
        ])
        #expect(saved.count == 1)
        #expect(saved.first?.detail == "2 legs")
    }
}
