import CryptoKit
import DurableNetworking
import Foundation
import PRKitCore

/// A changed file's text at a PR's head, for the lines its diff leaves out. A file at a commit never changes, so one
/// read is kept on this device beside the other kept answers and read from there from then on, offline too.
extension PRsModel {
    func fileText(_ path: String, head: String, of ref: PullRequestRef) async throws -> Data {
        if let samples {
            return try samples.fileText(path, for: ref)
        }
        let key = Self.fileKey(path, head: head, of: ref)
        if let saved = kept.load(key) {
            return saved.data
        }
        let text = try await client.file(path: path, head: head, for: ref)
        keep(text, as: key)
        return text
    }

    /// The path as a hash: a kept answer's key is its file's name, and a path may be longer than a name can be.
    static func fileKey(_ path: String, head: String, of ref: PullRequestRef) -> InboxKey {
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return InboxKey("file-\(ref.repo)/\(ref.number)/\(head)/\(hash)")
    }
}
