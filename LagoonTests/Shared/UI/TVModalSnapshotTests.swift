#if os(tvOS)
import SwiftUI
import Testing
@testable import Lagoon

/// Every tvOS modal panel. A sheet toolbar once squeezed Cancel into "C…el",
/// so tvOS modals keep their actions in the panel. The window is never key,
/// so focus is not drawn here.
@Suite("tvOS modal snapshots", .serialized)
@MainActor
struct TVModalSnapshotTests {
    private static let defaults = UserDefaults(suiteName: "tv-modal-snapshot-tests")!

    private static let seerr = SeerrSessionStore(
        defaults: defaults,
        localData: AccountLocalData(defaults: defaults, credentials: MemoryAccountCredentials())
    )

    private let session: SessionStore = {
        let session = SessionStore(
            defaults: defaults, credentials: MemoryAccountCredentials(), stores: .isolated(defaults: defaults)
        )
        session.client.configure(serverURL: URL(string: "https://jellyfin.snapshot.test")!)
        session.client.activateSession(token: "token", userId: "user")
        return session
    }()

    @Test func thePanelPutsTitleContentAndActionsInSequence() async throws {
        let panel = TVModalPanel(
            title: Text("Panel Title"),
            subtitle: "A subtitle long enough to wrap onto a second line, the way the Watch Together explainer does.",
            doneTitle: "Cancel"
        ) {
            Button("Confirm") {}
                .buttonStyle(.glass)
        } content: {
            VStack(spacing: Metrics.Space.m) {
                ForEach(1...6, id: \.self) { row in
                    Button {} label: {
                        Text("Row \(row)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        try await Snapshot.verify(panel, named: "modal-panel", size: Metrics.modalPanelSize)
    }

    @Test func theSeasonPickerShowsCancelAndTheRequestInFull() async throws {
        let details = try JSONDecoder().decode(
            SeerrMediaDetails.self,
            from: Data(
                #"""
                {"id":81723,"name":"The Gilded Age",
                 "seasons":[{"id":1,"seasonNumber":1,"episodeCount":9},
                            {"id":2,"seasonNumber":2,"episodeCount":8},
                            {"id":3,"seasonNumber":3,"episodeCount":8}],
                 "mediaInfo":{"status":4,"seasons":[{"id":10,"seasonNumber":1,"status":5}]}}
                """#.utf8
            )
        )
        try await Snapshot.verify(
            SeerrSeasonRequestView(details: details).environment(Self.seerr),
            named: "season-request",
            size: Metrics.modalPanelSize
        )
    }

    @Test func acknowledgementsListEveryComponent() async throws {
        try await Snapshot.verify(AcknowledgementsView(), named: "acknowledgements", size: Metrics.modalPanelSize)
    }

    @Test func watchTogetherListsTheServersGroups() async throws {
        let host = "syncplay.modal.snapshot.test"
        StubURLProtocol.register(host: host) { request in
            if request.url?.path.hasSuffix("/Users/Me") == true {
                return (200, [:], Data(#"{"Id":"user","Name":"Viewer","Policy":{"SyncPlayAccess":"JoinGroups"}}"#.utf8))
            }
            return (200, [:], Data(
                #"[{"GroupId":"g1","GroupName":"Friday Film","State":"Paused","Participants":["Ana","Ben"],"LastUpdatedAt":"2026-11-03T00:00:00Z"}]"#.utf8
            ))
        }
        let syncPlay = SyncPlayStore()
        syncPlay.configure(client: StubURLProtocol.makeJellyfinClient(host: host, deviceId: "snapshot-tests"), accountID: "account")
        await syncPlay.refreshAvailability()
        try #require(syncPlay.availability.canJoinGroups)
        try #require(await syncPlay.refreshGroups().count == 1)
        let item = try JellyfinClient.decoder.decode(MediaItem.self, from: Data(#"{"Id":"arrival","Name":"Arrival","Type":"Movie"}"#.utf8))

        try await Snapshot.verify(
            WatchTogetherSheet(item: item, startPositionTicks: 0)
                .environment(session)
                .environment(syncPlay),
            named: "watch-together",
            size: Metrics.modalPanelSize
        )
    }
}
#endif
