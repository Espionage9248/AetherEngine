// Tests/AetherEngineTests/TestMediaFixture.swift
import Foundation
import Libavformat
import Libavcodec
import Libavutil
@testable import AetherEngine

enum TestMediaFixture {
    struct FixtureError: Error { let stage: String; let code: Int32 }

    /// Video-only MP4: `frames` packets at `fps`, keyframe every `gop`-th frame,
    /// pts starting at `startPtsTicks` (time_base 1/90000), 256-byte dummy payloads.
    /// Payloads are garbage — these fixtures are for DEMUX tests only.
    static func writeMP4(frames: Int, fps: Int = 30, gop: Int = 30,
                         startPtsTicks: Int64 = 0,
                         packetDurations: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-\(UUID().uuidString).mp4")
        var ctxOut: UnsafeMutablePointer<AVFormatContext>?
        let alloc = avformat_alloc_output_context2(&ctxOut, nil, "mp4", url.path)
        guard alloc >= 0, let ctx = ctxOut else { throw FixtureError(stage: "alloc", code: alloc) }
        defer { avformat_free_context(ctx) }

        guard let stream = avformat_new_stream(ctx, nil) else {
            throw FixtureError(stage: "stream", code: -1)
        }
        stream.pointee.time_base = AVRational(num: 1, den: 90000)
        let par = stream.pointee.codecpar!
        par.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        // FFV1 (not MPEG-4): the mov demuxer reads width/height straight from
        // the sample entry, so `avformat_find_stream_info` never attaches a
        // bitstream parser to recover dimensions from the dummy payloads. That
        // keeps the container `stss` keyframe table authoritative, which is
        // exactly what `AVDISCARD_NONKEY` filters on. MPEG-4 reports 0×0 here
        // (dimensions live in the VOL bitstream we don't write), forcing a
        // parser that mis-flags the garbage packets and breaks NONKEY demux.
        par.pointee.codec_id = AV_CODEC_ID_FFV1
        par.pointee.width = 64
        par.pointee.height = 64

        var pb: UnsafeMutablePointer<AVIOContext>?
        let open = avio_open(&pb, url.path, AVIO_FLAG_WRITE)
        guard open >= 0 else { throw FixtureError(stage: "avio", code: open) }
        ctx.pointee.pb = pb
        defer { var p = pb; avio_closep(&p) }

        let hdr = avformat_write_header(ctx, nil)
        guard hdr >= 0 else { throw FixtureError(stage: "header", code: hdr) }

        let tickPerFrame = Int64(90000 / fps)
        var payload = [UInt8](repeating: 0xAB, count: 256)
        for i in 0..<frames {
            let pkt = av_packet_alloc()!
            defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
            _ = av_new_packet(pkt, 256)
            payload.withUnsafeBytes { src in
                pkt.pointee.data.update(from: src.bindMemory(to: UInt8.self).baseAddress!, count: 256)
            }
            pkt.pointee.stream_index = 0
            pkt.pointee.pts = startPtsTicks + Int64(i) * tickPerFrame
            pkt.pointee.dts = pkt.pointee.pts
            pkt.pointee.duration = packetDurations ? tickPerFrame : 0
            if i % gop == 0 { pkt.pointee.flags |= AV_PKT_FLAG_KEY }
            let w = av_interleaved_write_frame(ctx, pkt)
            guard w >= 0 else { throw FixtureError(stage: "write", code: w) }
        }
        let trailer = av_write_trailer(ctx)
        guard trailer >= 0 else { throw FixtureError(stage: "trailer", code: trailer) }
        return url
    }
}
