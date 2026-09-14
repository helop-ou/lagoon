import Foundation

/// One message off Jellyfin's WebSocket, with its payload kept as JSON so
/// the caller decodes whatever shape that message type carries (HEL-172).
///
/// The envelope is `{"MessageType": …, "MessageId": …, "Data": …}` and
/// `Data` is anything: an object for `SyncPlayGroupUpdate`, a bare integer
/// for `ForceKeepAlive`, a bare string for `GroupLeft`, or absent.
nonisolated struct ServerSocketMessage: Equatable, Sendable {
    let messageType: String
    /// Absent on every SyncPlay message observed on fixture 12.0.0, so this
    /// stays optional rather than defaulting to something invented.
    let messageId: String?
    /// The `Data` subtree, re-serialised, or nil when there was none.
    let payload: Data?

    /// Decodes the payload with the Jellyfin decoder, so PascalCase keys
    /// land on camelCase properties exactly as they do over HTTP.
    func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        guard let payload else { throw JellyfinError.server(status: 0, message: "No socket payload") }
        return try JellyfinClient.decoder.decode(type, from: payload)
    }
}

/// Splits the envelope from its payload without knowing any message type.
///
/// Pure, and separate from the socket, because this is the part that has to
/// survive a server sending something new: an unknown `MessageType` parses
/// like any other and is ignored by the caller, and only genuinely malformed
/// JSON returns nil. `JSONSerialization` rather than `Codable` because
/// `Data` has no fixed type — re-serialising the subtree is what lets the
/// caller decode it as the concrete DTO it turns out to be.
nonisolated enum ServerSocketEnvelope {
    static func parse(_ data: Data) -> ServerSocketMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageType = object["MessageType"] as? String, !messageType.isEmpty else { return nil }
        var payload: Data?
        if let value = object["Data"], !(value is NSNull) {
            // `.fragmentsAllowed`: `ForceKeepAlive` carries a bare 60 and
            // `GroupLeft` a bare string, neither of which is a valid
            // top-level JSON object.
            payload = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        }
        return ServerSocketMessage(
            messageType: messageType,
            messageId: object["MessageId"] as? String,
            payload: payload
        )
    }
}

/// How long to wait before the next reconnection attempt.
///
/// Pure so the schedule is pinned by tests rather than by pulling a network
/// cable. Doubling to a 30 s ceiling, with jitter so a server coming back up
/// is not met by every client in the house at the same instant.
nonisolated enum ServerSocketBackoff {
    static let delays: [Double] = [1, 2, 4, 8, 16, 30]
    static let jitterFraction = 0.2

    /// The schedule without jitter. Attempt 0 is the first retry.
    static func base(attempt: Int) -> Double {
        guard attempt > 0 else { return delays[0] }
        return delays[min(attempt, delays.count - 1)]
    }

    /// `jitter` is a fraction of the base delay, in −0.2…0.2.
    static func delay(attempt: Int, jitter: Double) -> Double {
        let bounded = min(max(jitter, -jitterFraction), jitterFraction)
        return base(attempt: attempt) * (1 + bounded)
    }

    static func randomDelay(attempt: Int) -> Double {
        delay(attempt: attempt, jitter: .random(in: -jitterFraction...jitterFraction))
    }
}

/// Builds the WebSocket URL from the configured server URL.
///
/// Same base-path rules as every other route, so it goes through
/// `serverRelativeURL("socket")` and only the scheme changes here. The token
/// rides in the query, which is the one first-party URL that still carries
/// it: Jellyfin's socket handshake authenticates from `api_key`, and a
/// WebSocket upgrade is not a request Lagoon's `Authorization` header was
/// verified to reach. Verified against fixture 12.0.0.
nonisolated enum ServerSocketURL {
    static func socket(from httpURL: URL, token: String, deviceId: String) -> URL? {
        guard var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: return nil
        }
        components.queryItems = [
            URLQueryItem(name: "api_key", value: token),
            URLQueryItem(name: "deviceId", value: deviceId)
        ]
        return components.url
    }
}

