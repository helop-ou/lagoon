import Foundation
#if canImport(UIKit)
import UIKit
#endif

nonisolated enum JellyfinError: LocalizedError {
    case notConfigured
    case invalidServerURL
    case unauthorized
    case server(status: Int)
    case unplayable

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Not connected to a server."
        case .invalidServerURL: "That doesn't look like a valid server address."
        case .unauthorized: "Wrong username or password."
        case .server(let status): "The server returned an error (\(status))."
        case .unplayable: "This item can't be played on this device."
        }
    }
}

/// Thin async HTTP client for a single Jellyfin server.
///
/// Jellyfin JSON is PascalCase on the wire; the decoder and encoder convert
/// key casing globally so model types stay camelCase with no CodingKeys.
final class JellyfinClient {
    static let clientName = "Lagoon"

    private(set) var serverURL: URL?
    private(set) var accessToken: String?
    private(set) var userId: String?
    let deviceId: String

    private let session: URLSession

    nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { keys in
            let key = keys.last!.stringValue
            return AnyCodingKey(stringLiteral: key.prefix(1).lowercased() + key.dropFirst())
        }
        return decoder
    }()

    nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .custom { keys in
            let key = keys.last!.stringValue
            return AnyCodingKey(stringLiteral: key.prefix(1).uppercased() + key.dropFirst())
        }
        return encoder
    }()

    init(
        deviceId: String,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.deviceId = deviceId
        let config = sessionConfiguration
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    // MARK: - Session state

    func configure(serverURL: URL) {
        self.serverURL = serverURL
    }

    func activateSession(token: String, userId: String) {
        accessToken = token
        self.userId = userId
    }

    func clearSession() {
        accessToken = nil
        userId = nil
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    private var deviceName: String {
        #if os(tvOS)
        "Apple TV"
        #elseif canImport(UIKit)
        UIDevice.current.model
        #else
        "Apple Device"
        #endif
    }

    var authorizationHeader: String {
        var header = #"MediaBrowser Client="\#(Self.clientName)", Device="\#(deviceName)", DeviceId="\#(deviceId)", Version="\#(appVersion)""#
        if let accessToken {
            header += #", Token="\#(accessToken)""#
        }
        return header
    }

    // MARK: - Requests

    func requireUserId() throws -> String {
        guard let userId else { throw JellyfinError.notConfigured }
        return userId
    }

    func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let serverURL else { throw JellyfinError.notConfigured }
        guard var components = URLComponents(url: serverURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw JellyfinError.invalidServerURL
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else { throw JellyfinError.invalidServerURL }
        return url
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send(request(for: url(path: path, query: query), method: "GET"))
    }

    func getData(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await data(for: request(for: url(path: path, query: query), method: "GET"))
    }

    func post<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send(request(for: url(path: path, query: query), method: "POST"))
    }

    func post<T: Decodable>(_ path: String, query: [URLQueryItem] = [], body: some Encodable) async throws -> T {
        try await send(request(for: url(path: path, query: query), method: "POST", body: Self.encoder.encode(body)))
    }

    func postVoid(_ path: String, query: [URLQueryItem] = []) async throws {
        _ = try await data(for: request(for: url(path: path, query: query), method: "POST"))
    }

    func postVoid(_ path: String, query: [URLQueryItem] = [], body: some Encodable) async throws {
        _ = try await data(for: request(for: url(path: path, query: query), method: "POST", body: Self.encoder.encode(body)))
    }

    func deleteVoid(_ path: String, query: [URLQueryItem] = []) async throws {
        _ = try await data(for: request(for: url(path: path, query: query), method: "DELETE"))
    }

    private func request(for url: URL, method: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await data(for: request)
        return try Self.decoder.decode(T.self, from: data)
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.server(status: 0) }
        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            throw JellyfinError.unauthorized
        default:
            throw JellyfinError.server(status: http.statusCode)
        }
    }

    // MARK: - Server probe (pre-auth, arbitrary URL)

    nonisolated static func fetchPublicInfo(at serverURL: URL) async throws -> PublicSystemInfo {
        var request = URLRequest(url: serverURL.appending(path: "System/Info/Public"))
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw JellyfinError.invalidServerURL
        }
        return try decoder.decode(PublicSystemInfo.self, from: data)
    }
}

// MARK: - Auth endpoints

extension JellyfinClient {
    nonisolated struct AuthenticateByNameRequest: Encodable {
        let username: String
        let pw: String
    }

    nonisolated struct QuickConnectAuthRequest: Encodable {
        let secret: String
    }

    func authenticateByName(username: String, password: String) async throws -> AuthenticationResult {
        try await post("Users/AuthenticateByName", body: AuthenticateByNameRequest(username: username, pw: password))
    }

    func quickConnectEnabled() async throws -> Bool {
        try await get("QuickConnect/Enabled")
    }

    func initiateQuickConnect() async throws -> QuickConnectResult {
        try await post("QuickConnect/Initiate")
    }

    func quickConnectState(secret: String) async throws -> QuickConnectResult {
        try await get("QuickConnect/Connect", query: [URLQueryItem(name: "secret", value: secret)])
    }

    func authenticateWithQuickConnect(secret: String) async throws -> AuthenticationResult {
        try await post("Users/AuthenticateWithQuickConnect", body: QuickConnectAuthRequest(secret: secret))
    }

    func logout() async throws {
        try await postVoid("Sessions/Logout")
    }
}
