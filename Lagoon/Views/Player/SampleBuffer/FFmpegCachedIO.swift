import Foundation
import Libavformat
import Libavutil

nonisolated private let avSeekSize: Int32 = 0x10000
nonisolated private let avSeekForce: Int32 = 0x20000
nonisolated private let avIOErrorEOF: Int32 = -541_478_725

/// Bridges FFmpeg's synchronous AVIO callbacks to Lagoon's bounded sparse
/// range cache. The object is retained by FFmpegDemuxer for longer than the
/// AVIOContext; the callback's unmanaged reference is therefore unretained.
nonisolated final class FFmpegCachedIO {
    private let scope: PlaybackCacheScope
    private var position: Int64 = 0
    private(set) var context: UnsafeMutablePointer<AVIOContext>?

    init(scope: PlaybackCacheScope, bufferSize: Int32 = 64 * 1_024) throws {
        self.scope = scope
        guard let buffer = av_malloc(Int(bufferSize))?.assumingMemoryBound(to: UInt8.self) else {
            throw PlaybackCacheError.storageUnavailable
        }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let context = avio_alloc_context(
            buffer,
            bufferSize,
            0,
            opaque,
            { opaque, buffer, size in
                guard let opaque, let buffer, size > 0 else { return avIOErrorEOF }
                return Unmanaged<FFmpegCachedIO>
                    .fromOpaque(opaque)
                    .takeUnretainedValue()
                    .read(into: buffer, size: size)
            },
            nil,
            { opaque, offset, whence in
                guard let opaque else { return -1 }
                return Unmanaged<FFmpegCachedIO>
                    .fromOpaque(opaque)
                    .takeUnretainedValue()
                    .seek(offset: offset, whence: whence)
            }
        ) else {
            av_free(buffer)
            throw PlaybackCacheError.storageUnavailable
        }
        self.context = context
    }

    func close() {
        guard context != nil else { return }
        if let buffer = context?.pointee.buffer {
            av_free(buffer)
            context?.pointee.buffer = nil
        }
        avio_context_free(&context)
    }

    private func read(into buffer: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        do {
            let data = try scope.read(offset: position, length: Int(size))
            guard !data.isEmpty else { return avIOErrorEOF }
            data.copyBytes(to: buffer, count: data.count)
            position += Int64(data.count)
            return Int32(data.count)
        } catch {
            return avIOErrorEOF
        }
    }

    private func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence & avSeekSize != 0 {
            return scope.contentLength ?? -1
        }
        let origin = whence & ~(avSeekForce)
        let target: Int64
        switch origin {
        case Int32(SEEK_SET):
            target = offset
        case Int32(SEEK_CUR):
            target = position + offset
        case Int32(SEEK_END):
            guard let length = scope.contentLength else { return -1 }
            target = length + offset
        default:
            return -1
        }
        guard target >= 0 else { return -1 }
        position = target
        return target
    }
}
