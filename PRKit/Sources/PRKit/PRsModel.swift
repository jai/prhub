import Foundation
import Observation
import PRKitCore
import QuartzCore

/// What started a sync, reported to the Worker with what it found, so freshness is measured and not guessed.
public enum PRSyncTrigger: String, Sendable {
    case silentPush = "push"
    case otherPush = "other_push"
    case foreground
    case pull
}

public enum PRSyncOutcome: Sendable {
    case changed, unchanged, failed
}

/// The two lists the PRs tab holds.
enum PRListPage: String, CaseIterable, Identifiable {
    case review, mine

    var id: Self { self }

    func holds(_ row: PullRequestRow) -> Bool {
        (row.isReviewRequest || row.isAnswered) == (self == .review)
    }

    /// A line of the list. On the review list, what Jai still has to review, then what he has approved, sent back or
    /// commented on.
    enum Entry: Identifiable {
        case header(String)
        case row(PullRequestRow)

        var id: String {
            switch self {
            case let .header(title): "header:\(title)"
            case let .row(row): row.id
            }
        }
    }

    func entries(_ rows: [PullRequestRow]) -> [Entry] {
        let section = { (title: String, rows: [PullRequestRow]) -> [Entry] in
            rows.isEmpty ? [] : [.header(title)] + rows.map(Entry.row)
        }
        guard self == .review, !rows.contains(where: \.isMerged) else {
            return rows.map(Entry.row)
        }
        return section("Review Pending", rows.filter { !$0.isAnswered })
            + section("Recently Reviewed", rows.filter(\.isAnswered))
    }

    /// Past the review SLA first, the longest overdue on top; then the rows waiting on Jai's own change request; then
    /// the rest, each in the order it came.
    static func ordered(_ rows: [PullRequestRow], now: Date = .now) -> [PullRequestRow] {
        let late = rows.filter { $0.isPastSLA(now: now) }.sorted { ($0.reviewDue ?? now) < ($1.reviewDue ?? now) }
        let rest = rows.filter { !$0.isPastSLA(now: now) }
        return late + rest.filter(\.isWaitingOnJaisChangeRequest) + rest.filter { !$0.isWaitingOnJaisChangeRequest }
    }
}

/// The orgs and repos the PRs tab shows, saved on the phone. Every org's PRs are mirrored either way, so a change is
/// instant and nothing has to load.
struct PROrgFilter: RawRepresentable, Equatable {
    private(set) var selected: Set<String>
    /// Empty means every repo of the chosen orgs.
    private(set) var repos: Set<String> = []

    init(selected: Set<String>) {
        self.selected = selected
    }

    /// `orgs|repos`, each comma separated. A value saved before repos existed has no `|`.
    init?(rawValue: String) {
        let parts = rawValue.split(separator: "|", omittingEmptySubsequences: false)
        selected = Set(parts[0].split(separator: ",").map(String.init))
        repos = parts.count > 1 ? Set(parts[1].split(separator: ",").map(String.init)) : []
    }

    var rawValue: String {
        "\(selected.sorted().joined(separator: ","))|\(repos.sorted().joined(separator: ","))"
    }

    func showsOrg(of row: PullRequestRow) -> Bool {
        selected.contains(row.org)
    }

    func shows(_ row: PullRequestRow) -> Bool {
        showsOrg(of: row) && (repos.isEmpty || repos.contains(row.repo))
    }

    /// An org going takes its repos with it, so a hidden choice can't empty the list.
    mutating func toggle(_ org: String) {
        if selected.remove(org) == nil {
            selected.insert(org)
        } else {
            repos = repos.filter { !$0.hasPrefix("\(org)/") }
        }
    }

    mutating func toggleRepo(_ repo: String) {
        if repos.remove(repo) == nil {
            repos.insert(repo)
        }
    }

    mutating func showAllRepos() {
        repos = []
    }
}

/// The list on screen and the mirror behind it, in Caches: never backed up, and iOS may clear it, which only costs a
/// download. Rows are on screen from the file before the Worker answers. A push carries no data, so a lost one costs
/// nothing but time.
@MainActor
@Observable
final class PRsModel {
    private static let staleAfter: TimeInterval = 5 * 60
    private static let answersKey = "prLocalAnswers"

