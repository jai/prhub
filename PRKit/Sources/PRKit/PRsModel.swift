import DurableNetworking
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
    /// The sample PRs merged on this phone, newest first, under the page that listed them.
    private var sampleMerged: [PRListPage: [PullRequestRow]] = [:]
    private(set) var mergedError: [PRListPage: String] = [:]
    private(set) var errorMessage: String?
    private(set) var workerSyncedAt: Date?
    /// Questions to a PR's AI not yet sent, by PR and by what each is about (`PRSession.askDraft`). Kept while the
    /// app runs, so a visit to another PR does not lose one.
    @ObservationIgnored var askDrafts: [String: String] = [:]
    /// Rows Jai swiped away. They stay hidden until the Worker's list drops them, so one can't flicker back.
    private(set) var removedRequests: Set<String> = []
    /// By row id. Saved, so a row stays read through a restart until the Worker's list catches up.
    private(set) var localAnswers: [String: PRLocalAnswer]
    let defaults: UserDefaults
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
    /// Unknown IDs can belong to an enqueue that has not returned its ID yet.
    @ObservationIgnored var enqueuesInFlight = 0
    @ObservationIgnored var earlyOutboxDeliveries: [PROutboxDelivery] = []
    /// Ids a screen is waiting on. Answers to the rest arrive after Jai has moved on.
    var waiting: Set<String> = []
    /// Each job still on the phone, so a refusal that comes after the screen has gone can say what it was.
    var queued: [String: PROutboxJob] = [:]
    /// How long a screen waits for GitHub's answer before the write carries on without it.
    var answerWait: Duration = .seconds(15)
    /// The screen waiting on each id in `waiting`: woken by its answer, the end of `answerWait` or its cancellation.
    @ObservationIgnored var answerWaits: [String: CheckedContinuation<Void, Never>] = [:]
    /// The model's clock: the answer wait, the Ask sheet's reads (`followAsk`) and the review toast's dwell are waited
    /// out on it. A test passes its own, which moves only when the test moves it.
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Whether the device has a network now (`PRNetwork`), which the host's offline banner shows too.
    let network: PRNetwork
    /// Whether the device has a network: what a question left in the outbox says while it waits. A test sets its own.
    @ObservationIgnored var isOnline: @MainActor () -> Bool
    private let draftDirectory: URL?

    var draftStore: PRDraftStore {
        if let draftDirectory {
            return PRDraftStore(directory: draftDirectory)
        }
        return PRDraftStore()
    }

    let mirror: PRMirror
    /// Last good answers to the reads the mirror doesn't hold (the merged lists, each PR's Ask chat, key lines at
    /// other contexts, reviewed ticks), in the mirror's folder.
    var kept: ReadStore {
        ReadStore(directory: mirror.directory.appending(path: PRMirror.keptFolder, directoryHint: .isDirectory))
    }

    /// The newest sync, and its list fetch while that is out: what a wake waits for, and what a pull waits for.
    private var running: Task<PRSyncOutcome, Never>?
    private var listing: Task<PRSyncOutcome, Never>?
    /// Each list fetch's number. Only the newest one's rows show (`PRMirror`).
    private var generation = 0
    /// PRs whose newest files failed to download: each shows its last good revision and says so, until a pull.
    private(set) var notUpdated: Set<String> = []
    /// The last sync ended with PRs still on their way and none failed: they show as each one lands.
    private(set) var stillDownloading = false
    /// How many PRs the newest list named: with `isSyncing`, how many are still on their way.
    private(set) var listedCount = 0

    /// A sync is running: on a first sign-in, the only sign the list is coming.
    var isSyncing: Bool {
        running != nil
    }

    /// PRs the running sync has listed and not yet shown.
    var arrivingCount: Int {
        isSyncing ? max(0, listedCount - rows.count) : 0
    }

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
    init(
        client: PRViewerClient, samples: PRSampleSet? = nil, directory: URL? = nil,
        defaults: UserDefaults = .standard, network: PRNetwork = PRNetwork(), draftDirectory: URL? = nil
    ) {
        self.network = network
        self.draftDirectory = draftDirectory
        self.defaults = defaults
        localAnswers = defaults.data(forKey: Self.answersKey)
            .flatMap { try? JSONDecoder().decode([String: PRLocalAnswer].self, from: $0) } ?? [:]
        self.client = client
        self.samples = samples
        let name = samples == nil ? "pr-viewer" : PRSampleSet.directoryName
        let directory = directory ?? URL.cachesDirectory.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = samples.map { $0.seed(in: directory, defaults: defaults) } ?? PRMirror.savedRows(in: directory)
        rows = saved
        if let samples {
            localAnswers = [:]
            errorMessage = samples.notUpToDate
        }
        mirror = PRMirror(directory: directory, client: client, shown: saved)
        isOnline = { [network] in network.isOnline }
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
            merged[page] = (sampleMerged[page] ?? []) + samples.merged(reviewed: page == .review)
            return
        }
        // The last good list shows at once, and stays if this read fails.
        let key = InboxKey("merged-\(page.rawValue)")
        if merged[page] == nil, let saved = kept.load(key),
           let rows = try? JSONDecoder().decode([PullRequestRow].self, from: saved.data)
        {
            merged[page] = rows
        }
        do {
            let rows = try await client.mergedPullRequests(reviewed: page == .review)
            merged[page] = rows
            mergedError[page] = nil
            if let data = try? JSONEncoder().encode(rows) {
                try? kept.save(KeptAnswer(data: data, savedAt: .now), for: key)
            }
        } catch {
            mergedError[page] = error.localizedDescription
        }
    }

    /// A sample PR's row after a write that stayed on the phone, as the Worker's next list would have it
    /// (`PRSampleSet.applying`). A merged PR leaves the open ones for its page's merged ones.
    func sampleWritten(_ write: PRWrite, to row: PullRequestRow) {
        guard let samples, let index = rows.firstIndex(of: row) else {
            return
        }
        guard case .merge = write, let status = row.status else {
            rows[index] = PRSampleSet.applying(write, to: row)
            return
        }
        rows.remove(at: index)
        let page = PRListPage.allCases.first { $0.holds(row) } ?? .mine
        let mergedRow = row.with(status.with(list: "merged", mergedAt: Date.now.ISO8601Format()))
        sampleMerged[page, default: []].insert(mergedRow, at: 0)
        merged[page] = (sampleMerged[page] ?? []) + samples.merged(reviewed: page == .review)
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
        listedCount = 0
        removedRequests = []
        notUpdated = []
        lateRefusal = nil
        saveAnswers([:])
        defaults.removeObject(forKey: "prOrgFilter")
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
    /// stored copy. With nothing on the phone the screen reads `newer`, else `row`, at their versions. `readsLive`: a
    /// PR on no list, whose copy on the phone may be days old, is read live behind it.
    func session(
        for row: PullRequestRow, source: PROpenReport.Source = .list, newer: PullRequestRow? = nil, readsLive: Bool = false
    ) -> PRSession {
        let tappedAt = CACurrentMediaTime()
        let ref = PullRequestRef(repo: row.repo, number: row.number)
        onEvent(.opened(ref))
        let content = localContent(row)
        let opening = PROpening(
            source: source, cache: content == nil ? .miss : newer == nil ? .hit : .stale,
            reads: content == nil ? newer ?? row : newer, readsLive: readsLive && content != nil && newer == nil
        )
        return PRSession(
            ref: ref, title: newer?.title ?? row.title, content: content, keyLines: localKeyLines(row),
            tappedAt: tappedAt, model: self, opening: opening
        )
    }

    /// A PR named by a link or an alert: from the phone if it holds it. `pushed` is the row an alert carried (docs/api.md,
    /// "Alerts"), its files on the phone when the Notification Service Extension fetched them (kept while the alert can
    /// be tapped, `PRAlertedFiles`); a PR on no list is then read live behind them. Else the session reads the PR from
    /// the Worker: `pushed` at its version, or, for a PR on no list, live.
    func session(
        for ref: PullRequestRef, pushed: PullRequestRow? = nil, source: PROpenReport.Source = .link
    ) -> PRSession {
        let isThisPR = { (row: PullRequestRow) in
            row.repo.caseInsensitiveCompare(ref.repo) == .orderedSame && row.number == ref.number
        }
        let listed = rows.first(where: isThisPR)
        if let pushed, isThisPR(pushed), mirror.isLocal(pushed) || listed == nil {
            return session(for: pushed, source: source, readsLive: listed == nil)
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

    /// Your standing review on this PR: the newer of the one sent from this device and the Worker's.
    func yourReview(on ref: PullRequestRef) -> PRJaiReview? {
        guard let row = rows.first(where: {
            $0.repo.caseInsensitiveCompare(ref.repo) == .orderedSame && $0.number == ref.number
        }) else {
            return nil
        }
        let worker = row.status?.jaiReview
        let local = localAnswers[row.id]
        let date = { (text: String?) in text.flatMap { try? Date($0, strategy: .iso8601) } ?? .distantPast }
        let isLocalNewer = local.map { date($0.sentAt) > date(row.status?.jaiReviewedAt) } ?? false
        return (isLocalNewer ? local?.review : worker).flatMap(PRJaiReview.init(rawValue:))
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
        defaults.set(try? JSONEncoder().encode(answers), forKey: Self.answersKey)
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

    func postAskLinear(message: String, index: Int, about ref: PullRequestRef) async throws -> PRAskChat {
        if samples != nil {
            throw SamplesPostNothing()
        }
        return try await client.postAskLinear(message: message, index: index, about: ref)
    }

    func askChat(_ ref: PullRequestRef) async throws -> PRAskChat {
        if let samples {
            return samples.askChat
                ?? PRAskChat(messages: [], isWorking: false, activity: nil, problem: nil, costCents: nil)
        }
        let (chat, data) = try await client.askChatAnswer(ref)
        try? kept.save(KeptAnswer(data: data, savedAt: .now), for: Self.askKey(ref))
        return chat
    }

    /// The chat on this PR as last read, on this device: what the sheet shows before the Worker answers, and offline.
    func keptAskChat(_ ref: PullRequestRef) -> PRAskChat? {
        guard samples == nil, let saved = kept.load(Self.askKey(ref)) else {
            return nil
        }
        return try? JSONDecoder().decode(PRAskChat.self, from: saved.data)
    }

    private static func askKey(_ ref: PullRequestRef) -> InboxKey {
        InboxKey("ask-\(ref.repo)/\(ref.number)")
    }

    /// Keeps an answer the Worker sent, for `kept(_:as:)` to give back offline and on the next launch.
    func keep(_ data: Data, as key: InboxKey) {
        guard samples == nil else {
            return
        }
        try? kept.save(KeptAnswer(data: data, savedAt: .now), for: key)
    }

    /// The answer kept under `key`, if there is one this build can read.
    func kept<Answer: Decodable>(_ key: InboxKey, as type: Answer.Type) -> Answer? {
        guard samples == nil, let saved = kept.load(key) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: saved.data)
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
        let decoded: PullRequestDetail
        do {
            decoded = try PullRequestDetail.decode(detailData)
        } catch {
            client.reportFailure(path: "prs/\(ref.repo)/\(ref.number)/detail", .unreadable)
            throw error
        }
        let content = PRContent(detail: decoded, document: diffData.map(DiffDocument.init))
        return PRFetched(
            content: content, networkMilliseconds: (arrived - started).milliseconds,
            decodeMilliseconds: (ContinuousClock.now - arrived).milliseconds
        )
    }
}

// MARK: - The Worker's model

extension PRsModel {
    /// Asks every few seconds until the Worker's job lands. An answer can be a failure, in the job's own words. How it
    /// went goes to the host (`PRKitEvent.aiAnswered`): how long it took, and for key lines whether the description
    /// reads as AI slop (the AI trash chip).
    func aiAnswer<Answer: Decodable>(
        _ kind: String, ref: PullRequestRef, head: String, context: Int = PRKeyLines.defaultContext, retry: Bool,
        keep key: InboxKey? = nil
    ) async throws -> Answer {
        let started = ContinuousClock.now
        let report = { (outcome: PRActionOutcome, slop: Bool?) in
            guard let kind = PRAIKind(route: kind) else {
                return
            }
            self.onEvent(.aiAnswered(
                kind, outcome, milliseconds: (ContinuousClock.now - started).milliseconds, slop: slop
            ))
        }
        do {
            let answer: Answer = try await readAIAnswer(
                kind, ref: ref, head: head, context: context, retry: retry, keep: key
            )
            report(.done, (answer as? PRKeyLines)?.summary?.isSlop)
            return answer
        } catch {
            if let outcome = PRActionOutcome(error: error) {
                report(outcome, nil)
            }
            throw error
        }
    }

    private func readAIAnswer<Answer: Decodable>(
        _ kind: String, ref: PullRequestRef, head: String, context: Int, retry: Bool, keep key: InboxKey?
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
            let data: Data?
            // `retry` goes with the first request only: again, it would drop an answer the Worker has just made.
            let asksAgain = retry && isFirst
            isFirst = false
            do {
                data = try await client.aiAnswer(path: path, head: head, context: context, retry: asksAgain)
            } catch where error.isPassingAIFailure {
                try await Task.sleep(for: .seconds(5))
                continue
            }
            if let data {
                if let failure = try? JSONDecoder().decode(PRAIFailure.self, from: data) {
                    if failure.moved == true {
                        throw PRAIHeadMoved()
                    }
                    throw PRWorkerError.refused(failure.error)
                }
                let answer = try client.decode(Answer.self, from: data, path: path)
                if let key {
                    keep(data, as: key)
                }
                return answer
            }
            try await Task.sleep(for: .seconds(3))
        }
        throw CancellationError()
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
            listedCount = list.prs.count
            if let shown = await mirror.begin(list.prs, generation: generation, retry: retry),
               generation == self.generation
            {
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
    /// A PR on no list, shown from the phone: read live behind it.
    var readsLive = false
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

/// A sample PR's Linear ticket is made up: nothing posts.
struct SamplesPostNothing: LocalizedError {
    var errorDescription: String? {
        "Sample PRs don't post to Linear."
    }
}
