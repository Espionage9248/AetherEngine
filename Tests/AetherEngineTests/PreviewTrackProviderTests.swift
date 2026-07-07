// Tests/AetherEngineTests/PreviewTrackProviderTests.swift
import Testing
import Foundation
import Libavcodec
import Libavutil
@testable import AetherEngine

/// Minimal fMP4 box walker for fragment assertions. Big-endian reads.
private struct BoxReader {
    let data: Data
    func be32(_ o: Int) -> Int { Int(data[o]) << 24 | Int(data[o+1]) << 16 | Int(data[o+2]) << 8 | Int(data[o+3]) }
    func be64(_ o: Int) -> Int64 {
        (0..<8).reduce(Int64(0)) { ($0 << 8) | Int64(data[o + $1]) }
    }
    func type(_ o: Int) -> String { String(bytes: data[o+4..<o+8], encoding: .ascii) ?? "" }
    /// Offset of the first box named `name` inside [start, end), or nil.
    func find(_ name: String, in range: Range<Int>) -> Int? {
        var o = range.lowerBound
        while o + 8 <= range.upperBound {
            let size = be32(o)
            if type(o) == name { return o }
            if size < 8 { return nil }
            o += size
        }
        return nil
    }
}

private func fragmentFacts(_ url: URL) throws -> (tfdt: Int64, sampleCount: Int, lastSampleDurationNonZero: Bool) {
    let data = try Data(contentsOf: url)
    let r = BoxReader(data: data)
    guard let moof = r.find("moof", in: 0..<data.count) else { throw TestError.noMoof }
    let moofEnd = moof + r.be32(moof)
    guard let traf = r.find("traf", in: (moof + 8)..<moofEnd) else { throw TestError.noTraf }
    let trafEnd = traf + r.be32(traf)
    guard let tfdt = r.find("tfdt", in: (traf + 8)..<trafEnd) else { throw TestError.noTfdt }
    let version = Int(data[tfdt + 8])
    let base: Int64 = version == 1 ? r.be64(tfdt + 12) : Int64(r.be32(tfdt + 12))
    guard let trun = r.find("trun", in: (traf + 8)..<trafEnd) else { throw TestError.noTrun }
    let flags = r.be32(trun + 8) & 0x00FFFFFF
    let sampleCount = r.be32(trun + 12)
    // First-sample fields start after count (+ optional data_offset / first_sample_flags).
    var fieldOffset = trun + 16
    if flags & 0x000001 != 0 { fieldOffset += 4 }   // data-offset present
    if flags & 0x000004 != 0 { fieldOffset += 4 }   // first-sample-flags present
    var lastDurationNonZero = false
    if flags & 0x000100 != 0 {                      // per-sample duration present in trun
        lastDurationNonZero = r.be32(fieldOffset) > 0   // single sample → first == last
    } else if let tfhd = r.find("tfhd", in: (traf + 8)..<trafEnd) {
        // This mp4 muxer hoists a fragment's uniform sample duration into the
        // tfhd default_sample_duration (flag 0x8) rather than emitting it
        // per-sample in the trun, so read it there. Optional tfhd fields, in
        // order: base_data_offset (0x1, 8B), sample_description_index (0x2, 4B),
        // then default_sample_duration (0x8, 4B).
        let tfhdFlags = r.be32(tfhd + 8) & 0x00FFFFFF
        var o = tfhd + 16                            // after size/type/verflags/track_ID
        if tfhdFlags & 0x000001 != 0 { o += 8 }
        if tfhdFlags & 0x000002 != 0 { o += 4 }
        if tfhdFlags & 0x000008 != 0 { lastDurationNonZero = r.be32(o) > 0 }
    }
    return (base, sampleCount, lastDurationNonZero)
}
private enum TestError: Error { case noMoof, noTraf, noTfdt, noTrun }

