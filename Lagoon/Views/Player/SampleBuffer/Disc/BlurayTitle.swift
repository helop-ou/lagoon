import Foundation

/// One playlist from `BDMV/PLAYLIST`, in the only terms title selection
/// needs: what it plays, in what order, and for how long.
nonisolated struct BlurayPlaylist: Equatable {
    struct Item: Equatable {
        /// The five-digit clip name, without its extension.
        let clip: String
        let seconds: Double
    }

    let name: String
    let items: [Item]

    var seconds: Double {
        items.reduce(0) { $0 + $1.seconds }
    }

    /// Duration with each clip counted once.
    ///
    /// A menu loop is a playlist that plays the same clip a few hundred
    /// times: WALL·E's `00020.mpls` reports 323 minutes from two distinct
    /// clips, more film than the image physically holds. Collapsing repeats
    /// drops it to 2 minutes and leaves the real titles at the top.
    var collapsedSeconds: Double {
        guard !items.isEmpty else { return 0 }
        let unique = Set(items.map(\.clip)).count
        return seconds * Double(unique) / Double(items.count)
    }
}

/// Blu-ray playlists are big-endian, unlike the little-endian filesystem
/// underneath them.
nonisolated enum BlurayPlaylistParser {
    private static let maxItems = 4_096
    /// Presentation timestamps in a playlist are 45 kHz ticks.
    private static let ticksPerSecond = 45_000.0

    static func parse(_ data: Data, name: String) throws -> BlurayPlaylist {
        let bytes = DiscBytes(data)
        guard try bytes.bytes(0, 4) == Data("MPLS".utf8) else {
            throw DiscImageError.malformed("\(name) is not a playlist")
        }
        let start = Int(try be32(bytes, 8))
        let count = Int(try be16(bytes, start + 6))
        guard count > 0, count <= maxItems else {
            throw DiscImageError.malformed("\(name) declares \(count) play items")
        }

        var items: [BlurayPlaylist.Item] = []
        items.reserveCapacity(count)
        var offset = start + 10
        for _ in 0..<count {
            let length = Int(try be16(bytes, offset))
            guard length > 0 else {
                throw DiscImageError.malformed("\(name) has an empty play item")
            }
            let body = offset + 2
            let clip = String(decoding: try bytes.bytes(body, 5), as: UTF8.self)
            let inTime = try be32(bytes, body + 12)
            let outTime = try be32(bytes, body + 16)
            let ticks = Double(outTime) - Double(inTime)
            items.append(BlurayPlaylist.Item(
                clip: clip,
                seconds: max(ticks, 0) / ticksPerSecond
            ))
            offset = body + length
        }
        return BlurayPlaylist(name: name, items: items)
    }

    private static func be16(_ bytes: DiscBytes, _ offset: Int) throws -> UInt16 {
        (UInt16(try bytes.u8(offset)) << 8) | UInt16(try bytes.u8(offset + 1))
    }

    private static func be32(_ bytes: DiscBytes, _ offset: Int) throws -> UInt32 {
        var value: UInt32 = 0
        for byte in 0..<4 {
            value = (value << 8) | UInt32(try bytes.u8(offset + byte))
        }
        return value
    }
}

nonisolated enum BlurayTitlePolicy {
    /// Which playlist is the film.
    ///
    /// The server has already probed this disc and reported a runtime, which
    /// is a better signal than any heuristic a client can invent: WALL·E's
    /// disc offers four plausible titles between 98.2 and 98.7 minutes, and
    /// Jellyfin's 98.11 picks the right one. Without that hint the longest
    /// title wins, loops collapsed.
    ///
    /// Ties resolve by name so the choice is deterministic across mounts —
    /// `00004.mpls` and `00800.mpls` are the same film on this disc, and
    /// which one plays should not depend on directory order.
    static func mainTitle(
        from playlists: [BlurayPlaylist],
        runtimeSeconds: Double?
    ) -> BlurayPlaylist? {
        let candidates = playlists.filter { !$0.items.isEmpty }.sorted { $0.name < $1.name }
        guard !candidates.isEmpty else { return nil }
        if let runtimeSeconds, runtimeSeconds > 0 {
            return candidates.min { left, right in
                abs(left.collapsedSeconds - runtimeSeconds) < abs(right.collapsedSeconds - runtimeSeconds)
            }
        }
        return candidates.max { $0.collapsedSeconds < $1.collapsedSeconds }
    }
}

/// Turns a mounted image into the stream the demuxer reads.
nonisolated enum BlurayDisc {
    private static let playlistDirectory = "BDMV/PLAYLIST"
    private static let streamDirectory = "BDMV/STREAM"
    private static let maxPlaylists = 512
    private static let maxPlaylistBytes = 1 * 1_024 * 1_024

    /// True when the image carries a Blu-ray structure at all, which is what
    /// separates a disc this reader can play from one it must decline.
    static func isBluray(_ volume: UDFVolume) -> Bool {
        ((try? volume.entry(at: playlistDirectory)) ?? nil) != nil
    }

    static func mainTitle(
        in volume: UDFVolume,
        runtimeSeconds: Double?
    ) throws -> (playlist: BlurayPlaylist?, stream: DiscStreamMap) {
        guard let playlistEntry = try volume.entry(at: playlistDirectory),
              let streamEntry = try volume.entry(at: streamDirectory) else {
            throw DiscImageError.notUDF
        }

        var clips: [String: UDFVolume.Entry] = [:]
        for entry in try volume.list(streamEntry.icb) where !entry.isDirectory {
            clips[entry.name.uppercased()] = entry
        }
        guard !clips.isEmpty else { throw DiscImageError.noTitle }

        var playlists: [BlurayPlaylist] = []
        for entry in try volume.list(playlistEntry.icb)
        where entry.name.uppercased().hasSuffix(".MPLS") && playlists.count < maxPlaylists {
            let data = try volume.data(of: entry.icb, limit: maxPlaylistBytes)
            // One unreadable playlist among sixty-five is not a broken disc.
            guard let playlist = try? BlurayPlaylistParser.parse(data, name: entry.name) else {
                continue
            }
            playlists.append(playlist)
        }

        guard let title = BlurayTitlePolicy.mainTitle(from: playlists, runtimeSeconds: runtimeSeconds) else {
            // No playlist parsed. The largest stream is a poor title but a
            // better outcome than refusing the disc.
            return (nil, try largestClipStream(in: volume, clips: clips))
        }

        var extents: [DiscExtent] = []
        for item in title.items {
            guard let entry = clips["\(item.clip).M2TS"] else { continue }
            guard case .extents(let clipExtents) = try volume.contents(of: entry.icb) else { continue }
            extents.append(contentsOf: clipExtents)
        }
        guard !extents.isEmpty else { throw DiscImageError.noTitle }
        return (title, DiscStreamMap(extents: extents))
    }

    private static func largestClipStream(
        in volume: UDFVolume,
        clips: [String: UDFVolume.Entry]
    ) throws -> DiscStreamMap {
        var best: (size: Int64, extents: [DiscExtent])?
        for entry in clips.values where entry.name.uppercased().hasSuffix(".M2TS") {
            guard case .extents(let extents) = try volume.contents(of: entry.icb) else { continue }
            let size = extents.reduce(0) { $0 + $1.length }
            if size > (best?.size ?? 0) {
                best = (size, extents)
            }
        }
        guard let best, !best.extents.isEmpty else { throw DiscImageError.noTitle }
        return DiscStreamMap(extents: best.extents)
    }
}
