import PRKitCore
import PRKitDesign
import SwiftUI

/// The PRs tab. Where it is narrow (a phone, Slide Over, a narrow Split View) a stack: the list, a PR pushed over it and
/// its diff over that. Where it is wide, the list beside the PR, and a diff takes the whole width. Both show
/// `PRNavigation`'s routes, so a change of width keeps what is open.
struct PRsView: View {
    let model: PRsModel
    @Bindable var navigation: PRNavigation
    let launchOptions: PRKitLaunchOptions
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        layout
            .environment(\.showsReviewToastAbove, true)
            .overlay(alignment: .top) { PRReviewToastView(model: model) }
            .background {
                if let session = navigation.diffOnShow {
                    PRDiffShortcuts(session: session)
                }
            }
            .onChange(of: navigation.pending, initial: true) { _, pending in
                if let pending {
                    navigation.pending = nil
                    open(pending)
                }
            }
            .task {
                guard !launchOptions.isEmpty else {
                    return
                }
                try? await Task.sleep(for: .seconds(3))
                openBenchmark()
                if let ref = launchOptions.linkAfterOpening {
                    try? await Task.sleep(for: .seconds(2))
                    navigation.pending = PRPendingOpen(link: PRLink(ref: ref), source: .push, pushed: nil)
                }
            }
    }

    @ViewBuilder private var layout: some View {
        #if os(iOS)
        if sizeClass == .regular {
            PRsSplitView(model: model, navigation: navigation)
        } else {
            stack
        }
        #else
        stack
        #endif
    }

    private var stack: some View {
        #if os(macOS)
        TabStack(path: $navigation.macPath) { stackRoot }
            .opensPullRequestLinks(on: .routes($navigation.routes))
        #else
        TabStack(path: $navigation.routes) { stackRoot }
            .opensPullRequestLinks(on: .routes($navigation.routes))
        #endif
    }

    private var stackRoot: some View {
        PRsList(model: model, selected: nil)
            .returnedToOnMac(atRoot: navigation.routes.isEmpty)
            .showsPullRequests()
    }

    /// A link from a notification: there is no stack of its own to go back to, so it shows here, over nothing else.
    private func open(_ pending: PRPendingOpen) {
        let session = model.session(for: pending.link.ref, pushed: pending.pushed, source: pending.source)
        navigation.routes = PRRoute.opening(session, showsDiff: pending.link.showsDiff)
    }

    /// A benchmark or UI test's launch: the row, on its diff when `-prPage Diff` asks.
    private func openBenchmark() {
        guard let id = launchOptions.benchmarkRow, let row = model.rows.first(where: { $0.id == id }) else {
            return
        }
        #if DEBUG
        let showsDiff = UserDefaults.standard.string(forKey: "prPage") == "Diff"
        #else
        let showsDiff = false
        #endif
        navigation.routes = PRRoute.opening(model.session(for: row), showsDiff: showsDiff)
    }
}

/// The list of PRs: one row per PR, from the file on disk, and a tap opens it.
struct PRsList: View {
    let model: PRsModel
    /// The PR open beside the list on a wide screen, marked in it.
    let selected: PullRequestRef?
    @Environment(\.pullRequestOpener) private var opener
    @State private var folds = FoldSet()
    /// `nil` until a filter is picked: then the model's default, which can follow the Worker.
    @AppStorage("prOrgFilter") private var savedOrgFilter: PROrgFilter?
    @AppStorage("prListPage") private var page = PRListPage.review
    @State private var isShowingFilter = false
    @AppStorage("prShowsMerged") private var showsMyMerged = false
    @AppStorage("prShowsMergedReviews") private var showsReviewedMerged = false
    @AppStorage("prListOrder") private var order = PRListOrder.sla
    @AppStorage("prListGrouping") private var grouping = PRListGrouping.none

    private var orgFilter: PROrgFilter {
        savedOrgFilter ?? model.orgDefault.filter(owners: model.orgs)
    }

    private var orgFilterBinding: Binding<PROrgFilter> {
        Binding(get: { orgFilter }, set: { savedOrgFilter = $0 })
    }

    private var liveRows: [PullRequestRow] {
        model.rows
            .filter { !model.removedRequests.contains($0.id) }
            .map { $0.answered(model.localAnswers[$0.id]) }
    }