/// Read the video track's mdhd timescale from the init segment
/// (moov → trak → mdia → mdhd). The mp4 muxer auto-picks this timescale after
/// avformat_write_header, so fragment tfdt/duration values are in these ticks —
/// assertions must convert seconds through it rather than hard-coding a tick count.
private func mdhdTimescale(_ initData: Data) -> Int {
    let r = BoxReader(data: initData)
    guard let moov = r.find("moov", in: 0..<initData.count) else { return 0 }
    let moovEnd = moov + r.be32(moov)
    guard let trak = r.find("trak", in: (moov + 8)..<moovEnd) else { return 0 }
    let trakEnd = trak + r.be32(trak)
    guard let mdia = r.find("mdia", in: (trak + 8)..<trakEnd) else { return 0 }
    let mdiaEnd = mdia + r.be32(mdia)
    guard let mdhd = r.find("mdhd", in: (mdia + 8)..<mdiaEnd) else { return 0 }
    let version = Int(initData[mdhd + 8])
    // v0: creation(4)+modification(4) precede timescale → mdhd+8+12; v1: 8+8 → mdhd+8+20.
    return r.be32(version == 1 ? mdhd + 28 : mdhd + 20)
}

/// Build a StreamConfig over the fixture's own codecpar (the engine passes its
/// resolved playback config in production; the fixture's params stand in here).
private func makeConfig(from demuxer: Demuxer) -> HLSSegmentProducer.StreamConfig {
    let stream = demuxer.stream(at: demuxer.videoStreamIndex)!
    return HLSSegmentProducer.StreamConfig(
        codecpar: UnsafePointer(stream.pointee.codecpar!),
        timeBase: stream.pointee.time_base,
        codecTagOverride: nil
    )
}

@Suite("PreviewTrackProvider", .serialized)
struct PreviewTrackProviderTests {

    private func plan(segmentSeconds stride: Double, count: Int, startPtsTicks: Int64,
                      tb: Double = 1.0 / 90000) -> [HLSVideoEngine.Segment] {
        (0..<count).map { i in
            HLSVideoEngine.Segment(
                startPts: startPtsTicks + Int64(Double(i) * stride / tb),
                endPts: startPtsTicks + Int64(Double(i + 1) * stride / tb),
                startSeconds: Double(i) * stride,
                durationSeconds: stride)
        }
    }

    /// End-to-end over a fixture whose pts start at 0: fragments land in the
    /// cache with tfdt == plan.startPts (firstKeyframePts == 0).
    @Test func sweepProducesFragmentsWithPlanAlignedTfdt() throws {
        let url = try TestMediaFixture.writeMP4(frames: 360, gop: 60)  // keyframes @ 0,2,4,6,8,10s
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = Demuxer(); try probe.open(url: url, profile: .stillExtraction)
        let cfg = makeConfig(from: probe)
        let p = plan(segmentSeconds: 6.0, count: 2, startPtsTicks: 0)  // segs @ 0s, 6s
        let provider = PreviewTrackProvider(sourceURL: url, httpHeaders: [:],
                                            plan: p, firstKeyframePts: 0, videoConfig: cfg)
        provider.runSweepSynchronously()
        probe.close()
        defer { provider.shutdown() }
        // The mp4 muxer picks its own output timescale after write_header, so
        // validate the SECONDS mapping through the init segment's mdhd timescale,
        // not a raw tick count.
        let initData = try #require(provider.previewInitData())
        let timescale = mdhdTimescale(initData)
        #expect(timescale > 0)
        let f0 = try fragmentFacts(provider.previewFragmentURL(forIndex: 0)!)
        #expect(f0.tfdt == 0)
        #expect(f0.sampleCount == 1)
        let f1 = try fragmentFacts(provider.previewFragmentURL(forIndex: 1)!)
        #expect(f1.tfdt == Int64((6.0 * Double(timescale)).rounded()))  // fragment 1 sits at 6.0s
    }

