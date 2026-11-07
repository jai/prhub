import Foundation

/// A PR named by a link: it may be on neither of the lists.
public struct PullRequestRef: Hashable, Sendable {
    public let repo: String
    public let number: Int

    public init(repo: String, number: Int) {
        self.repo = repo
        self.number = number
    }

    /// `https://github.com/{owner}/{repo}/pull/{number}`, with anything after the number.
    public init?(url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.host() == "github.com", parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]) else {
            return nil
        }
        repo = "\(parts[0])/\(parts[1])"
        self.number = number
    }
}

/// Finds the PR a piece of text names: a github.com PR link, or `owner/repo#N`. The way in for anything that hands
/// PRKit words rather than a tap: a link opened in the app, and later the clipboard, a share sheet or a quick jump.
public enum PRLinkParser {
    /// The PR `text` names, read whole after trimming: a link (`https://github.com/o/r/pull/12`, with anything after
    /// the number) or a ref (`o/r#12`). Nil for anything else, a link to another site included.
    public static func ref(in text: String) -> PullRequestRef? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), url.scheme?.lowercased() == "https", let ref = PullRequestRef(url: url) {
            return ref
        }
        return shortRef(text)
    }

    /// `owner/repo#N`: GitHub's own names, letters, digits, `-`, `_` and `.`, and a number above zero.
    private static func shortRef(_ text: String) -> PullRequestRef? {
        let parts = text.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, let number = Int(parts[1]), number > 0 else {
            return nil
        }
        let names = parts[0].split(separator: "/", omittingEmptySubsequences: false)
        let isName = { (name: Substring) in
            !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }
        guard names.count == 2, names.allSatisfy(isName) else {
            return nil
        }
        return PullRequestRef(repo: "\(names[0])/\(names[1])", number: number)
    }
}
