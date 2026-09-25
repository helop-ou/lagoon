import Foundation

/// How the profile picker groups and orders profiles: one group per server,
/// in the order the servers were first added, most recently used profile
/// first within each. Pure, so the order is testable.
nonisolated enum ProfileGrouping {
    struct ServerGroup: Identifiable, Equatable {
        let serverURL: URL
        /// The name the server reports, or its address when none was stored.
        let name: String
        let address: String
        let accounts: [StoredAccount]

        var id: URL { serverURL }
    }

    static func groups(_ accounts: [StoredAccount]) -> [ServerGroup] {
        var order: [URL] = []
        var members: [URL: [(offset: Int, account: StoredAccount)]] = [:]
        for (offset, account) in accounts.enumerated() {
            if members[account.serverURL] == nil { order.append(account.serverURL) }
            members[account.serverURL, default: []].append((offset, account))
        }
        return order.map { url in
            let entries = members[url] ?? []
            let sorted = entries.sorted { lhs, rhs in
                switch (lhs.account.lastUsedAt, rhs.account.lastUsedAt) {
                case let (l?, r?) where l != r: l > r
                case (_?, nil): true
                case (nil, _?): false
                default: lhs.offset < rhs.offset
                }
            }.map(\.account)
            let address = address(of: url)
            let name = entries.lazy.compactMap(\.account.serverName).first { !$0.isEmpty } ?? address
            return ServerGroup(serverURL: url, name: name, address: address, accounts: sorted)
        }
    }

    /// Host, a non-default port and any base path: what tells two servers
    /// with the same default name apart. No scheme.
    static func address(of url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        var address = host
        if let port = url.port, port != defaultPort(for: url.scheme) {
            address += ":\(port)"
        }
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty { address += "/\(path)" }
        return address
    }

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "https": 443
        case "http": 80
        default: nil
        }
    }
}