    /// Non-zero-origin source (the Gate-0 finding): pts start at 10s; plan startPts
    /// are RAW stream pts; firstKeyframePts == 900000. tfdt must be rebased to 0.
    @Test func sweepRebasesNonZeroOriginToMediaTimeline() throws {
        let url = try TestMediaFixture.writeMP4(frames: 360, gop: 60, startPtsTicks: 900_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = Demuxer(); try probe.open(url: url, profile: .stillExtraction)
        let cfg = makeConfig(from: probe)
        let p = plan(segmentSeconds: 6.0, count: 2, startPtsTicks: 900_000)
        let provider = PreviewTrackProvider(sourceURL: url, httpHeaders: [:],
                                            plan: p, firstKeyframePts: 900_000, videoConfig: cfg)
        provider.runSweepSynchronously()
        probe.close()
        defer { provider.shutdown() }
        let f0 = try fragmentFacts(provider.previewFragmentURL(forIndex: 0)!)
        #expect(f0.tfdt == 0)                                          // rebased, not 900000
    }

    /// Zero-duration source packets (the review-#3 finding): sample_duration
    /// must be backfilled, never 0.
    @Test func zeroDurationPacketsGetBackfilledSampleDuration() throws {
        let url = try TestMediaFixture.writeMP4(frames: 360, gop: 60, packetDurations: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = Demuxer(); try probe.open(url: url, profile: .stillExtraction)
        let cfg = makeConfig(from: probe)
        let p = plan(segmentSeconds: 6.0, count: 1, startPtsTicks: 0)
        let provider = PreviewTrackProvider(sourceURL: url, httpHeaders: [:],
                                            plan: p, firstKeyframePts: 0, videoConfig: cfg)
        provider.runSweepSynchronously()
        probe.close()
        defer { provider.shutdown() }
        let f0 = try fragmentFacts(provider.previewFragmentURL(forIndex: 0)!)
        #expect(f0.lastSampleDurationNonZero)
    }

    /// C1 isolation is BY CONSTRUCTION: the whole preview stack runs here with
    /// NO SegmentCache, NO producer, NO playback engine in existence.
    @Test func previewStackNeedsNoPlaybackStack() throws {
        let url = try TestMediaFixture.writeMP4(frames: 180, gop: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = Demuxer(); try probe.open(url: url, profile: .stillExtraction)
        let cfg = makeConfig(from: probe)
        let provider = PreviewTrackProvider(sourceURL: url, httpHeaders: [:],
                                            plan: plan(segmentSeconds: 6.0, count: 1, startPtsTicks: 0),
                                            firstKeyframePts: 0, videoConfig: cfg)
        provider.runSweepSynchronously()
        probe.close()
        #expect(provider.previewFragmentURL(forIndex: 0) != nil)        // exact swept index → url
        #expect(provider.previewFragmentURL(forIndex: 999) == nil)      // unswept index → 404 (was nearest)
        provider.shutdown()
        #expect(provider.previewFragmentURL(forIndex: 0) == nil)       // dead after shutdown
    }

    @Test func demuxOpenFailureLeavesFeatureSilentlyAbsent() throws {
        let bogus = URL(fileURLWithPath: "/nonexistent/no.mp4")
        let fixture = try TestMediaFixture.writeMP4(frames: 30, gop: 30)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let probe = Demuxer(); try probe.open(url: fixture, profile: .stillExtraction)
        let cfg = makeConfig(from: probe)
        let provider = PreviewTrackProvider(sourceURL: bogus, httpHeaders: [:],
                                            plan: plan(segmentSeconds: 6.0, count: 1, startPtsTicks: 0),
                                            firstKeyframePts: 0, videoConfig: cfg)
        provider.runSweepSynchronously()                                // must not crash
        probe.close()
        #expect(provider.previewInitData() == nil)
        #expect(provider.previewFragmentURL(forIndex: 0) == nil)
        provider.shutdown()
    }
}
