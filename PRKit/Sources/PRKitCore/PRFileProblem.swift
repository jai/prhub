import Foundation

/// Why the Worker has no text for a file at a PR's head (`GET /prs/{owner}/{repo}/{n}/file`, docs/api.md): each is an
/// answer about the file or the PR, and asking again gets the same one.
public enum PRFileProblem: Error, Equatable, Sendable {
    /// `413 too_large`: the file is over 1 MB.
    case tooLarge
    /// `415 binary_file`.
    case binary
    /// `409 head_moved`: the PR has a newer commit than the one asked at.
    case headMoved
    /// `404 not_found`: nothing at that path at that commit, or what is there is no file.
    case missing

    /// Nil for any other answer, a Worker without the route among them: its `404` has no such body.
    public init?(status: Int, body: Data) {
        struct Refusal: Decodable {
            struct Problem: Decodable {
                let code: String
            }

            let error: Problem
        }
        // A file's own text may be JSON of any shape: only a refusal is read as one.
        guard !(200 ..< 300).contains(status) else {
            return nil
        }
        switch (status, (try? JSONDecoder().decode(Refusal.self, from: body))?.error.code) {
        case (413, _), (_, "too_large"): self = .tooLarge
        case (415, _), (_, "binary_file"): self = .binary
        case (409, _), (_, "head_moved"): self = .headMoved
        case (404, "not_found"): self = .missing
        default: return nil
        }
    }
}
