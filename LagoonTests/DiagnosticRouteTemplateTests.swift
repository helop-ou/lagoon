import Foundation
import Testing
@testable import Lagoon

@Suite("Diagnostic route template")
struct DiagnosticRouteTemplateTests {
    @Test func identifiersBecomePlaceholdersAndTheBasePathGoes() {
        #expect(DiagnosticRouteTemplate.template(path: "/Users/8f3a1c2e9b4d/Items/12c4/PlaybackInfo") == "Users/{id}/Items/{id}/PlaybackInfo")
        #expect(DiagnosticRouteTemplate.template(path: "/jellyfin/Items/a1b2", basePath: "/jellyfin") == "Items/{id}")
        #expect(DiagnosticRouteTemplate.template(path: "/Videos/x1/stream.mkv") == "Videos/{id}/{id}")
        #expect(DiagnosticRouteTemplate.template(path: "/") == "{id}")
        let url = URL(string: "https://fixture.example.eu/jf/Sessions/Playing?positionTicks=5")!
        #expect(DiagnosticRouteTemplate.template(url: url, serverURL: URL(string: "https://fixture.example.eu/jf")) == "Sessions/Playing")
        #expect(DiagnosticSchema.isRoute(DiagnosticRouteTemplate.template(path: "/Users/8f3a/Items/12c4/PlaybackInfo")))
        #expect(APIDiagnostics.routeToken(.string("Users/{id}/Items/{id}/PlaybackInfo")) == "Users.id.Items.id.PlaybackInfo")
    }

    @Test func expectedNetworkConditionsAreNotIncidents() {
        #expect(DiagnosticNetworkClassifier.isExpectedTransportFailure(URLError(.notConnectedToInternet)))
        #expect(DiagnosticNetworkClassifier.isExpectedTransportFailure(URLError(.cannotConnectToHost)))
        #expect(DiagnosticNetworkClassifier.isExpectedTransportFailure(CancellationError()))
        #expect(!DiagnosticNetworkClassifier.isExpectedTransportFailure(URLError(.secureConnectionFailed)))
        #expect(!DiagnosticNetworkClassifier.isExpectedTransportFailure(URLError(.badServerResponse)))
        #expect(DiagnosticNetworkClassifier.isExpectedStatus(401))
        #expect(DiagnosticNetworkClassifier.isExpectedStatus(403))
        #expect(!DiagnosticNetworkClassifier.isExpectedStatus(500))
        #expect(!DiagnosticNetworkClassifier.isExpectedStatus(404))
    }
}
