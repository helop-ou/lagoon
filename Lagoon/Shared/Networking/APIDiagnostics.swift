import Foundation

/// The one place a failed Jellyfin or Seerr request becomes a diagnostic
/// record. Both clients call in from their shared request path
/// so every route gets the same classification: expected conditions (an
/// unreachable server, a lost connection, 401/403) are recorded into the
/// history and never reported; everything else is an incident grouped by
/// client, route template and status or error code. Nothing about the
/// request but its method and route shape leaves this function.
nonisolated enum APIDiagnostics {
    static func transportFailed(
        _ error: Error,
        request: URLRequest,
        serverURL: URL?,
        client: String,
        startedAt: TimeInterval,
        hub: DiagnosticsHub = Diagnostics.shared
    ) {
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        let nsError = error as NSError
        var fields = baseFields(request: request, serverURL: serverURL, client: client, startedAt: startedAt)
        if let domain = DiagnosticSchema.token(nsError.domain) {
            fields["errorDomain"] = domain
        }
        fields["errorCode"] = .int(nsError.code)
        hub.record(.apiFailure, fields)
        guard !DiagnosticNetworkClassifier.isExpectedTransportFailure(error) else { return }
        let route = routeToken(fields["route"])
        hub.report(
            .apiRequestFailed,
            level: .warning,
            variant: [client, route, nsError.domain, String(nsError.code)],
            fields: fields
        )
    }

    static func statusFailed(
        _ status: Int,
        request: URLRequest,
        serverURL: URL?,
        client: String,
        startedAt: TimeInterval,
        hub: DiagnosticsHub = Diagnostics.shared
    ) {
        var fields = baseFields(request: request, serverURL: serverURL, client: client, startedAt: startedAt)
        fields["httpStatus"] = .int(status)
        if status == 401 {
            hub.record(.apiSessionExpired, fields)
            return
        }
        hub.record(.apiFailure, fields)
        guard !DiagnosticNetworkClassifier.isExpectedStatus(status) else { return }
        let route = routeToken(fields["route"])
        hub.report(
            .apiRequestFailed,
            level: status >= 500 ? .warning : .error,
            variant: [client, route, "status\(status)"],
            fields: fields
        )
    }

    /// A 2xx body the app could not decode: the contract drifted or a DTO
    /// is wrong. The coding key names a Jellyfin field, never a value.
    static func decodeFailed(
        _ error: Error,
        request: URLRequest,
        serverURL: URL?,
        client: String,
        hub: DiagnosticsHub = Diagnostics.shared
    ) {
        var fields = baseFields(request: request, serverURL: serverURL, client: client, startedAt: nil)
        var kind = "unknown"
        var key: String?
        if let decoding = error as? DecodingError {
            switch decoding {
            case .keyNotFound(let codingKey, _):
                kind = "keyNotFound"
                key = codingKey.stringValue
            case .typeMismatch(_, let context):
                kind = "typeMismatch"
                key = context.codingPath.last?.stringValue
            case .valueNotFound(_, let context):
                kind = "valueNotFound"
                key = context.codingPath.last?.stringValue
            case .dataCorrupted(let context):
                kind = "dataCorrupted"
                key = context.codingPath.last?.stringValue
            @unknown default:
                kind = "unknown"
            }
        }
        fields["errorDomain"] = .string("DecodingError.\(kind)")
        if let key = DiagnosticSchema.token(key) {
            fields["decodingKey"] = key
        }
        hub.record(.apiFailure, fields)
        let route = routeToken(fields["route"])
        hub.report(
            .apiDecodeFailed,
            level: .error,
            variant: [client, route, kind, key ?? ""],
            fields: fields
        )
    }

    private static func baseFields(
        request: URLRequest,
        serverURL: URL?,
        client: String,
        startedAt: TimeInterval?
    ) -> [String: DiagnosticValue] {
        var fields: [String: DiagnosticValue] = ["client": .string(client)]
        if let method = request.httpMethod, DiagnosticSchema.httpMethodChoices.contains(method) {
            fields["httpMethod"] = .string(method)
        }
        if let url = request.url {
            fields["route"] = .string(DiagnosticRouteTemplate.template(url: url, serverURL: serverURL))
        }
        if let startedAt {
            let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            fields["elapsedMs"] = .double(max(elapsed, 0).rounded())
        }
        return fields
    }

    /// The route as a fingerprint token: `Users.id.Items.id.PlaybackInfo`.
    static func routeToken(_ value: DiagnosticValue?) -> String {
        guard case .string(let route)? = value else { return "route" }
        let token = route
            .replacingOccurrences(of: "{id}", with: "id")
            .replacingOccurrences(of: "/", with: ".")
        return String(token.prefix(DiagnosticSchema.tokenMaximumLength))
    }
}