    private(set) var rows: [PullRequestRow]
    /// Merged PRs by page: his own on My PRs, the ones he reviewed on For review. Read when a page shows them.
    private(set) var merged: [PRListPage: [PullRequestRow]] = [:]
    private(set) var mergedError: [PRListPage: String] = [:]
    private(set) var errorMessage: String?
    private(set) var workerSyncedAt: Date?
    /// Rows Jai swiped away. They stay hidden until the Worker's list drops them, so one can't flicker back.
    private(set) var removedRequests: Set<String> = []
    /// By row id. Saved, so a row stays read through a restart until the Worker's list catches up.
    private(set) var localAnswers: [String: PRLocalAnswer] = UserDefaults.standard.data(forKey: PRsModel.answersKey)
        .flatMap { try? JSONDecoder().decode([String: PRLocalAnswer].self, from: $0) } ?? [:]
    let client: PRViewerClient
    /// PRs with no Worker (`PRSampleSet`): Jai's Debug `-UXFixtures`, or PRHub's "Try with sample PRs". Nothing then
    /// leaves the phone.
    let samples: PRSampleSet?
    /// The host's (`PRKitHost.outbox`), read when a write goes, which hands each answer back through `outboxAnswered`
    /// and `outboxRefused`. Without one, as in a test, writes go straight to the Worker.
    @ObservationIgnored var outboxSource: @MainActor () -> (any PRKitOutbox)? = { nil }

    var outbox: (any PRKitOutbox)? {
        get { outboxSource() }
        set { outboxSource = { newValue } }
    }
    /// The APNs environment the push token is registered under (`PRKitHost.apnsEnvironment`).
    @ObservationIgnored var apnsEnvironment = ""
    /// Where `PRKitEvent`s go: the host.
    @ObservationIgnored var onEvent: (PRKitEvent) -> Void = { _ in }
    /// Where the empty list's link goes before it opens: the host (`PRKitHost.opensEmptyHintLink`).
    @ObservationIgnored var onEmptyHintLink: (URL) -> Void = { _ in }
    /// A queued job refused after Jai left its screen, in its own words, until he dismisses it.
    var lateRefusal: String?
    /// The review on its way from a box that has closed (`PRReviewToast`).
    var reviewToast: PRReviewToast?
    /// A sample set's one refused review has been refused (`PRSampleSet.refusesFirstReview`).
    var sampleReviewRefused = false
    /// Outbox answers by item id, until the screen that is waiting on one takes it.
    var outcomes: [String: Result<Data, PRWorkerError>] = [:]
    /// Ids a screen is waiting on. Answers to the rest arrive after Jai has moved on.
    var waiting: Set<String> = []
    /// Each job still on the phone, so a refusal that comes after the screen has gone can say what it was.
    var queued: [String: PROutboxJob] = [:]
    /// How long a screen waits for GitHub's answer before the write carries on without it.
    var answerWait: Duration = .seconds(15)
    /// Whether the device has a network: what a question left in the outbox says while it waits.
    var isOnline: () -> Bool = { PRNetworkPath.shared.isOnline }
    let mirror: PRMirror
    /// The newest sync, and its list fetch while that is out: what a wake waits for, and what a pull waits for.
    private var running: Task<PRSyncOutcome, Never>?
    private var listing: Task<PRSyncOutcome, Never>?
    /// Each list fetch's number. Only the newest one's rows show (`PRMirror`).
    private var generation = 0
    /// PRs whose newest files failed to download: each shows its last good revision and says so, until a pull.
    private(set) var notUpdated: Set<String> = []
    /// The last sync ended with PRs still on their way and none failed: they show as each one lands.
    private(set) var stillDownloading = false

    /// Where the mirror says a download or a write failed for good: the host's event log.
    func logFailures(to log: @escaping @Sendable (String) -> Void) {
        mirror.log.set(log)
    }
    private var apnsToken: String?
    /// What the Worker serves, which the PR screens follow: everything in Jai's build; PRHub's pr-worker's
    /// `GET /device/config`. Read through (`PRKitHost.configuration`), so a view that reads it follows a new config.
    @ObservationIgnored var featureSource: @MainActor () -> PRKitConfiguration = { .everything }

