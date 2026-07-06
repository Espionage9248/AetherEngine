// Tests/AetherEngineTests/IFramePlaylistTests.swift
//
// Byte-range I-frame playlist for trick-play seek previews (#158).
// tvOS AVKit renders the transport-bar scrubbing filmstrip only when the
// master advertises an #EXT-X-I-FRAME-STREAM-INF pointing at an
// #EXT-X-I-FRAMES-ONLY playlist (Apple HLS Authoring Spec 6.1). The
// loopback bridge synthesises that playlist over the SAME on-demand
// segments as the media playlist, using a FIXED generous byte range at
// offset 0 (every segment starts with its IDR at byte 0, so <LEN>@0 always
// covers moof+IDR and the server clamps the Range to the real segment
// size). These are pure-builder + pure-range-parser tests mirroring the
// existing playlist-builder tests; the socket wiring is device-verified.
import Testing
import Foundation
@testable import AetherEngine

/// VOD provider exposing master metadata + a hand-set segment list, so the
/// builders see a fully-known complete asset (the bridged trick-play case).
/// Only the members the builders read are meaningful; the rest take
/// protocol defaults. `masterVideoOnlyCodecs` is intentionally NOT
/// overridden so these tests exercise the protocol's derive-from-masterCodecs
/// default.
private final class IFrameVODProvider: HLSSegmentProvider, @unchecked Sendable {
    let count: Int
    let codecs: String
    let width: Int
    let height: Int
    let videoRange: HLSVideoRange?

    init(count: Int, codecs: String = "avc1.640029,mp4a.40.2",
         width: Int = 1920, height: Int = 1080,
         videoRange: HLSVideoRange? = nil) {
        self.count = count
        self.codecs = codecs
        self.width = width
        self.height = height
        self.videoRange = videoRange
    }

    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { count }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { .vod }

    var masterCodecs: String? { codecs }
    var masterResolution: (width: Int, height: Int)? { (width, height) }
    var masterVideoRange: HLSVideoRange? { videoRange }
    var masterBandwidth: Int? { 6_000_000 }
}

struct IFramePlaylistTests {

    private func lines(_ playlist: String) -> [String] {
        playlist.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - Part A: video-only codecs

    @Test("masterVideoOnlyCodecs strips the audio token")
    func videoOnlyCodecsStripsAudio() {
        let provider = IFrameVODProvider(count: 3, codecs: "avc1.640029,mp4a.40.2")
        #expect(provider.masterVideoOnlyCodecs == "avc1.640029")
    }

    @Test("masterVideoOnlyCodecs is the whole string when there is no audio token")
    func videoOnlyCodecsNoAudio() {
        let provider = IFrameVODProvider(count: 3, codecs: "hvc1.2.4.L153.90")
        #expect(provider.masterVideoOnlyCodecs == "hvc1.2.4.L153.90")
    }

    // MARK: - Part B: master advertises the I-frame stream

    @Test("master advertises #EXT-X-I-FRAME-STREAM-INF with a video-only CODECS and iframe.m3u8 URI")
    func masterAdvertisesIFrameStream() {
        let provider = IFrameVODProvider(count: 3)
        let master = HLSLocalServer.buildMasterPlaylistText(provider: provider)
        let ls = lines(master)

        guard let iframeLine = ls.first(where: { $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") }) else {
            Issue.record("master has no #EXT-X-I-FRAME-STREAM-INF line:\n\(master)")
            return
        }
        // URI is an attribute on the I-FRAME-STREAM-INF line (not a
        // following line, unlike EXT-X-STREAM-INF) per RFC 8216 4.3.4.3.
        #expect(iframeLine.contains("URI=\"iframe.m3u8\""))
        // CODECS must be video-only: the video token present, the audio
        // token absent (Apple HLS Authoring Spec 9.3).
        #expect(iframeLine.contains("CODECS=\"avc1.640029\""))
        #expect(!iframeLine.contains("mp4a"))
        #expect(iframeLine.contains("RESOLUTION=1920x1080"))
    }

    // MARK: - Part C: the I-frames-only playlist

    @Test("iframe playlist carries I-FRAMES-ONLY, MAP, and ENDLIST for VOD")
    func iframePlaylistShape() {
        let provider = IFrameVODProvider(count: 3)
        let iframe = HLSLocalServer.buildIFramePlaylistText(provider: provider)
        let ls = lines(iframe)

        #expect(ls.contains("#EXT-X-I-FRAMES-ONLY"))
        #expect(ls.contains(where: { $0.hasPrefix("#EXT-X-MAP:URI=") }))
        #expect(ls.contains("#EXT-X-ENDLIST"))
        #expect(ls.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
    }

    @Test("every iframe entry carries a byte range at offset 0, one per segment")
    func iframeByteRangesPerSegment() {
        let provider = IFrameVODProvider(count: 5)
        let iframe = HLSLocalServer.buildIFramePlaylistText(provider: provider)
        let ls = lines(iframe)

        let byteRanges = ls.filter { $0.hasPrefix("#EXT-X-BYTERANGE:") }
        let extinfs = ls.filter { $0.hasPrefix("#EXTINF:") }
        let segURIs = ls.filter { $0.hasPrefix("seg") }

        #expect(byteRanges.count == 5)
        #expect(extinfs.count == 5)
        #expect(segURIs.count == 5)
        // Every range starts at offset 0 (the IDR lives at byte 0 of every
        // keyframe-aligned segment).
        #expect(byteRanges.allSatisfy { $0.hasSuffix("@0") })
        // LEN = max(1 MiB, w*h/2). At 1920x1080: w*h/2 = 1_036_800 < 1 MiB,
        // so the 1 MiB floor governs. Pins the resolution-scaled formula.
        #expect(byteRanges.allSatisfy { $0 == "#EXT-X-BYTERANGE:1048576@0" })
    }

    @Test("iframe byte-range length scales up with resolution (4K)")
    func iframeByteRangeScales4K() {
        let provider = IFrameVODProvider(count: 2, width: 3840, height: 2160)
        let iframe = HLSLocalServer.buildIFramePlaylistText(provider: provider)
        // 3840*2160/2 = 4_147_200, above the 1 MiB floor.
        #expect(lines(iframe).allSatisfy { line in
            !line.hasPrefix("#EXT-X-BYTERANGE:") || line == "#EXT-X-BYTERANGE:4147200@0"
        })
    }