    private func rows(on page: PRListPage) -> [PullRequestRow] {
        if showsMerged(on: page) {
            return (model.merged[page] ?? []).filter { orgFilter.shows($0) }
        }
        return PRListPage.ordered(liveRows.filter { page.holds($0) && orgFilter.shows($0) }, by: order)
    }

    /// My PRs shows Jai's open PRs or, picked in the filter, his merged ones.
    /// Each page shows open PRs or, picked in the filter, merged ones: Jai's own on My PRs, the ones he reviewed on For
    /// review.
    private func showsMerged(on page: PRListPage) -> Bool {
        page == .mine ? showsMyMerged : showsReviewedMerged
    }

    private var showsMergedHere: Bool { showsMerged(on: page) }

    private var showsMergedBinding: Binding<Bool> {
        page == .mine ? $showsMyMerged : $showsReviewedMerged
    }

    /// What the repo list offers: this page's repos in the chosen orgs, and any already picked.
    private var repoCounts: [String: Int] {
        var counts = Dictionary(orgFilter.repos.map { ($0, 0) }, uniquingKeysWith: { first, _ in first })
        for row in liveRows where page.holds(row) && orgFilter.showsOrg(of: row) {
            counts[row.repo, default: 0] += 1
        }
        return counts
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.sm) {
                if let since = model.staleSince {
                    banner("Last checked GitHub \(since.formatted(.relative(presentation: .named)))")
                }
                if !model.rows.isEmpty, let message = model.errorMessage {
                    banner("Not up to date. \(message)")
                }
                if let refused = model.lateRefusal {
                    Button { model.dismissLateRefusal() } label: {
                        Label {
                            Text(refused)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } icon: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .font(.appCaption)
                        .foregroundStyle(Color.toneBad)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.sm)
                    .accessibilityHint("Dismisses this")
                    .transition(.fold)
                }
                pagePicker
                if !orgFilter.repos.isEmpty {
                    repoFilterNote
                }
                list(rows(on: page), on: page)
                if model.arrivingCount > 0, !model.rows.isEmpty {
                    arriving
                }
                if showsMergedHere, let error = model.mergedError[page] {
                    banner("Merged PRs didn't load. \(error)")
                }
            }
            .padding(.bottom, Space.lg)
        }
        .animation(AppMotion.fold, value: model.rows)
        .animation(AppMotion.fold, value: model.errorMessage)
        .animation(AppMotion.fold, value: model.lateRefusal)
        .animation(AppMotion.fold, value: orgFilter)
        .animation(AppMotion.fold, value: page)
        .animation(AppMotion.fold, value: model.merged)
        .animation(AppMotion.fold, value: showsMergedHere)
        .animation(AppMotion.fold, value: model.removedRequests)
        .animation(AppMotion.fold, value: model.localAnswers)
        .animation(AppMotion.fold, value: order)
        .animation(AppMotion.fold, value: grouping)
        .animation(AppMotion.fold, value: model.isSyncing)
        .background(Color.groundPage)
        .navigationTitle("PRs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { filterButton }
        }
        .overlay {
            if model.rows.isEmpty, model.isSyncing {
                ProgressView(model.arrivingCount > 0 ? "Downloading \(model.arrivingCount) PRs…" : "Loading PRs…")
                    .accessibilityIdentifier("pr-list-loading")
                    .transition(.opacity)
            } else if model.rows.isEmpty, let message = model.errorMessage {
                ContentUnavailableView(
                    model.stillDownloading ? "Downloading PRs" : "PRs didn't load", systemImage: "arrow.triangle.pull",
                    description: Text(message)
                )
            } else if model.rows.isEmpty, model.workerSyncedAt != nil || model.samples != nil,
                      let hint = model.configuration.emptyHint {
                emptyHint(hint)
                    .transition(.opacity)
            } else if !model.rows.isEmpty, rows(on: page).isEmpty, !showsMergedHere || model.mergedError[page] == nil {
                ContentUnavailableView(
                    "No PRs", systemImage: "line.3.horizontal.decrease",
                    description: Text("None in the orgs and repos you picked.")
                )
            }
        }
        .refreshable {
            await model.refresh(.pull)
            if showsMergedHere { await model.loadMerged(on: page) }
        }
        .task(id: "\(page.rawValue)-\(showsMergedHere)") {
            if showsMergedHere { await model.loadMerged(on: page) }
        }
    }

    /// In the list, not the bar: it scrolls away with the first rows, so it costs no room while reading.
    /// The counts change in place: the list's fold animation would slide the segments' labels, so they take none.
    private var pagePicker: some View {
        Picker("List", selection: $page) {
            Text(
                showsReviewedMerged ? "Reviewed merged\(count(rows(on: .review).count))"
                    : "For review\(count(rows(on: .review).filter(\.isReviewRequest).count))"
            )
            .monospacedDigit()
            .tag(PRListPage.review)
            Text("\(showsMyMerged ? "My merged" : "My PRs")\(count(rows(on: .mine).count))")
                .monospacedDigit()
                .tag(PRListPage.mine)
        }
        .pickerStyle(.segmented)
        .transaction { $0.animation = nil }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.sm)
        .accessibilityIdentifier("pr-list-page")
    }

    /// No count until the first list has come: a zero then would say there is nothing to review.
    private func count(_ count: Int) -> String {
        model.rows.isEmpty && model.isSyncing ? "" : " · \(count)"
    }

    /// Under the rows while a sync still has PRs on their way: each shows as it lands.
    private var arriving: some View {
        HStack(spacing: Space.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Downloading \(model.arrivingCount) more PRs…")
                .font(.appCaption)
                .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.sm)
        .transition(.fold)
        .accessibilityIdentifier("pr-list-arriving")
    }

    /// A filter can hide most of a list, so it says so, and one tap undoes it.
    private var repoFilterNote: some View {
        Button {
            orgFilterBinding.wrappedValue.showAllRepos()
        } label: {
            let count = orgFilter.repos.count
            Text("\(count) repo\(count == 1 ? "" : "s") · Clear")
                .font(.appCaption)
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, Space.lg)
                .frame(minHeight: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pr-repo-filter-clear")
    }

    private var filterButton: some View {
        let symbol = "line.3.horizontal.decrease.circle"
        let narrowed = !orgFilter.repos.isEmpty || showsMergedHere
        return Button("Filter", systemImage: narrowed ? "\(symbol).fill" : symbol) {
            isShowingFilter = true
        }
        .accessibilityIdentifier("pr-org-filter")
        .popover(isPresented: $isShowingFilter) {
            PRFilterPanel(
                orgs: model.orgs, repoCounts: repoCounts, filter: orgFilterBinding,
                showsMerged: showsMergedBinding, order: page == .review && !showsMergedHere ? $order : nil,
                grouping: $grouping
            )
                .presentationCompactAdaptation(.popover)
        }
    }

    /// The host's words for a list GitHub left empty, and its link (`PRKitConfiguration.emptyHint`), or a spinner while
    /// the host checks them.
    private func emptyHint(_ hint: PREmptyHint) -> some View {
        ContentUnavailableView {
            Label(hint.title, systemImage: "arrow.triangle.pull")
        } description: {
            Text(hint.message)
        } actions: {
            if hint.isChecking {
                ProgressView()
                    .accessibilityIdentifier("pr-empty-hint-checking")
            } else {
                Link(hint.linkTitle, destination: hint.link)
                    .buttonStyle(PRButtonStyle(.primary))
                    .environment(\.openURL, OpenURLAction { [model] url in
                        model.onEmptyHintLink(url)
                        return .systemAction
                    })
                    .accessibilityIdentifier("pr-empty-hint-link")
            }
        }
    }

    private func banner(_ text: String) -> some View {
        Text(text)
            .font(.appCaption)
            .foregroundStyle(Color.toneWaiting)
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.sm)
    }

    /// Rows are `PrListBlock`s, as in Agents → Lists: a tap is a PR link, which `opensPullRequestLinks` pushes here.
    /// One `ForEach` across both sections, so a PR Jai has just reviewed slides down to Recently Reviewed.
    private func list(_ rows: [PullRequestRow], on page: PRListPage) -> some View {
        ForEach(page.entries(rows, grouping: grouping)) { entry in
            switch entry {
            case let .header(title):
                PRSectionTitle(title)
                    .padding(.top, Space.sm)
            case let .row(row):
                rowView(row)
            }
        }
    }

    @ViewBuilder private func rowView(_ row: PullRequestRow) -> some View {
        let ref = PullRequestRef(repo: row.repo, number: row.number)
        let block = PrListBlock(
            item: PRListItem(
                ticket: row.tickets?.first ?? row.ticket, moreTickets: Array(row.tickets?.dropFirst() ?? []),
                pullRequests: [row.listPullRequest], title: nil, note: nil
            ),
            id: row.id, sentAt: .now, now: .now, folds: folds
        )
        .notUpdated(model.notUpdated.contains(row.id))
        .selected(selected == ref)
        .environment(\.openURL, OpenURLAction { url in
            guard let link = PRLink(url: url), let opener else {
                return .systemAction
            }
            opener.open(link, source: .list)
            return .handled
        })
        PRSwipeRow(
            leading: opener.map { opener in
                PRSwipeAction(
                    title: "Review changes", icon: .reviewChanges, id: "pr-swipe-review", tone: .accent, inMenu: false
                ) { opener.review(ref, source: .list) }
            },
            trailing: row.isReviewRequest ? PRSwipeAction(
                title: row.status?.review == "approved" ? "Approved · Remove me" : "Remove me", icon: .dismiss,
                id: "pr-remove-request", tone: .destructive
            ) { model.removeReviewRequest(row) } : nil
        ) {
            block
        }
    }
}