    var configuration: PRKitConfiguration {
        featureSource()
    }

    /// `directory`: where the mirror's files go, the app's caches unless a test gives its own.
    init(client: PRViewerClient, samples: PRSampleSet? = nil, directory: URL? = nil) {
        self.client = client
        self.samples = samples
        let name = samples == nil ? "pr-viewer" : PRSampleSet.directoryName
        let directory = directory ?? URL.cachesDirectory.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = samples.map { $0.seed(in: directory) } ?? PRMirror.savedRows(in: directory)
        rows = saved
        if samples != nil {
            localAnswers = [:]
        }
        mirror = PRMirror(directory: directory, client: client, shown: saved)
    }

    var orgs: [String] {
        Set(rows.map(\.org)).sorted()
    }

    var orgDefault: PROrgDefault {
        configuration.orgDefault
    }

    /// Worked out by the Worker's own last successful look at GitHub, so a stuck Worker shows here and not as old code.
    var staleSince: Date? {
        workerSyncedAt.flatMap { Date.now.timeIntervalSince($0) > Self.staleAfter ? $0 : nil }
    }

    func loadMerged(on page: PRListPage) async {
        if let samples {
            merged[page] = samples.merged(reviewed: page == .review)
            return
        }
        do {
            merged[page] = try await client.mergedPullRequests(reviewed: page == .review)
            mergedError[page] = nil
        } catch {
            mergedError[page] = error.localizedDescription
        }
    }

    /// A wake that finds a sync running waits for it, rather than reporting work it did not do. A pull waits for a
    /// list alone — the one being fetched, else a new one — and the PRs' files download behind it, each row showing as
    /// its files land: the spinner is for the list, not for every new PR's diff.
    @discardableResult
    func refresh(_ trigger: PRSyncTrigger) async -> PRSyncOutcome {
        if samples != nil {
            onEvent(.synced(trigger, .unchanged))
            return .unchanged
        }
        if trigger == .pull, let listing {
            return await listing.value
        }
        if trigger != .pull, let running {
            return await running.value
        }
        generation += 1
        let generation = generation
        let before = rows
        let listed = Task { await list(generation: generation, retry: trigger == .pull) }
        let listPhase = Task { () -> PRSyncOutcome in
            let outcome = await listed.value ? (rows != before ? PRSyncOutcome.changed : .unchanged) : .failed
            if self.generation == generation {
                listing = nil
            }
            return outcome
        }
        let whole = Task { () -> PRSyncOutcome in
            let outcome = await listed.value ? await download(generation: generation, before: before, trigger) : .failed
            if self.generation == generation {
                running = nil
            }
            onEvent(.synced(trigger, outcome))
            return outcome
        }
        listing = listPhase
        running = whole
        return trigger == .pull ? await listPhase.value : await whole.value
    }

    /// The token is kept either way; it goes to a Worker that pushes (`push`), now and at each foreground sync.
    func register(apnsToken: String) {
        self.apnsToken = apnsToken
        guard configuration.isOn(.push) else {
            return
        }
        let body = PRDeviceRegistration(token: apnsToken, host: apnsEnvironment)
        Task { await post(body, to: "device/register") }
    }

    /// PRHub's Disconnect: the rows, the mirror's files, the answers and the filter, so another Worker's PRs start
    /// from nothing.
    func forgetEverything() {
        rows = []
        merged = [:]
        mergedError = [:]
        errorMessage = nil
        stillDownloading = false
        workerSyncedAt = nil
        removedRequests = []
        notUpdated = []
        lateRefusal = nil
        saveAnswers([:])
        UserDefaults.standard.removeObject(forKey: "prOrgFilter")
        // Nothing of a sync still running may show, and nothing it downloads may stay.
        generation += 1
        running = nil
        listing = nil
        let files = (try? FileManager.default.contentsOfDirectory(at: mirror.directory, includingPropertiesForKeys: nil))
        for file in files ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
        let mirror = mirror
        let generation = generation
        Task { await mirror.forget(generation: generation) }
    }