    // MARK: - Part D: HTTP Range parsing / clamping

    @Test("a full byte range within the segment is returned verbatim")
    func rangeWithinSegment() {
        // bytes=0-(LEN-1) where LEN-1 < size: kept as-is, length == LEN.
        let r = HLSLocalServer.parseByteRange("bytes=0-1048575", totalSize: 2_000_000)
        #expect(r?.start == 0)
        #expect(r?.end == 1_048_575)
        // Content-Length the 206 will send.
        #expect(r.map { $0.end - $0.start + 1 } == 1_048_576)
    }

    @Test("a byte range past EOF clamps its end to size-1")
    func rangePastEOFClamps() {
        let r = HLSLocalServer.parseByteRange("bytes=0-99999999", totalSize: 1000)
        #expect(r?.start == 0)
        #expect(r?.end == 999)
        #expect(r.map { $0.end - $0.start + 1 } == 1000)
    }

    @Test("an open-ended range serves through EOF")
    func rangeOpenEnded() {
        let r = HLSLocalServer.parseByteRange("bytes=500-", totalSize: 1000)
        #expect(r?.start == 500)
        #expect(r?.end == 999)
    }

    @Test("no Range header means serve the full body (200, not 206)")
    func noRangeHeader() {
        #expect(HLSLocalServer.parseByteRange(nil, totalSize: 1000) == nil)
        #expect(HLSLocalServer.parseByteRange("", totalSize: 1000) == nil)
        #expect(HLSLocalServer.parseByteRange("bytes=abc", totalSize: 1000) == nil)
    }

    @Test("a start beyond EOF is unsatisfiable and falls back to a full 200")
    func rangeStartBeyondEOF() {
        #expect(HLSLocalServer.parseByteRange("bytes=5000-6000", totalSize: 1000) == nil)
    }

    // MARK: - Part B2: VIDEO-RANGE on the I-frame line (#158 review I1)