/// Orgs on top, then the repos in them, each with how many PRs it holds on this page. A popover and not a menu: it
/// scrolls a long list, and the repos change the moment an org does. They come from rows already on the phone, so none
/// has to load.
struct PRFilterPanel: View {
    let orgs: [String]
    let repoCounts: [String: Int]
    @Binding var filter: PROrgFilter
    /// On My PRs only.
    var showsMerged: Binding<Bool>?
    /// On the open review list only: the other lists have no request times to order by.
    var order: Binding<PRListOrder>?
    @Binding var grouping: PRListGrouping

    private var repos: [String] {
        repoCounts.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let order {
                    PRSectionTitle("Sort").padding(.bottom, Space.xs)
                    ForEach(PRListOrder.allCases) { choice in
                        row(choice.title, isOn: order.wrappedValue == choice, id: "pr-sort-\(choice.rawValue)") {
                            order.wrappedValue = choice
                        }
                    }
                    Divider()
                        .padding(.vertical, Space.sm)
                }
                PRSectionTitle("Group").padding(.bottom, Space.xs)
                ForEach(PRListGrouping.allCases) { choice in
                    row(choice.title, isOn: grouping == choice, id: "pr-group-\(choice.rawValue)") {
                        grouping = choice
                    }
                }
                Divider()
                    .padding(.vertical, Space.sm)
                if let showsMerged {
                    PRSectionTitle("Show").padding(.bottom, Space.xs)
                    row("Open", isOn: !showsMerged.wrappedValue, id: "pr-filter-open") {
                        showsMerged.wrappedValue = false
                    }
                    row("Merged", isOn: showsMerged.wrappedValue, id: "pr-filter-merged") {
                        showsMerged.wrappedValue = true
                    }
                    Divider()
                        .padding(.vertical, Space.sm)
                }
                PRSectionTitle("Orgs").padding(.bottom, Space.xs)
                ForEach(orgs, id: \.self) { org in
                    row(org, isOn: filter.selected.contains(org), id: "pr-filter-org-\(org)") { filter.toggle(org) }
                }
                Divider()
                    .padding(.vertical, Space.sm)
                PRSectionTitle("Repos").padding(.bottom, Space.xs)
                row("All repos", isOn: filter.repos.isEmpty, id: "pr-filter-all-repos") { filter.showAllRepos() }
                ForEach(repos, id: \.self) { repo in
                    row(
                        name(of: repo), count: repoCounts[repo], isOn: filter.repos.contains(repo),
                        id: "pr-filter-repo-\(repo)"
                    ) { filter.toggleRepo(repo) }
                }
            }
            .padding(.vertical, Space.md)
        }
        .presentedScrollMargins()
        .frame(width: 300, height: 440)
    }

    /// A short name, unless two orgs are on and it could be either.
    private func name(of repo: String) -> String {
        filter.selected.count > 1 ? repo : String(repo.drop { $0 != "/" }.dropFirst())
    }


    private func row(
        _ title: String, count: Int? = nil, isOn: Bool, id: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                Image(systemName: "checkmark")
                    .font(.appCaption.weight(.semibold))
                    .opacity(isOn ? 1 : 0)
                    .frame(width: 16)
                Text(title)
                    .font(.appFootnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let count {
                    Text("\(count)")
                        .font(.appCaption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Space.lg)
            .frame(minHeight: 40)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}
