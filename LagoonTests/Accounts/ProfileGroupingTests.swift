import Foundation
import Testing
@testable import Lagoon

@Suite("Profile picker grouping")
struct ProfileGroupingTests {
    private let jaflix = URL(string: "https://jaflix.jaagop.eu")!
    private let demo = URL(string: "https://demo.jellyfin.org/stable")!

    private func account(_ server: URL, _ user: String, serverName: String? = nil, lastUsedAt: TimeInterval? = nil) -> StoredAccount {
        StoredAccount(serverURL: server, serverName: serverName, userId: user, userName: user, lastUsedAt: lastUsedAt)
    }

    @Test func serversKeepTheOrderTheyWereFirstAdded() {
        let groups = ProfileGrouping.groups([
            account(demo, "demo"),
            account(jaflix, "dev"),
            account(demo, "guest"),
        ])
        #expect(groups.map(\.serverURL) == [demo, jaflix])
        #expect(groups[0].accounts.map(\.userId) == ["demo", "guest"])
    }

    @Test func theMostRecentlyUsedProfileComesFirstAndNeverUsedOnesKeepTheirOrder() {
        let groups = ProfileGrouping.groups([
            account(jaflix, "never-a"),
            account(jaflix, "older", lastUsedAt: 100),
            account(jaflix, "never-b"),
            account(jaflix, "newest", lastUsedAt: 200),
        ])
        #expect(groups.single?.accounts.map(\.userId) == ["newest", "older", "never-a", "never-b"])
    }

    @Test func theNameIsTheFirstOneStoredAndFallsBackToTheAddress() {
        let groups = ProfileGrouping.groups([
            account(jaflix, "a", serverName: ""),
            account(jaflix, "b", serverName: "Jaflix"),
            account(demo, "demo"),
        ])
        #expect(groups.map(\.name) == ["Jaflix", "demo.jellyfin.org/stable"])
    }

    @Test(arguments: [
        ("https://jaflix.jaagop.eu", "jaflix.jaagop.eu"),
        ("https://jaflix.jaagop.eu:443/", "jaflix.jaagop.eu"),
        ("http://cabin.local:80", "cabin.local"),
        ("http://cabin.local:8096", "cabin.local:8096"),
        ("https://example.com:8920/services/jellyfin/", "example.com:8920/services/jellyfin"),
    ])
    func theAddressDropsTheSchemeAndDefaultPort(url: String, expected: String) {
        #expect(ProfileGrouping.address(of: URL(string: url)!) == expected)
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
