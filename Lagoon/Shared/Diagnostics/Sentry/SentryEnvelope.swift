import Foundation
import LagoonEngine

/// Builds Sentry envelope bytes from an incident. No SDK: every byte comes
/// from here, so nothing adds breadcrumbs, a user, a device name or a stack.
/// See https://develop.sentry.dev/sdk/data-model/envelopes/ and
/// https://develop.sentry.dev/sdk/data-model/event-payloads/.
nonisolated struct SentryEnvelope: Equatable, Sendable {
    static let sdkName = "lagoon.diagnostics"
    static let sdkVersion = "1.0.0"
    /// Fields that double as dashboard tags.
    static let tagFields: [String] = [
        "delivery", "method", "container", "videoCodec", "audioCodec", "videoRange",
        "videoPath", "audioPath", "stage", "cause", "errorDomain", "client", "route",
        "httpStatus", "degradation", "thermal", "recovery", "outcome", "track",
    ]

    let eventID: String
    let data: Data

    static func make(incident: DiagnosticIncident, context: DiagnosticContext) -> SentryEnvelope? {
        let eventID = identifier(incident.id)
        let event = eventJSONObject(incident: incident, context: context, eventID: eventID)
        let history = incident.historyJSONObject
        guard let eventData = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
              let historyData = try? JSONSerialization.data(withJSONObject: history, options: [.sortedKeys]) else {
            return nil
        }
        let header: [String: Any] = [
            "event_id": eventID,
            "sent_at": iso8601(incident.timestamp),
            "sdk": ["name": sdkName, "version": sdkVersion],
        ]
        let items: [(header: [String: Any], payload: Data)] = [
            (["type": "event", "content_type": "application/json"], eventData),
            (
                [
                    "type": "attachment",
                    "filename": "history.json",
                    "content_type": "application/json",
                    "attachment_type": "event.attachment",
                ],
                historyData
            ),
        ]
        guard let data = frame(header: header, items: items) else { return nil }
        return SentryEnvelope(eventID: eventID, data: data)
    }

    /// Grouping is by `fingerprint`; the exception block only titles the
    /// issue.
    static func eventJSONObject(
        incident: DiagnosticIncident,
        context: DiagnosticContext,
        eventID: String? = nil
    ) -> [String: Any] {
        var tags: [String: String] = [
            "build": context.build,
            "os": context.osName,
            "model": context.deviceModel,
            "simulator": context.isSimulator ? "true" : "false",
            "engine": context.engineVersion,
        ]
        for key in tagFields {
            guard let value = incident.fields[key] else { continue }
            tags[key] = tagString(value)
        }
        let extra = incident.fields.mapValues(\.jsonObject)
        let variant = incident.fingerprint.dropFirst().joined(separator: " ")
        var value = variant.isEmpty ? incident.code.rawValue : variant
        if incident.occurrences > 1 {
            value += " ×\(incident.occurrences)"
        }
        return [
            "event_id": eventID ?? identifier(incident.id),
            "timestamp": incident.timestamp.timeIntervalSince1970,
            // Not "cocoa": for that platform Sentry infers the user's IP and
            // location from the connection. "native" is left alone.
            "platform": "native",
            "level": incident.level.rawValue,
            "logger": sdkName,
            "release": context.release,
            "dist": context.build,
            "environment": context.environment,
            "fingerprint": incident.fingerprint,
            "exception": [
                "values": [[
                    "type": incident.code.rawValue,
                    "value": value,
                    "mechanism": ["type": sdkName, "handled": true],
                ]],
            ],
            "tags": tags,
            "extra": extra,
            "contexts": [
                "os": ["name": context.osName, "version": context.osVersion],
                "device": [
                    "model": context.deviceModel,
                    "family": context.osName == "tvOS" ? "Apple TV" : "iOS",
                    "simulator": context.isSimulator,
                ],
                "app": [
                    "app_identifier": context.bundleIdentifier,
                    "app_version": context.appVersion,
                    "app_build": context.build,
                ],
            ],
            "sdk": ["name": sdkName, "version": sdkVersion],
        ]
    }

    /// A JSON header line, then per item a header line with the payload
    /// length, the payload and a newline.
    static func frame(header: [String: Any], items: [(header: [String: Any], payload: Data)]) -> Data? {
        guard let headerData = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]) else {
            return nil
        }
        var data = headerData
        data.append(0x0A)
        for item in items {
            var itemHeader = item.header
            itemHeader["length"] = item.payload.count
            guard let itemHeaderData = try? JSONSerialization.data(withJSONObject: itemHeader, options: [.sortedKeys]) else {
                return nil
            }
            data.append(itemHeaderData)
            data.append(0x0A)
            data.append(item.payload)
            data.append(0x0A)
        }
        return data
    }

    static func identifier(_ id: UUID) -> String {
        id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func tagString(_ value: DiagnosticValue) -> String {
        switch value {
        case .int(let number): String(number)
        case .double(let number): String(format: "%.3g", number)
        case .bool(let flag): flag ? "true" : "false"
        case .string(let text): text
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
