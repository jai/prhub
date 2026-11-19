import DurableNetworking
import Foundation
@testable import PRKit
@testable import PRKitCore
import PRKitTestSupport
import Testing

/// The merged lists keep their last good answer: it shows at once on the next launch and stays when a read fails. The
/// next launch is a second model over the first one's storage.
@MainActor
struct PRMergedKeptTests {
    private let storage = PRKitStorage.inMemory()

    private let row = PullRequestRow(
        repo: "acme/web", number: 7, title: "Merged one", head: "h", revision: "r", diff: .ready, detail: "d",
        status: nil
    )

    /// `rows` on the merged lists.
    private func client(offline: Bool, rows: [PullRequestRow] = []) -> PRViewerClient {
        let access = PRViewerAccess(baseURL: { URL(string: "https://worker.test")! }, bearer: { "t" }, discard: {})
        return PRViewerClient(access: access) { request in
            if offline {
                throw URLError(.notConnectedToInternet)
            }
            let listed = request.url!.path().hasSuffix("/prs/merged") ? rows : []
            let body = try JSONSerialization.data(withJSONObject: [
                "prs": JSONSerialization.jsonObject(with: JSONEncoder().encode(listed)), "synced_at": 0,
            ])
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func aMergedListReadOnlineShowsOfflineAfterARelaunch() async {
        let online = PRsModel(client: client(offline: false, rows: [row]), storage: storage, network: PRNetwork(isOnline: true))
        await online.loadMerged(on: .mine)
        #expect(online.merged[.mine]?.map(\.id) == [row.id])

        let relaunched = PRsModel(client: client(offline: true), storage: storage, network: PRNetwork(isOnline: true))
        await relaunched.loadMerged(on: .mine)
        #expect(relaunched.merged[.mine]?.map(\.id) == [row.id], "the kept list, not nothing")
        #expect(relaunched.mergedError[.mine] != nil, "and it says the read failed")
    }

    @Test func offlineWithNothingKeptShowsNoList() async {
        let model = PRsModel(client: client(offline: true), storage: storage, network: PRNetwork(isOnline: true))
        await model.loadMerged(on: .mine)
        #expect(model.merged[.mine] == nil)
        #expect(model.mergedError[.mine] != nil)
    }
}
