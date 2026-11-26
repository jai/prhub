import Foundation

/// The labels a PR's repo has, as the Worker reads them from GitHub (`GET /prs/{owner}/{repo}/{n}/labels`), sorted, and
/// whether the person may put them on the PR or take them off.
public struct PRRepoLabels: Decodable, Equatable, Sendable {
    public struct Label: Decodable, Identifiable, Equatable, Sendable {
        public let name: String
        /// Six hex digits, no `#`, as GitHub has it.
        public let color: String
        public let description: String?

        public init(name: String, color: String, description: String? = nil) {
            self.name = name
            self.color = color
            self.description = description
        }

        public var id: String {
            name
        }
    }

    public let labels: [Label]
    /// False where GitHub lets the person read the repo and not triage it.
    public let canEdit: Bool

    public init(labels: [Label], canEdit: Bool) {
        self.labels = labels
        self.canEdit = canEdit
    }
}
