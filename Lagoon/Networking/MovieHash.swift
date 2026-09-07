import Foundation

/// OpenSubtitles' "moviehash" (OSHash): the file size plus the little-endian
/// 64-bit word sum of the first and last 64 KiB, with unsigned wraparound.
///
/// It is the highest-precision match the provider offers — it identifies the
/// exact release rather than the title — and Lagoon can afford it because the
/// media is reachable over HTTP `Range`, so two small reads are enough. Title
/// and id searches stay as the fallback for what it cannot cover.
nonisolated enum MovieHash {
    static let chunkSize = 64 * 1_024
    /// The head and tail chunks would overlap below this, which the algorithm
    /// does not define. OpenSubtitles rejects such files outright.
    static let minimumFileSize: Int64 = 131_072
    static let maximumFileSize: Int64 = 9_000_000_000

    static func supports(fileSize: Int64) -> Bool {
        fileSize >= minimumFileSize && fileSize < maximumFileSize
    }

    /// Pure form, so the arithmetic is pinned without any I/O. Both chunks
    /// must be a whole 64 KiB; a short read means the range request was
    /// truncated and the hash would silently be wrong.
    static func value(fileSize: Int64, head: Data, tail: Data) -> String? {
        guard supports(fileSize: fileSize),
              head.count == chunkSize,
              tail.count == chunkSize else { return nil }
        var hash = UInt64(fileSize)
        hash = hash &+ sum(head)
        hash = hash &+ sum(tail)
        // Leading zeros are significant: the provider matches on the padded
        // 16-character form.
        return String(format: "%016llx", hash)
    }

    private static func sum(_ data: Data) -> UInt64 {
        var total: UInt64 = 0
        data.withUnsafeBytes { raw in
            let words = raw.count / 8
            for index in 0..<words {
                total = total &+ UInt64(
                    littleEndian: raw.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self)
                )
            }
        }
        return total
    }
}

/// Reads the two chunks `MovieHash` needs straight from the streaming URL.
/// Jellyfin serves direct-play files over ranged HTTP, which is the same
/// capability the playback cache already relies on.
nonisolated struct MovieHashReader: Sendable {
    private let downloads: BoundedDownload
    private let timeout: TimeInterval

    init(session: URLSession = .shared, timeout: TimeInterval = 15) {
        downloads = BoundedDownload(configuration: session.configuration)
        self.timeout = timeout
    }

    func hash(of url: URL, fileSize: Int64) async -> String? {
        guard MovieHash.supports(fileSize: fileSize) else { return nil }
        let tailStart = fileSize - Int64(MovieHash.chunkSize)
        async let head = chunk(of: url, from: 0)
        async let tail = chunk(of: url, from: tailStart)
        guard let head = await head, let tail = await tail else { return nil }
        return MovieHash.value(fileSize: fileSize, head: head, tail: tail)
    }

    /// A hash is an optimisation, never a requirement: any failure returns
    /// nil so the search falls back to identifiers instead of erroring.
    private func chunk(of url: URL, from offset: Int64) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(
            "bytes=\(offset)-\(offset + Int64(MovieHash.chunkSize) - 1)",
            forHTTPHeaderField: "Range"
        )
        // Reject a server ignoring Range before it can send an entire movie.
        guard let data = try? await downloads.data(for: request, limit: MovieHash.chunkSize,
                                                  content: .bytes, statusCodes: [206]),
              data.count == MovieHash.chunkSize else { return nil }
        return data
    }
}