    @Test("the I-frame line carries VIDEO-RANGE, mirroring the STREAM-INF main variant")
    func iframeLineCarriesVideoRange() {
        // An HDR/DV-8.x master (video-only codec is plain hvc1, so the
        // I-frame line IS emitted) with a PQ range. Absent VIDEO-RANGE means
        // SDR per HLS, so the I-frame variant must state PQ explicitly to
        // stay consistent with the PQ main variant.
        let provider = IFrameVODProvider(count: 3, codecs: "hvc1.2.4.L153.90",
                                         videoRange: .pq)
        let ls = lines(HLSLocalServer.buildMasterPlaylistText(provider: provider))

        guard let iframeLine = ls.first(where: { $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") }),
              let streamLine = ls.first(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) else {
            Issue.record("master missing STREAM-INF or I-FRAME-STREAM-INF line")
            return
        }
        #expect(iframeLine.contains("VIDEO-RANGE=PQ"))
        // The I-frame variant's range must match the main variant's.
        #expect(streamLine.contains("VIDEO-RANGE=PQ"))
    }

    @Test("no provider range means no VIDEO-RANGE on the I-frame line (implicit SDR, unchanged)")
    func iframeLineOmitsVideoRangeWhenNil() {
        // The default stub reports no masterVideoRange; the attribute is
        // simply absent (implicit SDR), exactly as before the fix.
        let provider = IFrameVODProvider(count: 3)
        let ls = lines(HLSLocalServer.buildMasterPlaylistText(provider: provider))
        let iframeLine = ls.first(where: { $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") })
        #expect(iframeLine != nil)
        #expect(iframeLine?.contains("VIDEO-RANGE") == false)
    }

    // MARK: - Part B3: skip the I-frame line for Dolby Vision (#158 review I2)

    @Test("a Dolby Vision (dvh1) master advertises NO I-frame line")
    func dolbyVisionMasterHasNoIFrameLine() {
        // DV Profile 5's video-only codec is dvh1.05.06; the P5 master must
        // return to its pre-#158 shape (no trick-play line).
        let provider = IFrameVODProvider(count: 3, codecs: "dvh1.05.06",
                                         videoRange: .pq)
        let master = HLSLocalServer.buildMasterPlaylistText(provider: provider)
        #expect(!master.contains("#EXT-X-I-FRAME-STREAM-INF"))
    }

    @Test("an hvc1 (DV 8.x / HDR base) master still advertises the I-frame line")
    func hvc1MasterKeepsIFrameLine() {
        // DV 8.x advertises a plain hvc1 video-only codec, so it is NOT
        // treated as DV here and keeps previews (only bare dvh1 is skipped).
        let provider = IFrameVODProvider(count: 3, codecs: "hvc1.2.4.L153.90",
                                         videoRange: .pq)
        let master = HLSLocalServer.buildMasterPlaylistText(provider: provider)
        #expect(master.contains("#EXT-X-I-FRAME-STREAM-INF"))
    }

    // MARK: - Part E: preview fetch is side-effect-free (#158 review C1)

    /// Records producer-restart callbacks so a test can assert a preview
    /// fetch never triggers one.
    private final class RestartSpy: @unchecked Sendable {
        var calls: [Int] = []
    }

    @Test("previewSegmentURL is a pure peek (no declareTarget / restart); mediaSegmentURL retargets")
    func previewSegmentURLIsSideEffectFree() {
        let cache = SegmentCache()
        // Seed segment 0 resident; segments 1..9 stay non-resident.
        cache.store(index: 0, data: Data([0x01, 0x02, 0x03, 0x04]))

        let spy = RestartSpy()
        let segments = (0..<10).map { i in
            HLSVideoEngine.Segment(startPts: 0, endPts: 0,
                                   startSeconds: Double(i) * 4.0,
                                   durationSeconds: 4.0)
        }
        let provider = VideoSegmentProvider(
            cache: cache,
            segments: segments,
            codecsString: "avc1.640029,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (1920, 1080),
            videoRange: .sdr,
            frameRate: nil,
            hdcpLevel: nil,
            sourceBitrate: 6_000_000,
            restartHandler: { spy.calls.append($0) })

        // No fetch has declared a cache target yet.
        #expect(cache.targetIndex == -1)

        // Preview of a RESIDENT segment: returns the file URL and drives NO
        // side effect — the cache target stays -1, the producer never
        // restarts. This is the C1 fix: a trick-play byte-range fetch must
        // not retarget the cache away from the play position.
        #expect(provider.previewSegmentURL(at: 0) != nil)
        #expect(cache.targetIndex == -1)
        #expect(spy.calls.isEmpty)

        // Preview of an in-bounds but NON-resident segment: graceful nil,
        // still no retarget / restart (the server turns this into a 404).
        #expect(provider.previewSegmentURL(at: 5) == nil)
        #expect(cache.targetIndex == -1)
        #expect(spy.calls.isEmpty)

        // Out-of-bounds preview: nil via the bounds guard, no side effect.
        #expect(provider.previewSegmentURL(at: 999) == nil)
        #expect(cache.targetIndex == -1)
        #expect(spy.calls.isEmpty)

        // CONTRAST — the playback path legitimately retargets: mediaSegmentURL
        // for the same resident segment declares the cache target (exactly the
        // side effect the preview path must avoid).
        #expect(provider.mediaSegmentURL(at: 0) != nil)
        #expect(cache.targetIndex == 0)
    }
}
