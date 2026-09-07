import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Testing
@testable import Lagoon

@Suite("Native FFmpeg TLS", .serialized)
struct FFmpegTransportTests {
    @Test func theLinkedTLSBackendVerifiesByDefault() throws {
        var tlsClass = try #require(avio_protocol_get_class("tls"))
        let option = withUnsafeMutablePointer(to: &tlsClass) {
            av_opt_find($0, "tls_verify", nil, 0, AV_OPT_SEARCH_FAKE_OBJ)
        }
        #expect(try #require(option).pointee.default_val.i64 == 1)
    }

    @Test func nativeOpenPreservesParentCancellation() throws {
        let context = try #require(avformat_alloc_context())
        defer { avformat_free_context(context) }
        context.pointee.interrupt_callback = AVIOInterruptCB(callback: { _ in 1 }, opaque: nil)
        var io: UnsafeMutablePointer<AVIOContext>?
        defer { if io != nil { avio_closep(&io) } }
        let result = FFmpegNetworkPolicy.open(context: context, output: &io,
                                             url: "https://127.0.0.1:9/body", flags: AVIO_FLAG_READ, options: nil)
        #expect(result == -1414092869) // AVERROR_EXIT
    }

    // Run scripts/test-ffmpeg-tls.py for controlled certificates, HTTP logs and
    // simulator-only trust roots. Ordinary unit runs still check the binary's
    // default, without depending on network access or third-party servers.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LAGOON_TLS_FIXTURES"] != nil))
    func certificateAndNestedRequestMatrix() async throws {
        let base = try #require(ProcessInfo.processInfo.environment["LAGOON_TLS_FIXTURES"])
        let (data, _) = try await URLSession.shared.data(from: #require(URL(string: base + "/fixtures")))
        let cases = try JSONDecoder().decode([Fixture].self, from: data)
        #expect(cases.count >= 20)
        for fixture in cases {
            let result = fixture.hls ? readHLS(fixture.url) : readNative(fixture)
            // Each valid HLS fixture has three one-second AAC segments. This
            // catches failures after the initial segment, including keepalive.
            let completed = fixture.hls ? result >= 120 : result > 0
            #expect(completed == fixture.allowed, "\(fixture.name): read result \(result)")
        }
        let (report, _) = try await URLSession.shared.data(from: #require(URL(string: base + "/report")))
        let violations = try JSONDecoder().decode([String].self, from: report)
        #expect(violations.isEmpty, "HTTP requests reached invalid TLS peers: \(violations)")
    }

    private nonisolated struct Fixture: Decodable {
        let name: String
        let url: String
        let allowed: Bool
        let hls: Bool
        let enforce: Bool
        let reconnect: Bool
    }

    private nonisolated func readNative(_ fixture: Fixture) -> Int32 {
        var io: UnsafeMutablePointer<AVIOContext>?
        var options: OpaquePointer?
        av_dict_set(&options, "rw_timeout", "5000000", 0)
        if fixture.enforce {
            // A caller cannot accidentally weaken the application policy.
            av_dict_set(&options, "tls_verify", "0", 0)
            av_dict_set(&options, "verifyhost", "wrong.invalid", 0)
        }
        if fixture.reconnect {
            av_dict_set(&options, "reconnect", "1", 0)
            av_dict_set(&options, "reconnect_streamed", "1", 0)
            av_dict_set(&options, "reconnect_delay_max", "1", 0)
            av_dict_set(&options, "reconnect_max_retries", "1", 0)
        }
        defer {
            if io != nil { avio_closep(&io) }
            av_dict_free(&options)
        }
        let result = fixture.url.withCString { url in
            if fixture.enforce {
                return FFmpegNetworkPolicy.open(context: nil, output: &io, url: url,
                                                flags: AVIO_FLAG_READ, options: &options)
            }
            return avio_open2(&io, url, AVIO_FLAG_READ, nil, &options)
        }
        guard result >= 0, let io else { return result }
        var bytes = [UInt8](repeating: 0, count: 4096)
        var total: Int32 = 0
        while total < 65_536 {
            let count = avio_read(io, &bytes, Int32(bytes.count))
            if count <= 0 { break }
            total += count
        }
        // Reconnect fixtures advertise 64 KiB, then drop after 8 KiB. A valid
        // reconnect must finish; a changed invalid certificate must stop it.
        return fixture.reconnect && total != 65_536 ? -1 : total
    }

    private nonisolated func readHLS(_ url: String) -> Int32 {
        guard let allocated = avformat_alloc_context() else { return -12 }
        FFmpegNetworkPolicy.install(on: allocated)
        var context: UnsafeMutablePointer<AVFormatContext>? = allocated
        var options: OpaquePointer?
        av_dict_set(&options, "rw_timeout", "5000000", 0)
        // Leave HLS native persistent connections enabled, as in production.
        defer {
            avformat_close_input(&context)
            av_dict_free(&options)
        }
        let result = avformat_open_input(&context, url, nil, &options)
        guard result >= 0, let context, let packet = av_packet_alloc() else { return result }
        var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&packetToFree) }
        var packets: Int32 = 0
        while packets < 500 {
            if av_read_frame(context, packet) < 0 { break }
            packets += 1
            av_packet_unref(packet)
        }
        return packets
    }
}
