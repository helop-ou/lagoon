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

    /// Seerr mounts every route under `api/v1`, and a version segment that
    /// blanked to `{id}` made `search`, `request` and `movie/{id}` all read
    /// `api/{id}/…` on the dashboard (HEL-180).
    @Test func versionSegmentsSurviveSoSeerrRoutesStayDistinct() {
        #expect(DiagnosticRouteTemplate.template(path: "/api/v1/search") == "api/v1/search")
        #expect(DiagnosticRouteTemplate.template(path: "/api/v1/movie/603") == "api/v1/movie/{id}")
        #expect(DiagnosticRouteTemplate.template(path: "/api/v2/request/41") == "api/v2/request/{id}")
        #expect(APIDiagnostics.routeToken(.string("api/v1/search")) == "api.v1.search")
    }

    /// The exception is only ever `v` and digits. Everything that could name
    /// the viewer or what they are watching still blanks, and the schema has
    /// to agree with the template or the route field is dropped on the way out.
    @Test func onlyVersionSegmentsSurviveAndTheSchemaAgrees() {
        #expect(!DiagnosticRouteTemplate.isVersionSegment("v"))
        #expect(!DiagnosticRouteTemplate.isVersionSegment("v1beta"))
        #expect(!DiagnosticRouteTemplate.isVersionSegment("version1"))
        #expect(!DiagnosticRouteTemplate.isVersionSegment("V1"))
        #expect(!DiagnosticRouteTemplate.isVersionSegment("603"))
        #expect(DiagnosticRouteTemplate.isVersionSegment("v1"))
        #expect(DiagnosticRouteTemplate.isVersionSegment("v10"))

        // A media id that merely starts with a v is still an id.
        #expect(DiagnosticRouteTemplate.template(path: "/Items/v1a2b3c4/Similar") == "Items/{id}/Similar")
        #expect(DiagnosticSchema.isRoute(DiagnosticRouteTemplate.template(path: "/api/v1/movie/603")))
        #expect(DiagnosticSchema.isRoute("api/v1/search"))
        #expect(!DiagnosticSchema.isRoute("api/603/search"))
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
