import Testing
@testable import PRKit

/// What a PR is named by, wherever words come from: a link, and later the clipboard, a share sheet or a quick jump.
struct PRLinkParserTests {
    @Test func aGitHubLinkNamesItsPRWithAnythingAfterTheNumber() {
        let ref = PullRequestRef(repo: "acme/web-app", number: 6798)
        #expect(PRLinkParser.ref(in: "https://github.com/acme/web-app/pull/6798") == ref)
        #expect(PRLinkParser.ref(in: "  https://github.com/acme/web-app/pull/6798/files#diff-1\n") == ref)
    }

    @Test func aShortRefNamesItsPR() {
        #expect(PRLinkParser.ref(in: "jai/agent-pager#28") == PullRequestRef(repo: "jai/agent-pager", number: 28))
        #expect(PRLinkParser.ref(in: "a-b/c_d.e#1") == PullRequestRef(repo: "a-b/c_d.e", number: 1))
    }

    @Test func anythingElseNamesNoPR() {
        for text in [
            "", "jai/agent-pager", "jai/agent-pager#", "jai/agent-pager#0", "jai/agent-pager#-3", "agent-pager#3",
            "a/b/c#3", "jai/agent pager#3", "https://github.com/jai/agent-pager/issues/3",
            "https://gitlab.com/jai/agent-pager/pull/3", "http://github.com/jai/agent-pager/pull/3", "see jai/a#3",
        ] {
            #expect(PRLinkParser.ref(in: text) == nil, "\(text)")
        }
    }
}
