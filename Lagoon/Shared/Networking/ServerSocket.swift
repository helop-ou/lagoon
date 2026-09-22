import Foundation

/// One WebSocket message. `Data` can be an object, a bare integer or string,
/// or absent, so it stays JSON for the caller to decode.
nonisolated struct ServerSocketMessage: Equatable, Sendable {
    let messageType: String
    /// Absent on SyncPlay messages in practice.
    let messageId: String?
    /// The `Data` subtree, re-serialised, or nil when there was none.
    let payload: Data?

    /// Uses the Jellyfin decoder, so casing works as over HTTP.
    func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        guard let payload else { throw JellyfinError.server(status: 0, message: "No socket payload") }
        return try JellyfinClient.decoder.decode(type, from: payload)
    }
}

/// Splits the envelope from its payload. Unknown message types parse fine;
/// only malformed JSON returns nil. `JSONSerialization` because `Data` has
/// no fixed type.
nonisolated enum ServerSocketEnvelope {
    static func parse(_ data: Data) -> ServerSocketMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageType = object["MessageType"] as? String, !messageType.isEmpty else { return nil }
        var payload: Data?
        if let value = object["Data"], !(value is NSNull) {
            // Payloads can be bare numbers or strings.
            payload = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        }
        return ServerSocketMessage(
            messageType: messageType,
            messageId: object["MessageId"] as? String,
            payload: payload
        )
    }
}

/// Reconnect delay: doubling to 30 s, with jitter so clients do not all
/// return at once.
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

/// The WebSocket URL. The only first-party URL carrying the token: the
/// handshake authenticates from `api_key`, and the header is not known to
/// reach a WebSocket upgrade.
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

/// Jellyfin's WebSocket, the only way SyncPlay commands arrive.
///
/// Snapshots the client's URL and token, so it never adopts a new account.
/// Keep-alive is handled here and never forwarded. Nothing tears it down on
/// deinit: whoever calls `connect()` owns `disconnect()`.
final class ServerSocket {
    nonisolated enum State: Equatable, Sendable {
        case idle
        case connecting
        case open
        case waitingToReconnect
    }

    private(set) var state: State = .idle

    /// Every non-keep-alive message. One consumer; survives reconnects.
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
            // A connection that opened and dropped restarts the backoff.
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

    /// Returns whether a message arrived. The handshake alone can succeed
    /// against a proxy that then answers nothing.
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
        // Half the timeout, as the server asks, and at least a second.
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
            // The receive loop notices a dead connection.
        }
    }
}