/// Jellyfin's server-to-client WebSocket: the only way a SyncPlay group's
/// commands reach a client (HEL-172).
///
/// Main-actor owned, by the project's default isolation. Built from a
/// snapshot of the client's URL, token and device id — the same rule
/// `sessionSnapshot()` follows — so a socket that outlives an account
/// change fails and reconnects as the account it was opened for, instead of
/// silently adopting the new one.
///
/// Keep-alive is handled here and never forwarded: the server sends
/// `ForceKeepAlive` with a timeout in seconds, expects a `KeepAlive` reply
/// at once and then one every half-timeout, and echoes a bare `KeepAlive`
/// back at us, which is not a message anything upstream wants to see.
///
/// Nothing tears this down on deinit: a `URLSessionWebSocketTask` outlives
/// its owner happily. Whoever calls `connect()` owns calling `disconnect()`.
final class ServerSocket {
    nonisolated enum State: Equatable, Sendable {
        case idle
        case connecting
        case open
        case waitingToReconnect
    }

    private(set) var state: State = .idle

    /// Every message except keep-alive traffic, in arrival order. One
    /// consumer: the stream is created once and survives
    /// disconnect/reconnect, so a consumer's `for await` keeps working
    /// across a drop.
    let messages: AsyncStream<ServerSocketMessage>

    private let continuation: AsyncStream<ServerSocketMessage>.Continuation
    private let url: URL?
    private let session: URLSession
    private var connectionTask: Task<Void, Never>?
    private var socketTask: URLSessionWebSocketTask?
    private var keepAliveTask: Task<Void, Never>?

    init(client: JellyfinClient) {
        let stream = AsyncStream.makeStream(of: ServerSocketMessage.self)
        messages = stream.stream
        continuation = stream.continuation
        if let base = client.serverRelativeURL("socket"), let token = client.accessToken {
            url = ServerSocketURL.socket(from: base, token: token, deviceId: client.deviceId)
        } else {
            url = nil
        }
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func connect() {
        guard url != nil, connectionTask == nil else { return }
        connectionTask = Task { [weak self] in await self?.run() }
    }

    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        stopKeepAlive()
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        state = .idle
    }

    // MARK: - Connection

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            state = .connecting
            let opened = await receiveUntilFailure()
            stopKeepAlive()
            if Task.isCancelled { break }
            // A connection that opened and then dropped starts the schedule
            // over: it is a different failure from never having reached the
            // server at all.
            if opened { attempt = 0 }
            state = .waitingToReconnect
            let delay = ServerSocketBackoff.randomDelay(attempt: attempt)
            attempt += 1
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                break
            }
        }
        state = .idle
    }

    /// Runs one connection to completion. Returns whether it ever carried a
    /// message, which is what counts as having opened: the handshake alone
    /// can succeed against a proxy that then answers nothing.
    private func receiveUntilFailure() async -> Bool {
        guard let url else { return false }
        let task = session.webSocketTask(with: url)
        socketTask = task
        task.resume()
        var opened = false
        while !Task.isCancelled {
            guard let message = try? await task.receive() else { break }
            if !opened {
                opened = true
                state = .open
            }
            handle(message)
        }
        task.cancel(with: .goingAway, reason: nil)
        if socketTask === task { socketTask = nil }
        return opened
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: return
        }
        guard let parsed = ServerSocketEnvelope.parse(data) else { return }
        switch parsed.messageType {
        case "ForceKeepAlive":
            startKeepAlive(timeout: (try? parsed.decodePayload(Int.self)) ?? Self.defaultKeepAliveTimeout)
        case "KeepAlive":
            // Our own reply, echoed back.
            break
        default:
            continuation.yield(parsed)
        }
    }

    // MARK: - Keep-alive

    private static let defaultKeepAliveTimeout = 60
    private static let keepAliveBody = #"{"MessageType":"KeepAlive"}"#

    private func startKeepAlive(timeout: Int) {
        stopKeepAlive()
        sendKeepAlive()
        // Half the timeout, as the server asks, and never less than a
        // second in case a server ever sends a nonsense timeout.
        let interval = Duration.seconds(max(Double(timeout) / 2, 1))
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                self?.sendKeepAlive()
            }
        }
    }

    private func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    private func sendKeepAlive() {
        socketTask?.send(.string(Self.keepAliveBody)) { _ in
            // A failed send is a dead connection; the receive loop is
            // already about to say so and start the backoff.
        }
    }
}
