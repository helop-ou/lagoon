import Foundation

/// A readable sentence from an error body, shared by the Jellyfin and Seerr
/// clients: problem-details JSON or plain text. HTML pages are ignored.
nonisolated enum ServerErrorMessage {
    static func from(_ data: Data) -> String? {
        guard !data.isEmpty, data.count < 64 * 1_024 else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["detail", "title", "message", "Message", "error"] {
                if let value = object[key] as? String {
                    return condensed(value)
                }
            }
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else { return nil }
        return condensed(text)
    }

    private static func condensed(_ value: String) -> String? {
        let clean = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return clean.count > 180 ? String(clean.prefix(180)) + "…" : clean
    }
}
