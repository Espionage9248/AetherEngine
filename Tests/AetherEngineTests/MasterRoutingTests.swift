// Tests/AetherEngineTests/MasterRoutingTests.swift
//
// Table tests for `HLSVideoEngine.routesAtMasterPlaylist`, the pure
// master-vs-media playlist routing decision extracted from `start()`
// (AetherEngine#187). `true` = serve the master playlist (HDR/DV
// signaling and the #158 I-frame trick-play stream reach AVPlayer);
// `false` = the media-playlist auto-tonemap path. The socket wiring and
// the empirical panel read that feeds `panelReadyForHDR` are
// device-verified; this covers only the branch logic.
import Testing
@testable import AetherEngine

@Suite("Master routing decision")
struct MasterRoutingTests {

    struct Case: Sendable {
        let name: String
        let videoRange: HLSVideoRange
        let dvVariant: HLSVideoEngine.DVVariant
        let effectiveDvMode: Bool
        let panelReadyForHDR: Bool
        let advertisesIFrameStream: Bool
        let expected: Bool
    }

    private static let cases: [Case] = [
        // #187 regression: a plain SDR source that advertises the I-frame
        // stream must route at the master even on a DV-capable system whose
        // panel currently reads SDR. The old `sourceIsHDR = ... ||
        // effectiveDvMode` dragged it into the panel-gated branch and
        // demoted it to media.m3u8 (no I-frame stream → previews absent).
        Case(name: "SDR + iframe advertised → master (regression case)",
             videoRange: .sdr, dvVariant: .none, effectiveDvMode: true,
             panelReadyForHDR: false, advertisesIFrameStream: true, expected: true),
        Case(name: "SDR + no iframe stream → media",
             videoRange: .sdr, dvVariant: .none, effectiveDvMode: true,
             panelReadyForHDR: false, advertisesIFrameStream: false, expected: false),
        // A genuine HDR source is panel-gated regardless of the I-frame line.
        Case(name: "HDR (PQ) + panel ready → master",
             videoRange: .pq, dvVariant: .none, effectiveDvMode: false,
             panelReadyForHDR: true, advertisesIFrameStream: false, expected: true),
        Case(name: "HDR (PQ) + panel not ready → media",
             videoRange: .pq, dvVariant: .none, effectiveDvMode: false,
             panelReadyForHDR: false, advertisesIFrameStream: true, expected: false),
        Case(name: "HDR (HLG) + panel ready → master",
             videoRange: .hlg, dvVariant: .none, effectiveDvMode: false,
             panelReadyForHDR: true, advertisesIFrameStream: false, expected: true),
        // DV Profile 5 on a non-DV panel (`!effectiveDvMode`) → media
        // regardless of the panel read: the dvh1 master trips AVPlayer's
        // strict master-level codec filter.
        Case(name: "DV P5 + non-DV panel, panel ready → media",
             videoRange: .pq, dvVariant: .profile5, effectiveDvMode: false,
             panelReadyForHDR: true, advertisesIFrameStream: true, expected: false),
        Case(name: "DV P5 + non-DV panel, panel not ready → media",
             videoRange: .pq, dvVariant: .profile5, effectiveDvMode: false,
             panelReadyForHDR: false, advertisesIFrameStream: false, expected: false),
        // A DV bitstream (any non-P5 profile) whose master carries an
        // SDR-tagged VIDEO-RANGE still routes through the HDR branch via
        // `dvVariant != .none`, so it stays panel-gated — the master's DV
        // attributes need the panel mode.
        Case(name: "DV 8.1 with SDR range + panel ready → master (panel-gated)",
             videoRange: .sdr, dvVariant: .profile81, effectiveDvMode: false,
             panelReadyForHDR: true, advertisesIFrameStream: false, expected: true),
        Case(name: "DV 8.1 with SDR range + panel not ready → media (panel-gated)",
             videoRange: .sdr, dvVariant: .profile81, effectiveDvMode: false,
             panelReadyForHDR: false, advertisesIFrameStream: true, expected: false),
    ]

    @Test("routesAtMasterPlaylist reproduces the start() routing contract",
          arguments: MasterRoutingTests.cases)
    func routingContract(_ c: Case) {
        let result = HLSVideoEngine.routesAtMasterPlaylist(
            videoRange: c.videoRange,
            dvVariant: c.dvVariant,
            effectiveDvMode: c.effectiveDvMode,
            panelReadyForHDR: c.panelReadyForHDR,
            advertisesIFrameStream: c.advertisesIFrameStream
        )
        #expect(result == c.expected, "\(c.name)")
    }
}
