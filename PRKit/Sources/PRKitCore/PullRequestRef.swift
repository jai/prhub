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

/// A PR and what of it a link asks to see: GitHub's `/files` and `/changes` pages are its diff, anything else its page.
public struct PRLink: Hashable, Sendable {
    public let ref: PullRequestRef
    public let showsDiff: Bool

    public init(ref: PullRequestRef, showsDiff: Bool = false) {
        self.ref = ref
        self.showsDiff = showsDiff
    }

    public init?(url: URL) {
        guard let ref = PullRequestRef(url: url) else {
            return nil
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        self.init(ref: ref, showsDiff: parts.count > 4 && ["files", "changes"].contains(parts[4]))
    }
}

/// Finds the PR a piece of text names: a github.com PR link, or `owner/repo#N`. The way in for anything that hands
/// PRKit words rather than a tap: a link opened in the app, and later the clipboard, a share sheet or a quick jump.
public enum PRLinkParser {
    /// The PR `text` names, read whole after trimming: a link (`https://github.com/o/r/pull/12`, with anything after
    /// the number) or a ref (`o/r#12`). Nil for anything else, a link to another site included.
    public static func ref(in text: String) -> PullRequestRef? {
        link(in: text)?.ref
    }

    /// The PR `text` names and whether it names its diff: a link to `…/pull/12/files` does, a ref never.
    public static func link(in text: String) -> PRLink? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), url.scheme?.lowercased() == "https", let link = PRLink(url: url) {
            return link
        }
        return shortRef(text).map { PRLink(ref: $0) }
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
