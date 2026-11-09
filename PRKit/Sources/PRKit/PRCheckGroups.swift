import Foundation

extension PullRequestDetail {
    /// A line in the PR's checks: one check, or a job's matrix legs under the job. GitHub names a leg after its job, its
    /// matrix values in brackets ("frontend visual proof (web 1/8)"), and a workflow can also run the job's own check
    /// beside them ("frontend visual proof").
    public struct CheckGroup: Identifiable, Sendable {
        /// One of a job's legs: what its brackets say ("web 1/8"), and the check.
        public struct Leg: Identifiable, Sendable {
            public let label: String
            public let check: Check

            public var id: String { check.id }
        }

        public let name: String
        public let workflow: String?
        /// The check named after the job itself; for a single check, that check.
        public let job: Check?
        /// Empty for a single check.
        public let legs: [Leg]
        /// Another line has the same name, so this one says its workflow.
        public fileprivate(set) var showsWorkflow = false

        public var id: String { "\(workflow ?? "")\n\(name)\n\(job?.id ?? legs.first?.id ?? "")" }
        public var isGroup: Bool { !legs.isEmpty }

        /// The job's check and its legs.
        public var checks: [Check] { (job.map { [$0] } ?? []) + legs.map(\.check) }

        /// The worst of its checks: failing, then running, then passing, then skipped.
        public var state: String {
            checks.map(\.state).min { Self.rank($0) < Self.rank($1) } ?? "skipped"
        }

        /// GitHub holds the merge for one of its checks.
        public var required: Bool? {
            let required = checks.map(\.required)
            return required.contains(true) ? true : required.contains(nil) ? nil : false
        }

        /// Where a tap goes for a single check.
        public var url: String? { isGroup ? nil : job?.url }

        /// What follows the name, quieter: the legs' count and, where it tells two lines apart, the workflow.
        public var detail: String? {
            let count = isGroup ? "\(legs.count) leg\(legs.count == 1 ? "" : "s")" : nil
            let shown = [count, showsWorkflow ? workflow : nil].compactMap(\.self)
            return shown.isEmpty ? nil : shown.joined(separator: " · ")
        }

        static func rank(_ state: String) -> Int {
            ["failure": 0, "pending": 1, "success": 2, "skipped": 3][state] ?? 3
        }
    }

    /// The checks as the list shows them: a job's matrix legs under one line with their count and worst state, and a
    /// name two workflows share told apart by its workflow. Ordered as `listedChecks`: required first, then what needs
    /// looking at, then by name.
    public var checkGroups: [CheckGroup] {
        Self.groups(of: listedChecks)
    }

    static func groups(of checks: [Check]) -> [CheckGroup] {
        let names = Set(checks.map { JobKey(workflow: $0.workflow, name: $0.name) })
        var legCounts: [JobKey: Int] = [:]
        for check in checks {
            if let leg = Self.leg(of: check) {
                legCounts[JobKey(workflow: check.workflow, name: leg.job), default: 0] += 1
            }
        }
        // A job is a group with two legs, or with one beside the job's own check.
        let jobs = Set(legCounts.filter { key, count in count > 1 || names.contains(key) }.keys)

        var groups: [CheckGroup] = []
        var grouped: [JobKey: (job: Check?, legs: [CheckGroup.Leg])] = [:]
        var order: [JobKey] = []
        for check in checks {
            let own = JobKey(workflow: check.workflow, name: check.name)
            if jobs.contains(own) {
                if grouped[own] == nil { order.append(own) }
                grouped[own, default: (nil, [])].job = check
            } else if let leg = Self.leg(of: check), case let key = JobKey(workflow: check.workflow, name: leg.job),
                      jobs.contains(key) {
                if grouped[key] == nil { order.append(key) }
                grouped[key, default: (nil, [])].legs.append(.init(label: leg.label, check: check))
            } else {
                groups.append(CheckGroup(name: check.name, workflow: check.workflow, job: check, legs: []))
            }
        }
        groups += order.compactMap { key in
            grouped[key].map { CheckGroup(name: key.name, workflow: key.workflow, job: $0.job, legs: $0.legs) }
        }

        var workflowsByName: [String: Set<String>] = [:]
        groups.forEach { workflowsByName[$0.name, default: []].insert($0.workflow ?? "") }
        for index in groups.indices where groups[index].workflow != nil {
            groups[index].showsWorkflow = (workflowsByName[groups[index].name]?.count ?? 0) > 1
        }
        return groups.sorted { first, second in
            let order = { (group: CheckGroup) in (group.required == false ? 1 : 0, CheckGroup.rank(group.state)) }
            if order(first) != order(second) {
                return order(first) < order(second)
            }
            let byName = first.name.localizedCaseInsensitiveCompare(second.name)
            return byName != .orderedSame
                ? byName == .orderedAscending
                : (first.workflow ?? "").localizedCaseInsensitiveCompare(second.workflow ?? "") == .orderedAscending
        }
    }

    /// "frontend visual proof (web 1/8)" is the job "frontend visual proof", leg "web 1/8": one bracketed part at the
    /// end, and no other brackets.
    private static func leg(of check: Check) -> (job: String, label: String)? {
        guard check.name.hasSuffix(")"), let open = check.name.range(of: " (", options: .backwards) else {
            return nil
        }
        let job = String(check.name[..<open.lowerBound])
        let label = String(check.name[open.upperBound..<check.name.index(before: check.name.endIndex)])
        guard !job.isEmpty, !label.isEmpty, !(job + label).contains(where: { "()".contains($0) }) else {
            return nil
        }
        return (job, label)
    }

    private struct JobKey: Hashable {
        let workflow: String?
        let name: String
    }
}
