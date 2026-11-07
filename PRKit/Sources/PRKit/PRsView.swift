import PRKitCore
import PRKitDesign
import SwiftUI

/// Goes on a `NavigationStack`, not inside it: pushed screens take their environment from the stack. A PR link in any of
/// them then pushes the PR on this stack, so Back returns to where the link was.
struct PullRequestLinks: ViewModifier {
    @Environment(PRsModel.self) private var model
    @Binding var path: NavigationPath
    /// The PRs tab's: Back from any PR is the list. A link from another tab's screen returns to that screen.
    var backGoesToRoot = false

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard let ref = PullRequestRef(url: url) else {
                    return .systemAction
                }
                path.append(model.session(for: ref))
                return .handled
            })
            .environment(\.pullRequestBack, PullRequestBack(path: $path, goesToRoot: backGoesToRoot))
    }
}

/// What a PR's Back does on the Mac, in place of the system's Back and Forward (`PRScreen.macBackButton`).
struct PullRequestBack {
    let path: Binding<NavigationPath>
    let goesToRoot: Bool

    @MainActor func callAsFunction() {
        if goesToRoot {
            path.wrappedValue = NavigationPath()
        } else if !path.wrappedValue.isEmpty {
            path.wrappedValue.removeLast()
        }
    }
}

extension EnvironmentValues {
    @Entry var pullRequestBack: PullRequestBack?
}

/// Goes inside the `NavigationStack`.
struct PullRequestDestination: ViewModifier {
    /// Handed on by name: on the Mac a pushed screen doesn't get what is set on its stack.
    @Environment(\.pullRequestBack) private var back

    func body(content: Content) -> some View {
        content.navigationDestination(for: PRSession.self) {
            PRScreen(session: $0)
                .environment(\.pullRequestBack, back)
                .pushedOnMac()
        }
    }
}

/// The PRs tab: one row per PR, from the file on disk, and a tap pushes it.
struct PRsView: View {
    let model: PRsModel
    @Bindable var navigation: PRNavigation
    let launchOptions: PRKitLaunchOptions
    @State private var folds = FoldSet()
    /// `nil` until a filter is picked: then the model's default, which can follow the Worker.
    @AppStorage("prOrgFilter") private var savedOrgFilter: PROrgFilter?
    @AppStorage("prListPage") private var page = PRListPage.review
    @State private var isShowingFilter = false
    @AppStorage("prShowsMerged") private var showsMyMerged = false
    @AppStorage("prShowsMergedReviews") private var showsReviewedMerged = false

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
        return PRListPage.ordered(liveRows.filter { page.holds($0) && orgFilter.shows($0) })
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
        TabStack(path: $navigation.path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.sm) {
                    if let since = model.staleSince {
                        banner("Last checked GitHub \(since.formatted(.relative(presentation: .named)))")
                    }
                    if !model.rows.isEmpty, let message = model.errorMessage {
                        banner("Not up to date. \(message)")
                    }
                    if let refused = model.refusedWrite {
                        Button { model.dismissRefusedWrite() } label: {
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
                    if showsMergedHere, let error = model.mergedError[page] {
                        banner("Merged PRs didn't load. \(error)")
                    }
                }
                .padding(.bottom, Space.lg)
            }
            .animation(AppMotion.fold, value: model.rows)
            .animation(AppMotion.fold, value: model.errorMessage)
            .animation(AppMotion.fold, value: model.refusedWrite)
            .animation(AppMotion.fold, value: orgFilter)
            .animation(AppMotion.fold, value: page)
            .animation(AppMotion.fold, value: model.merged)
            .animation(AppMotion.fold, value: showsMergedHere)
            .animation(AppMotion.fold, value: model.removedRequests)
            .animation(AppMotion.fold, value: model.localAnswers)
            .background(Color.groundPage)
            .navigationTitle("PRs")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { filterButton }
            }
            .overlay {
                if model.rows.isEmpty, let message = model.errorMessage {
                    ContentUnavailableView("No PRs", systemImage: "arrow.triangle.pull", description: Text(message))
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
            .returnedToOnMac(atRoot: navigation.path.isEmpty)
            .showsPullRequests()
        }
        .opensPullRequestLinks(in: $navigation.path, backGoesToRoot: true)
        .onChange(of: navigation.pendingPullRequest, initial: true) { _, ref in
            if let ref {
                navigation.pendingPullRequest = nil
                open(ref)
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
                navigation.pendingPullRequest = ref
            }
        }
    }

    /// In the list, not the bar: it scrolls away with the first rows, so it costs no room while reading.
    private var pagePicker: some View {
        Picker("List", selection: $page) {
            Text(
                showsReviewedMerged ? "Reviewed merged · \(rows(on: .review).count)"
                    : "For review · \(rows(on: .review).filter(\.isReviewRequest).count)"
            )
            .tag(PRListPage.review)
            Text("\(showsMyMerged ? "My merged" : "My PRs") · \(rows(on: .mine).count)").tag(PRListPage.mine)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.sm)
        .accessibilityIdentifier("pr-list-page")
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
                showsMerged: showsMergedBinding
            )
                .presentationCompactAdaptation(.popover)
        }
    }

    /// The host's words for a list GitHub left empty, and its link (`PRKitConfiguration.emptyHint`).
    private func emptyHint(_ hint: PREmptyHint) -> some View {
        ContentUnavailableView {
            Label(hint.title, systemImage: "arrow.triangle.pull")
        } description: {
            Text(hint.message)
        } actions: {
            Link(hint.linkTitle, destination: hint.link)
                .buttonStyle(PRButtonStyle(.primary))
                .accessibilityIdentifier("pr-empty-hint-link")
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
        ForEach(page.entries(rows)) { entry in
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
        let block = PrListBlock(
            item: PRListItem(ticket: nil, pullRequests: [row.listPullRequest], title: nil, note: nil),
            id: row.id, sentAt: .now, now: .now, folds: folds
        ).notUpdated(model.notUpdated.contains(row.id))
        if row.isReviewRequest {
            PRSwipeRow(title: row.status?.review == "approved" ? "Approved · Remove me" : "Remove me") {
                model.removeReviewRequest(row)
            } content: {
                block
            }
        } else {
            block
        }
    }

    /// A link from a notification: there is no stack of its own to go back to, so it shows here, over nothing else.
    private func open(_ ref: PullRequestRef) {
        navigation.path = NavigationPath()
        navigation.path.append(model.session(for: ref))
    }

    private func openBenchmark() {
        if let id = launchOptions.benchmarkRow, let row = model.rows.first(where: { $0.id == id }) {
            navigation.path.append(model.session(for: row))
        }
    }
}

/// Orgs on top, then the repos in them, each with how many PRs it holds on this page. A popover and not a menu: it
/// scrolls a long list, and the repos change the moment an org does. They come from rows already on the phone, so none
/// has to load.
private struct PRFilterPanel: View {
    let orgs: [String]
    let repoCounts: [String: Int]
    @Binding var filter: PROrgFilter
    /// On My PRs only.
    var showsMerged: Binding<Bool>?

    private var repos: [String] {
        repoCounts.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
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