    /// After a pairing, or a config that turned push on: the token this launch already has.
    func registerKnownToken() {
        if let apnsToken {
            register(apnsToken: apnsToken)
        }
    }

    /// The phone's alone: the Worker reads a sync as the phone being up to date, which decides its pushes.
    func report(_ event: some Encodable & Sendable) async {
        #if os(macOS)
        return
        #else
        await post(event, to: "device/event")
        #endif
    }

    private func post(_ body: some Encodable & Sendable, to path: String) async {
        try? await client.post(path, body)
    }

    /// What a tap pushes. The PR is read and parsed here, on the main thread, so its time counts from the tap. Whatever
    /// the phone holds of it shows at once; `newer`, a row it does not hold yet, is read behind it from the Worker's
    /// stored copy. With nothing on the phone the screen reads `newer`, else `row`, at their versions.
    func session(
        for row: PullRequestRow, source: PROpenReport.Source = .list, newer: PullRequestRow? = nil
    ) -> PRSession {
        let tappedAt = CACurrentMediaTime()
        let ref = PullRequestRef(repo: row.repo, number: row.number)
        onEvent(.opened(ref))
        let content = localContent(row)
        let opening = PROpening(
            source: source, cache: content == nil ? .miss : newer == nil ? .hit : .stale,
            reads: content == nil ? newer ?? row : newer
        )
        return PRSession(
            ref: ref, title: newer?.title ?? row.title, content: content, keyLines: localKeyLines(row),
            tappedAt: tappedAt, model: self, opening: opening
        )
    }

    /// A PR named by a link or an alert: from the phone if it holds it. `pushed` is the row an alert carried (docs/api.md,
    /// "Alerts"), its files on the phone when the Notification Service Extension fetched them. Else the session reads
    /// the PR from the Worker: `pushed` at its version, or, for a PR on no list, live.
    func session(
        for ref: PullRequestRef, pushed: PullRequestRow? = nil, source: PROpenReport.Source = .link
    ) -> PRSession {
        let isThisPR = { (row: PullRequestRow) in
            row.repo.caseInsensitiveCompare(ref.repo) == .orderedSame && row.number == ref.number
        }
        let listed = rows.first(where: isThisPR)
        if let pushed, isThisPR(pushed), mirror.isLocal(pushed) || listed == nil {
            return session(for: pushed, source: source)
        }
        if let listed {
            let isNewer = pushed.map { isThisPR($0) && ($0.detail != listed.detail || $0.revision != listed.revision) }
            return session(for: listed, source: source, newer: isNewer == true ? pushed : nil)
        }
        onEvent(.opened(ref))
        return PRSession(
            ref: ref, title: nil, content: nil, tappedAt: CACurrentMediaTime(), model: self,
            opening: PROpening(source: source, cache: .miss, reads: nil)
        )
    }

    private func localKeyLines(_ row: PullRequestRow) -> PRKeyLines? {
        row.keyLinesFileName
            .flatMap { try? Data(contentsOf: mirror.directory.appending(path: $0)) }
            .flatMap { try? JSONDecoder().decode(PRKeyLines.self, from: $0) }
    }

    /// Asks every few seconds until the Worker's job lands. An answer can be a failure, in the job's own words.
    func aiAnswer<Answer: Decodable>(
        _ kind: String, ref: PullRequestRef, head: String, context: Int = PRKeyLines.defaultContext, retry: Bool
    ) async throws -> Answer {
        if let samples {
            guard kind == "key-lines", let data = samples.keyLines(for: ref) else {
                throw PRLocalRefusal.sampleAI
            }
            return try JSONDecoder().decode(Answer.self, from: data)
        }
        let path = "prs/\(ref.repo)/\(ref.number)/\(kind)"
        var isFirst = true
        while !Task.isCancelled {
            if let data = try await client.aiAnswer(path: path, head: head, context: context, retry: retry && isFirst) {
                if let failure = try? JSONDecoder().decode(PRAIFailure.self, from: data) {
                    throw PRWorkerError.refused(failure.error)
                }
                return try JSONDecoder().decode(Answer.self, from: data)
            }
            isFirst = false
            try await Task.sleep(for: .seconds(3))
        }
        throw CancellationError()
    }

