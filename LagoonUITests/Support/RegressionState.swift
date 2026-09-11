import Foundation

/// Values from the launch-gated playback and lifecycle accessibility probes.
struct RegressionState {
    let raw: String
    private let values: [String: String]

    init(_ raw: String) {
        self.raw = raw
        values = Dictionary(uniqueKeysWithValues: raw.split(separator: " ").compactMap { token in
            let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
            return pair.count == 2 ? (pair[0], pair[1]) : nil
        })
    }

    func string(_ key: String) -> String { values[key] ?? "" }
    func int(_ key: String) -> Int { Int(values[key] ?? "") ?? -1 }
    func double(_ key: String) -> Double { Double(values[key] ?? "") ?? -1 }
}
