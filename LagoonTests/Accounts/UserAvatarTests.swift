import Foundation
import Testing
@testable import Lagoon

/// The user's profile picture in the account picker and Settings.
@Suite("User avatar")
struct UserAvatarTests {
    private let server = URL(string: "https://media.test/jellyfin")!

    @Test func theRouteCarriesTheTagSizeAndQualityUnderTheBasePath() throws {
        let url = try #require(JellyfinClient.userImageURL(
            serverURL: server, userId: "93f3", tag: "73c5", maxWidth: 440
        ))
        #expect(url.path == "/jellyfin/Users/93f3/Images/Primary")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "tag", value: "73c5")))
        #expect(query.contains(URLQueryItem(name: "maxWidth", value: "440")))
        #expect(query.contains(URLQueryItem(name: "quality", value: "90")))
    }

    @Test func aUserWithoutAPictureHasNoURL() {
        #expect(JellyfinClient.userImageURL(serverURL: server, userId: "93f3", tag: nil, maxWidth: 440) == nil)
        let account = StoredAccount(serverURL: server, serverName: nil, userId: "93f3", userName: "Jaagop")
        #expect(account.avatarURL(maxWidth: 440) == nil)
    }

    @Test func anAccountBuildsItsAvatarAtItsOwnServer() throws {
        let account = StoredAccount(
            serverURL: URL(string: "https://other.test")!,
            serverName: nil, userId: "93f3", userName: "Jaagop", primaryImageTag: "73c5"
        )
        let url = try #require(account.avatarURL(maxWidth: 220))
        #expect(url.host() == "other.test")
        #expect(url.path == "/Users/93f3/Images/Primary")
    }

    @Test func accountsStoredBeforeTheTagStillDecode() throws {
        let stored = Data(#"""
        [{"serverURL":"https://media.test/jellyfin","serverName":"Fixture Server","userId":"93f3","userName":"Jaagop"}]
        """#.utf8)
        let accounts = try JSONDecoder().decode([StoredAccount].self, from: stored)
        #expect(accounts.count == 1)
        #expect(accounts[0].primaryImageTag == nil)
        #expect(accounts[0].userName == "Jaagop")
    }

    @Test func theTagRoundTripsThroughStorage() throws {
        let account = StoredAccount(serverURL: server, serverName: nil, userId: "93f3", userName: "Jaagop", primaryImageTag: "73c5")
        let decoded = try JSONDecoder().decode([StoredAccount].self, from: JSONEncoder().encode([account]))
        #expect(decoded == [account])
    }

    @Test func theSignInResultCarriesTheTag() throws {
        let result = try JellyfinClient.decoder.decode(AuthenticationResult.self, from: Data(#"""
        {"User":{"Id":"93f3","Name":"Jaagop","PrimaryImageTag":"73c5"},"AccessToken":"t","ServerId":"s"}
        """#.utf8))
        #expect(result.user.primaryImageTag == "73c5")
    }
}
