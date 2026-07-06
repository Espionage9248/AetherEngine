// Tests/AetherEngineTests/PreviewDemuxTests.swift
import Testing
import Foundation
import Libavcodec
import Libavutil
@testable import AetherEngine

@Suite("PreviewDemux")
struct PreviewDemuxTests {

    /// Fixture sanity FIRST: if the synthetic-MP4 approach fails at runtime,
    /// STOP and report — do not silently skip (plan gate).
    @Test func fixtureRoundTripsThroughDemuxer() throws {
        let url = try TestMediaFixture.writeMP4(frames: 90, gop: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let d = Demuxer()
        try d.open(url: url, profile: .stillExtraction)
        defer { d.close() }
        #expect(d.videoStreamIndex >= 0)
        var packets = 0
        while let pkt = try d.readPacket() { av_packet_unref(pkt); packets += 1 }
        #expect(packets == 90)
    }

    @Test func nonKeyDiscardYieldsOnlyKeyframes() throws {
        let url = try TestMediaFixture.writeMP4(frames: 90, gop: 30)   // keyframes @ 0,30,60
        defer { try? FileManager.default.removeItem(at: url) }
        let d = Demuxer()
        try d.open(url: url, profile: .stillExtraction)
        defer { d.close() }
        d.discardAllStreamsExcept([d.videoStreamIndex])
        d.discardNonKeyPackets(streamIndex: d.videoStreamIndex)
        var keyPts: [Int64] = []
        while let pkt = try d.readPacket() {
            keyPts.append(pkt.pointee.pts)
            av_packet_unref(pkt)
        }
        #expect(keyPts == [0, 90000, 180000])   // 30fps → 3000 ticks/frame × 30
    }

    @Test func seekThenScanForwardFindsKeyframeAtOrAfterTarget() throws {
        let url = try TestMediaFixture.writeMP4(frames: 180, gop: 30)  // keyframes @ 0,1,2,3,4,5s
        defer { try? FileManager.default.removeItem(at: url) }
        let d = Demuxer()
        try d.open(url: url, profile: .stillExtraction)
        defer { d.close() }
        d.discardAllStreamsExcept([d.videoStreamIndex])
        d.discardNonKeyPackets(streamIndex: d.videoStreamIndex)
        d.seek(to: 1.5)                                    // mid-GOP: seek lands at/BEFORE
        let targetPts: Int64 = 135_000                     // 1.5s in 1/90000
        var found: Int64 = -1
        while let pkt = try d.readPacket() {
            let pts = pkt.pointee.pts
            av_packet_unref(pkt)
            if pts != Int64.min, pts < targetPts { continue }   // scan-forward gate
            found = pts; break
        }
        #expect(found == 180_000)                          // 2.0s keyframe, not 1.0s
    }
}