    /// Nil if iOS cleared the cache under a row: the session then reads the PR live.
    private func localContent(_ row: PullRequestRow) -> PRContent? {
        let read = { (name: String) in
            try? Data(contentsOf: self.mirror.directory.appending(path: name), options: .mappedIfSafe)
        }
        guard let detail = read(row.detailFileName).flatMap({ try? PullRequestDetail.decode($0) }) else {
            return nil
        }
        let document = read(row.diffFileName).map(DiffDocument.init)
        return row.hasDiff && document == nil ? nil : PRContent(detail: detail, document: document)
    }

    /// The row reads as answered from now, ahead of the Worker.
    func noteAnswer(_ review: String, on ref: PullRequestRef, head: String) {
        let answer = PRLocalAnswer(review: review, sentAt: Date.now.ISO8601Format(), head: head)
        let isThisPR = { (row: PullRequestRow) in
            row.repo.caseInsensitiveCompare(ref.repo) == .orderedSame && row.number == ref.number
        }
        if let row = rows.first(where: isThisPR) {
            var answers = localAnswers
            answers[row.id] = answer
            saveAnswers(answers)
        }
    }

    private func saveAnswers(_ answers: [String: PRLocalAnswer]) {
        guard answers != localAnswers else {
            return
        }
        localAnswers = answers
        // A sample's answers last as long as it does.
        guard samples == nil else {
            return
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(answers), forKey: Self.answersKey)
    }

    /// Takes Jai off this PR's review on GitHub.
    func removeReviewRequest(_ row: PullRequestRow) {
        removedRequests.insert(row.id)
        if samples != nil {
            return
        }
        Task {
            let ref = PullRequestRef(repo: row.repo, number: row.number)
            do {
                // Posted or saved to go: the row stays away either way.
                _ = try await write(.removeRequest, to: ref)
            } catch {
                removedRequests.remove(row.id)
                refuseLate(PRWrite.removeRequest.refusal(on: ref, reason: error.localizedDescription), of: .write)
            }
        }
    }

    func askChat(_ ref: PullRequestRef) async throws -> PRAskChat {
        if let samples {
            return samples.askChat
                ?? PRAskChat(messages: [], isWorking: false, activity: nil, problem: nil, costCents: nil)
        }
        return try await client.askChat(ref)
    }

    /// A PR the phone does not hold, its detail and diff side by side: `row` at its version, which the Worker serves
    /// from its stored copy, else (a PR on no list) GitHub, through the Worker, now. With how long the Worker took and
    /// how long reading what came took.
    func fetch(_ ref: PullRequestRef, row: PullRequestRow?) async throws -> PRFetched {
        let started = ContinuousClock.now
        async let detail = readDetail(ref, row: row)
        async let diff = readDiff(ref, row: row)
        let (detailData, diffData) = try await (detail, diff)
        let arrived = ContinuousClock.now
        let content = PRContent(detail: try PullRequestDetail.decode(detailData), document: diffData.map(DiffDocument.init))
        return PRFetched(
            content: content, networkMilliseconds: (arrived - started).milliseconds,
            decodeMilliseconds: (ContinuousClock.now - arrived).milliseconds
        )
    }
}

extension PRsModel {
    private func readDetail(_ ref: PullRequestRef, row: PullRequestRow?) async throws -> Data {
        if let row {
            return try await client.detail(row)
        }
        return try await client.liveDetail(ref)
    }

    /// Nil when GitHub won't give a diff this big.
    private func readDiff(_ ref: PullRequestRef, row: PullRequestRow?) async throws -> Data? {
        if row?.hasDiff == false {
            return nil
        }
        do {
            if let row {
                return try await client.diff(row)
            }
            return try await client.liveDiff(ref)
        } catch PRWorkerError.tooLarge {
            return nil
        }
    }

