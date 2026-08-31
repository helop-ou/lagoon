import Foundation

/// Enough read-only UDF to find a file and say where its bytes are.
///
/// Not a general filesystem: it resolves names to extents and reads small
/// files whole, which is all a disc image needs before the demuxer takes
/// over. Written rather than linked because libavformat has no UDF at all,
/// and libbluray/libudfread would be a new dependency that still could not
/// reach a disc over HTTP without the same callbacks (HEL-133).
///
/// UDF 2.50, which is what BD-ROM uses, keeps every file entry inside a
/// *metadata partition* — a file in the physical partition that the volume
/// then addresses as if it were a partition of its own. That indirection is
/// the part worth knowing about: file entries live there, while the file data
/// they describe lives in the physical partition, and a reader that misses
/// the distinction reads empty directories.
nonisolated final class UDFVolume {
    /// Where a file entry lives. `partition` is a reference into the volume's
    /// partition map, not a partition number.
    struct ICB: Equatable {
        let block: UInt32
        let partition: UInt16
        let length: UInt32
    }

    struct Entry: Equatable {
        let name: String
        let isDirectory: Bool
        let icb: ICB
    }

    /// A file's bytes: where they are, or — for a file small enough that UDF
    /// stored it inside its own entry — what they are.
    enum Contents: Equatable {
        case extents([DiscExtent])
        case embedded(Data)
    }

    private enum Tag {
        static let anchor: UInt16 = 2
        static let partition: UInt16 = 5
        static let logicalVolume: UInt16 = 6
        static let terminating: UInt16 = 8
        static let fileSet: UInt16 = 256
        static let fileIdentifier: UInt16 = 257
        static let allocationExtent: UInt16 = 258
        static let fileEntry: UInt16 = 261
        static let extendedFileEntry: UInt16 = 266
    }

    /// The anchor is at a fixed logical sector, which is what makes "is this
    /// a UDF image at all" a cheap question to answer.
    private static let anchorSector: Int64 = 256
    private static let sectorSize: Int64 = 2_048
    /// Bounds on a structure a server handed us: a malformed image should
    /// fail the open, never spin.
    private static let maxVolumeDescriptors = 64
    private static let maxExtents = 8_192
    private static let maxAllocationContinuations = 64
    private static let maxDirectoryBytes = 4 * 1_024 * 1_024

    private let source: DiscImageSource
    private var blockSize: Int64 = UDFVolume.sectorSize
    private var partitionStart: Int64 = 0
    private var metadataPartition: UInt16?
    private var metadataExtents: [DiscExtent] = []
    private(set) var root = ICB(block: 0, partition: 0, length: 0)

    init(source: DiscImageSource) throws {
        self.source = source
        try mount()
    }

    // MARK: - Mounting

    private func mount() throws {
        let anchor = try sector(at: Self.anchorSector)
        guard try anchor.u16(0) == Tag.anchor else { throw DiscImageError.notUDF }
        let sequenceLength = Int64(try anchor.u32(16))
        let sequenceStart = Int64(try anchor.u32(20))

        var partitionDescriptor: DiscBytes?
        var logicalVolume: DiscBytes?
        let sectors = min(sequenceLength / Self.sectorSize, Int64(Self.maxVolumeDescriptors))
        for index in 0..<max(sectors, 0) {
            let descriptor = try sector(at: sequenceStart + index)
            switch try descriptor.u16(0) {
            case Tag.partition: partitionDescriptor = descriptor
            case Tag.logicalVolume: logicalVolume = descriptor
            case Tag.terminating: break
            default: continue
            }
            if try descriptor.u16(0) == Tag.terminating { break }
        }
        guard let partitionDescriptor, let logicalVolume else {
            throw DiscImageError.malformed("no partition or logical volume descriptor")
        }

        partitionStart = Int64(try partitionDescriptor.u32(188))
        let declaredBlockSize = Int64(try logicalVolume.u32(212))
        guard declaredBlockSize >= 512, declaredBlockSize <= 65_536 else {
            throw DiscImageError.malformed("logical block size \(declaredBlockSize)")
        }
        blockSize = declaredBlockSize

        try mountMetadataPartition(in: logicalVolume)

        let fileSetLocation = try longAD(logicalVolume, at: 248)
        let fileSet = try read(
            block: fileSetLocation.block,
            partition: fileSetLocation.partition,
            count: Int(Self.sectorSize)
        )
        guard try fileSet.u16(0) == Tag.fileSet else {
            throw DiscImageError.malformed("no file set descriptor")
        }
        root = try longAD(fileSet, at: 400)
    }

    /// UDF 2.50's metadata partition, which every BD-ROM image uses. Its file
    /// is described in the physical partition; once its extents are known,
    /// logical blocks addressed to that partition are offsets into it.
    private func mountMetadataPartition(in logicalVolume: DiscBytes) throws {
        let count = Int(try logicalVolume.u32(268))
        var offset = 440
        for reference in 0..<min(count, Self.maxVolumeDescriptors) {
            let kind = try logicalVolume.u8(offset)
            let length = Int(try logicalVolume.u8(offset + 1))
            guard length > 0 else { break }
            if kind == 2, try logicalVolume.identifier(offset + 4).contains("Metadata") {
                let fileBlock = try logicalVolume.u32(offset + 40)
                let entry = try physical(block: fileBlock, count: Int(Self.sectorSize))
                // Read with no metadata mapping in place yet: the metadata
                // file itself is always described in the physical partition.
                guard case .extents(let extents) = try contents(ofEntry: entry, partition: nil) else {
                    throw DiscImageError.malformed("metadata file stored inside its own entry")
                }
                metadataExtents = extents
                metadataPartition = UInt16(reference)
                return
            }
            offset += length
        }
    }

    // MARK: - Addressing

    private func sector(at index: Int64) throws -> DiscBytes {
        DiscBytes(try source.read(at: index * Self.sectorSize, count: Int(Self.sectorSize)))
    }

    private func physical(block: UInt32, count: Int) throws -> DiscBytes {
        DiscBytes(try source.read(at: (partitionStart + Int64(block)) * blockSize, count: count))
    }

    /// Image extents for a run of logical blocks, resolved through the
    /// metadata partition when the descriptor names it. A metadata run can
    /// cross the metadata file's own extents, so this may return several.
    private func imageExtents(block: UInt32, length: Int64, partition: UInt16?) -> [DiscExtent] {
        guard let partition, partition == metadataPartition, !metadataExtents.isEmpty else {
            return [DiscExtent(offset: (partitionStart + Int64(block)) * blockSize, length: length)]
        }
        var offset = Int64(block) * blockSize
        var remaining = length
        var mapped: [DiscExtent] = []
        for extent in metadataExtents {
            guard remaining > 0 else { break }
            if offset >= extent.length {
                offset -= extent.length
                continue
            }
            let take = min(remaining, extent.length - offset)
            mapped.append(DiscExtent(offset: extent.offset + offset, length: take))
            remaining -= take
            offset = 0
        }
        return mapped
    }

    private func read(block: UInt32, partition: UInt16?, count: Int) throws -> DiscBytes {
        var data = Data()
        for extent in imageExtents(block: block, length: Int64(count), partition: partition) {
            data += try source.read(at: extent.offset, count: Int(extent.length))
            if data.count >= count { break }
        }
        return DiscBytes(data)
    }

    private func longAD(_ bytes: DiscBytes, at offset: Int) throws -> ICB {
        ICB(
            block: try bytes.u32(offset + 4),
            partition: try bytes.u16(offset + 8),
            length: try bytes.u32(offset) & 0x3FFF_FFFF
        )
    }

    // MARK: - File entries

    func entry(_ icb: ICB) throws -> DiscBytes {
        try read(
            block: icb.block,
            partition: icb.partition,
            count: max(Int(Self.sectorSize), Int(icb.length))
        )
    }

    /// The extents of a file, in image bytes, or its contents when UDF stored
    /// them inside the entry.
    func contents(of icb: ICB) throws -> Contents {
        try contents(ofEntry: try entry(icb), partition: icb.partition)
    }

    private func contents(ofEntry entry: DiscBytes, partition: UInt16?) throws -> Contents {
        let tag = try entry.u16(0)
        let descriptorType = try entry.u16(34) & 0x07
        let extendedAttributes: Int
        let descriptors: Int
        let base: Int
        switch tag {
        case Tag.extendedFileEntry:
            extendedAttributes = Int(try entry.u32(208))
            descriptors = Int(try entry.u32(212))
            base = 216
        case Tag.fileEntry:
            extendedAttributes = Int(try entry.u32(168))
            descriptors = Int(try entry.u32(172))
            base = 176
        default:
            throw DiscImageError.malformed("expected a file entry, found tag \(tag)")
        }

        var bytes = entry
        var offset = base + extendedAttributes
        var end = offset + descriptors
        if descriptorType == 3 {
            return .embedded(try bytes.bytes(offset, descriptors))
        }
        guard descriptorType == 0 || descriptorType == 1 else {
            throw DiscImageError.unsupported("allocation descriptor type \(descriptorType)")
        }

        var extents: [DiscExtent] = []
        var continuations = 0
        while offset < end, extents.count < Self.maxExtents {
            let rawLength: UInt32
            let block: UInt32
            let extentPartition: UInt16?
            if descriptorType == 0 {
                rawLength = try bytes.u32(offset)
                block = try bytes.u32(offset + 4)
                extentPartition = partition
                offset += 8
            } else {
                rawLength = try bytes.u32(offset)
                block = try bytes.u32(offset + 4)
                extentPartition = try bytes.u16(offset + 8)
                offset += 16
            }
            let length = Int64(rawLength & 0x3FFF_FFFF)
            switch rawLength >> 30 {
            case 3:
                // The descriptors continue in a block of their own.
                continuations += 1
                guard continuations <= Self.maxAllocationContinuations else {
                    throw DiscImageError.malformed("allocation descriptors never end")
                }
                let continuation = try read(
                    block: block,
                    partition: extentPartition,
                    count: Int(Self.sectorSize)
                )
                guard try continuation.u16(0) == Tag.allocationExtent else {
                    throw DiscImageError.malformed("expected an allocation extent descriptor")
                }
                bytes = continuation
                offset = 24
                end = 24 + Int(try continuation.u32(20))
            case 0 where length > 0:
                extents.append(contentsOf: imageExtents(
                    block: block,
                    length: length,
                    partition: extentPartition
                ))
            default:
                // Allocated but not recorded, or a terminator. Neither has
                // bytes to read.
                if length == 0 { offset = end }
            }
        }
        return .extents(extents)
    }

    /// A whole file, for the small ones this reader is allowed to open: a
    /// directory, a playlist. Never a stream.
    func data(of icb: ICB, limit: Int = UDFVolume.maxDirectoryBytes) throws -> Data {
        switch try contents(of: icb) {
        case .embedded(let data):
            return data
        case .extents(let extents):
            var data = Data()
            for extent in extents {
                guard data.count < limit else { break }
                let take = Int(min(extent.length, Int64(limit - data.count)))
                data += try source.read(at: extent.offset, count: take)
            }
            return data
        }
    }

    // MARK: - Directories

    func list(_ icb: ICB) throws -> [Entry] {
        let data = DiscBytes(try data(of: icb))
        var entries: [Entry] = []
        var offset = 0
        while offset + 38 <= data.count {
            guard try data.u16(offset) == Tag.fileIdentifier else { break }
            let characteristics = try data.u8(offset + 18)
            let nameLength = Int(try data.u8(offset + 19))
            let child = try longAD(data, at: offset + 20)
            let implementationUse = Int(try data.u16(offset + 36))
            let nameOffset = offset + 38 + implementationUse
            // Bit 3 marks the entry pointing back at the parent directory,
            // which has no name and is not a child.
            if characteristics & 0x08 == 0, nameLength > 0 {
                let raw = try data.bytes(nameOffset, nameLength)
                entries.append(Entry(
                    name: DiscBytes.characters(raw),
                    isDirectory: characteristics & 0x02 != 0,
                    icb: child
                ))
            }
            var length = 38 + implementationUse + nameLength
            length += (4 - (length % 4)) % 4
            guard length > 0 else { break }
            offset += length
        }
        return entries
    }

    /// Resolve a slash-separated path from the root. Case-insensitive: the
    /// specification uppercases BDMV's names, and images in the wild are not
    /// uniformly obedient about it.
    func entry(at path: String) throws -> Entry? {
        var current = Entry(name: "", isDirectory: true, icb: root)
        for component in path.split(separator: "/") {
            guard current.isDirectory else { return nil }
            let name = component.uppercased()
            guard let next = try list(current.icb).first(where: { $0.name.uppercased() == name }) else {
                return nil
            }
            current = next
        }
        return current
    }
}
