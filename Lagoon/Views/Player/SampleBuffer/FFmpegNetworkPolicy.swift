import Libavformat
import Libavutil

/// Applies to native direct-file fallback and every HLS manifest, segment and key.
/// The owned libavformat also verifies by default, covering internal reconnects
/// and protocol opens which do not go through AVFormatContext.io_open.
nonisolated enum FFmpegNetworkPolicy {
    // FFmpeg's default stderr logger prints complete HLS URLs on failures,
    // including Jellyfin's query token. Lagoon reports av_strerror results and
    // its own playback diagnostics; do not emit the native raw URL messages.
    private static let configureLogging: Void = {
        av_log_set_level(AV_LOG_QUIET)
    }()

    static func install(on context: UnsafeMutablePointer<AVFormatContext>) {
        _ = configureLogging
        context.pointee.io_open = { context, output, url, flags, options in
            FFmpegNetworkPolicy.open(context: context, output: output, url: url, flags: flags, options: options)
        }
    }

    static func open(
        context: UnsafeMutablePointer<AVFormatContext>?,
        output: UnsafeMutablePointer<UnsafeMutablePointer<AVIOContext>?>?,
        url: UnsafePointer<CChar>?,
        flags: Int32,
        options: UnsafeMutablePointer<OpaquePointer?>?
    ) -> Int32 {
        _ = configureLogging
        guard let output, let url else { return -22 } // AVERROR(EINVAL)
        var localOptions: OpaquePointer?
        defer { av_dict_free(&localOptions) }
        return withUnsafeMutablePointer(to: &localOptions) { local in
            let options = options ?? local
            let result = av_dict_set(options, "tls_verify", "1", 0)
            guard result >= 0 else { return result }
            // The certificate must match the actual endpoint, including redirects.
            av_dict_set(options, "verifyhost", nil, 0)
            // Preserve the protocol restrictions used by FFmpeg's default
            // io_open callback (avio_open2 cannot read the parent context).
            for (key, value) in [
                ("protocol_whitelist", context?.pointee.protocol_whitelist),
                ("protocol_blacklist", context?.pointee.protocol_blacklist),
            ] {
                if let value {
                    let result = av_dict_set(options, key, value, 0)
                    guard result >= 0 else { return result }
                }
            }
            var interrupt = context?.pointee.interrupt_callback ?? AVIOInterruptCB()
            return avio_open2(output, url, flags, &interrupt, options)
        }
    }
}