    /// The Worker's list, with the rows whose files are already here on screen at once. False when the Worker didn't
    /// answer: its words are on screen instead.
    private func list(generation: Int, retry: Bool) async -> Bool {
        do {
            let list = try await client.pullRequests()
            workerSyncedAt = Date(timeIntervalSince1970: list.synced_at / 1000)
            if let shown = await mirror.begin(list.prs, generation: generation, retry: retry),
               generation == self.generation {
                rows = shown
                if retry {
                    notUpdated = []
                }
            }
            return true
        } catch {
            stillDownloading = false
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Every PR the list names that is not on the phone yet, then the rest of a sync: the answers, the push token and
    /// the report to the Worker. A sync a newer list has overtaken leaves all that to the newer one, and waits for it.
    private func download(generation: Int, before: [PullRequestRow], _ trigger: PRSyncTrigger) async -> PRSyncOutcome {
        let result = await mirror.sync(generation: generation) { [weak self] generation, rows, failed in
            await self?.landed(rows, failed: failed, generation: generation)
        }
        guard let result, generation == self.generation else {
            // Overtaken: the newer sync downloads what this one wanted too, and says what came of it.
            if let running {
                _ = await running.value
            }
            return rows != before ? .changed : .unchanged
        }
        let changed = result.rows != before
        rows = result.rows
        notUpdated = result.failed
        removedRequests.formIntersection(rows.map(\.id))
        saveAnswers(localAnswers.filter { id, answer in answer.isNeeded(by: rows.first { $0.id == id }) })
        stillDownloading = !result.isComplete && result.failed.isEmpty
        errorMessage = result.isComplete ? nil : Self.notUpToDate(
            listed: result.listed, shown: result.rows.count, failed: result.failed.count
        )
        if trigger == .foreground, configuration.isOn(.push), let apnsToken {
            let device = PRDeviceRegistration(token: apnsToken, host: apnsEnvironment)
            await post(device, to: "device/register")
        }
        await report(PRSyncEvent(
            trigger: trigger.rawValue, rows: result.rows.count, changed: result.fetched, complete: result.isComplete
        ))
        onEvent(.reviewRequests(rows.filter { $0.isReviewRequest && !removedRequests.contains($0.id) }.count))
        return changed ? .changed : .unchanged
    }

    /// What a sync that left PRs behind says: with nothing to show, why the list is empty; else how many are behind.
    static func notUpToDate(listed: Int, shown: Int, failed: Int) -> String {
        if failed == 0 {
            return "Still downloading PRs. Each one shows when it arrives."
        }
        if shown == 0 {
            return "GitHub lists \(listed) PRs, but none could be downloaded to this device. Refresh to try again."
        }
        return "\(failed) of \(listed) PRs could not be downloaded and show their last copy. Refresh to try again."
    }

    /// A PR's files have landed: its row shows, unless a newer list has begun since.
    private func landed(_ landed: [PullRequestRow], failed: Set<String>, generation: Int) {
        if generation == self.generation {
            rows = landed
            notUpdated = failed
        }
    }
}

private struct PRDeviceRegistration: Encodable, Sendable {
    let token: String
    let host: String
}

private struct PRSyncEvent: Encodable, Sendable {
    let kind = "sync"
    let trigger: String
    let rows: Int
    let changed: [String]
    let complete: Bool
}

/// A PR read from the Worker, and how long that took.
struct PRFetched: Sendable {
    let content: PRContent
    let networkMilliseconds: Int
    let decodeMilliseconds: Int
}

/// How a session opened: what opened it, what the phone had, and the row its screen reads, if any.
struct PROpening: Sendable {
    let source: PROpenReport.Source
    let cache: PROpenReport.Cache
    /// What the screen reads: with nothing on the phone, its content; with an older copy, the newer one behind it. Nil:
    /// nothing to read (a hit), or a PR on no list, read live.
    let reads: PullRequestRow?
}

extension Duration {
    var milliseconds: Int {
        Int((Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15).rounded())
    }
}

/// One tap on a PR: how long the diff took and whether it was already on the phone.
struct PROpenEvent: Encodable, Sendable {
    let kind = "open"
    let milliseconds: Int
    let parseMilliseconds: Int
    let preloaded: Bool
    let bytes: Int
    let lines: Int
}
