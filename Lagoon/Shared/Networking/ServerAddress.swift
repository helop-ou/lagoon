import Foundation
import Network

/// Parses user-entered server roots, keeping any proxy path. Only
/// schemeless input tries other schemes and default ports.
nonisolated enum ServerAddress {
    enum Service { case jellyfin, seerr }

    enum Failure: LocalizedError {
        case invalid

        var errorDescription: String? {
            "Enter a hostname or an HTTP or HTTPS address, with an optional port and base path. Leave out usernames, passwords, query parameters, and fragments."
        }
    }

    static func candidateURLs(for input: String, service: Service) -> [URL] {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.hasPrefix("/"),
              address.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !address.contains("\\"), hasValidPercentEscapes(address) else { return [] }

        let explicitScheme = address.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil
        let inputURL = explicitScheme ? address : "https://" + address
        guard var components = URLComponents(string: inputURL),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, validHost(host),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else { return [] }
        // Foundation reads "host:" as no port; treat it as incomplete.
        let authority = inputURL[inputURL.range(of: "://")!.upperBound...]
            .prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.hasSuffix(":") else { return [] }

        components.scheme = scheme
        normalizePath(&components, removingAPISuffix: service == .seerr)
        if explicitScheme { return components.url.map { [$0] } ?? [] }

        let literalHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let looksLocal = host.lowercased().hasSuffix(".local")
            || IPv4Address(literalHost) != nil || IPv6Address(literalHost) != nil
        var candidates: [URL] = []
        func append(_ scheme: String, defaultPort: Bool = false) {
            var candidate = components
            candidate.scheme = scheme
            if defaultPort { candidate.port = service == .jellyfin ? 8096 : 5055 }
            if let url = candidate.url, !candidates.contains(url) { candidates.append(url) }
        }
        if looksLocal {
            append("http")
            if service == .jellyfin, components.port == nil { append("http", defaultPort: true) }
            append("https")
        } else {
            append("https")
            append("http")
        }
        if components.port == nil, !looksLocal || service == .seerr { append("http", defaultPort: true) }
        return candidates
    }

    /// A saved URL is already a root. Never strip an API suffix again: a
    /// proxy root can itself end in /api/v1.
    static func normalizedRootURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        normalizePath(&components, removingAPISuffix: false)
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    static func displayString(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        // Old saved addresses may hold credentials or tokens; never show them.
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? ""
    }

    private static func normalizePath(_ components: inout URLComponents, removingAPISuffix: Bool) {
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if removingAPISuffix, path.hasSuffix("/api/v1") {
            path.removeLast("/api/v1".count)
            while path.hasSuffix("/") { path.removeLast() }
        }
        components.percentEncodedPath = path
    }

    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            return IPv6Address(String(host.dropFirst().dropLast())) != nil
        }
        // Host names must not decode into URL delimiters. IPv6 needs brackets.
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
            .union(CharacterSet(charactersIn: "/\\:@?#[]%"))
        guard host.rangeOfCharacter(from: forbidden) == nil else { return false }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return IPv4Address(host) != nil }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        return !name.split(separator: ".", omittingEmptySubsequences: false).contains(where: { $0.isEmpty })
    }

    private static func hasValidPercentEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func isHex(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
        for index in bytes.indices where bytes[index] == 37 {
            guard index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) else { return false }
        }
        return true
    }
}
