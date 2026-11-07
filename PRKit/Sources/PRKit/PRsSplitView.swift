#if os(iOS)
import PRKitCore
import PRKitDesign
import SwiftUI

/// The PRs tab where the screen is wide (an iPad's regular width): the list in its column, the PR picked beside it, and
/// what that PR opens stacked over it. A diff takes the list's room, so the code has the whole width; Back from it brings
/// the list back.
struct PRsSplitView: View {
    let model: PRsModel
    @Bindable var navigation: PRNavigation
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            PRsList(model: model, selected: navigation.selected?.ref)
                // The app's readable width is the window's; this column is narrower than it.
                .contentMargins(.horizontal, 0, for: .scrollContent)
                .opensPullRequestLinks(on: .replacing($navigation.routes))
        } detail: {
            NavigationStack(path: $navigation.detailRoutes) {
                Group {
                    if let session = navigation.selected {
                        PRScreen(session: session)
                    } else {
                        ContentUnavailableView(
                            "No PR open", systemImage: AppIcon.openPullRequest.symbol,
                            description: Text("Pick one from the list.")
                        )
                    }
                }
                .showsPullRequests()
            }
            .readableContentWidth()
            .opensPullRequestLinks(on: .routes($navigation.routes))
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: navigation.showsDiff, initial: true) { _, showsDiff in
            withAnimation(AppMotion.fold) { columns = showsDiff ? .detailOnly : .all }
        }
    }
}
#endif
