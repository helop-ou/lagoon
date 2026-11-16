import Foundation

nonisolated extension KeyedDecodingContainer {
    /// Reads one field of a record saved on the device. A key the record
    /// lacks, or a value this build cannot read, leaves `record` as it was,
    /// so a build that adds a field keeps what an older one saved.
    func read<Record, Value: Decodable>(
        _ key: Key, into record: inout Record, at field: WritableKeyPath<Record, Value>
    ) {
        if let value = try? decodeIfPresent(Value.self, forKey: key) {
            record[keyPath: field] = value
        }
    }
}
