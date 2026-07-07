// Sources/AetherEngine/Video/PreviewTrackProvider.swift
import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// #158 v2: playback-decoupled background sweep that produces one
/// single-sample fMP4 preview fragment per plan segment into a dedicated
/// PreviewCache, for the whole-file #EXT-X-I-FRAMES-ONLY playlist.
///
/// Fully separate from playback by construction: own Demuxer
/// (`.stillExtraction`, video-only, keyframe-only), own MP4SegmentMuxer,
/// own cache directory. Serving is a pure PreviewCache read — it can never
/// declareTarget, extend the playback window, or restart the producer (C1).
///
/// Timeline: fragments are stamped `source pts − firstKeyframePts`, the same
/// media-timeline convention the playback producer uses for its tfdt, so the
/// preview track maps onto the exact positions the playback segments occupy.
/// Conforms to `PreviewFragmentSource`: its serving members are pure
/// PreviewCache reads (below), which the whole-file I-frames-only playlist
/// route consumes.
final class PreviewTrackProvider: PreviewFragmentSource, @unchecked Sendable {
    private let sourceURL: URL
    private let httpHeaders: [String: String]
    private let plan: [HLSVideoEngine.Segment]
    private let firstKeyframePts: Int64
    private let cache = PreviewCache()
    /// Deep-copied at init so the provider never dangles into the playback
    /// demuxer's stream (the engine frees its saved video config on stop, and
    /// producer restarts reopen streams). Freed in deinit.
    private var ownedCodecpar: UnsafeMutablePointer<AVCodecParameters>?
    private let videoTimeBase: AVRational
    private let codecTagOverride: String?
    private let stripDolbyVisionMetadata: Bool
    private let colorOverride: MP4SegmentMuxer.ColorOverride?
    private let extradataOverride: [UInt8]?

    private let sweepQueue = DispatchQueue(label: "com.aetherengine.previewsweep", qos: .utility)
    private let stateLock = NSLock()
    private var cancelled = false
    private var demuxer: Demuxer?
    private var shutDown = false

    /// ~500 MB hard cap (spec): sweep stops and logs; slots past the cap simply 404 (no thumbnail).
    private static let cacheByteCap = 500 * 1024 * 1024

    init(sourceURL: URL, httpHeaders: [String: String],
         plan: [HLSVideoEngine.Segment], firstKeyframePts: Int64,
         videoConfig: HLSSegmentProducer.StreamConfig) {
        self.sourceURL = sourceURL
        self.httpHeaders = httpHeaders
        self.plan = plan
        self.firstKeyframePts = firstKeyframePts
        self.videoTimeBase = videoConfig.timeBase
        self.codecTagOverride = videoConfig.codecTagOverride
        self.stripDolbyVisionMetadata = videoConfig.stripDolbyVisionMetadata
        self.colorOverride = videoConfig.colorOverride
        self.extradataOverride = videoConfig.extradataOverride
        if let owned = avcodec_parameters_alloc() {
            if avcodec_parameters_copy(owned, videoConfig.codecpar) >= 0 {
                self.ownedCodecpar = owned
            } else {
                var o: UnsafeMutablePointer<AVCodecParameters>? = owned
                avcodec_parameters_free(&o)
            }
        }
    }

    deinit {
        var o = ownedCodecpar
        if o != nil { avcodec_parameters_free(&o) }
    }

    // MARK: - Lifecycle

    func start() {
        sweepQueue.async { [weak self] in self?.sweep() }
    }

    /// Test hook: run the whole sweep on the calling thread.
    func runSweepSynchronously() { sweep() }

    /// Prompt teardown: flip the cancel flag, unblock a parked read, then
    /// close the cache so serving goes dead immediately. `PreviewCache.close`
    /// is a cheap session-dir removal + in-memory reset, so it runs inline;
    /// it's thread-safe against a still-running background sweep (the sweep
    /// sees `isCancelled` and unwinds, and any late `adopt`/`setInit` no-ops
    /// against the closed cache).
    func shutdown() {
        stateLock.lock()
        guard !shutDown else { stateLock.unlock(); return }
        shutDown = true
        cancelled = true
        let d = demuxer
        stateLock.unlock()
        d?.markClosed()
        cache.close()
    }

    private var isCancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return cancelled
    }

    // MARK: - Serving (pure cache reads — C1)

    func previewInitData() -> Data? { cache.initData() }
    func previewFragmentURL(forIndex index: Int) -> URL? { cache.fileURL(exactly: index) }

    // MARK: - Sweep

    private func sweep() {
        guard !plan.isEmpty, let codecpar = ownedCodecpar else { return }
        let d = Demuxer()
        do { try d.open(url: sourceURL, extraHeaders: httpHeaders, profile: .stillExtraction) }
        catch {
            EngineLog.emit("[PreviewSweep] demux open failed — previews absent: \(error)",
                           category: .session)
            return
        }
        stateLock.lock(); demuxer = d; stateLock.unlock()
        defer {
            d.close()
            stateLock.lock(); demuxer = nil; stateLock.unlock()
        }
        let vIdx = d.videoStreamIndex
        guard vIdx >= 0 else {
            EngineLog.emit("[PreviewSweep] no video stream — previews absent", category: .session)
            return
        }
        d.discardAllStreamsExcept([vIdx])
        d.discardNonKeyPackets(streamIndex: vIdx)

        let muxer: MP4SegmentMuxer
        do {
            muxer = try MP4SegmentMuxer(
                initialSegmentIndex: 0,
                sessionDir: cache.sessionDir,
                video: .init(codecpar: UnsafePointer(codecpar),
                             timeBase: videoTimeBase,
                             codecTagOverride: codecTagOverride,
                             stripDolbyVisionMetadata: stripDolbyVisionMetadata,
                             colorOverride: colorOverride,
                             extradataOverride: extradataOverride),
                audio: nil,
                onInitCaptured: { [cache] bytes in cache.setInit(bytes) })
        } catch {
            EngineLog.emit("[PreviewSweep] muxer init failed — previews absent: \(error)",
                           category: .session)
            return
        }

        let tbSec = Double(videoTimeBase.num) / Double(videoTimeBase.den)
        // Fallback span for a degenerate zero-length plan segment.
        let fallbackDurationTicks = tbSec > 0 ? Int64(max(1.0, (1.0 / 25.0) / tbSec)) : 1
        var produced = 0
        let sweepStart = Date()

        segmentLoop: for (i, seg) in plan.enumerated() {
            if isCancelled { break }
            if cache.totalBytes >= Self.cacheByteCap {
                EngineLog.emit("[PreviewSweep] byte cap reached at seg \(i)/\(plan.count) — " +
                               "stopping; slots past the cap will 404 (no thumbnail)", category: .session)
                break
            }
            // Seek in the SOURCE PTS domain (startPts is a raw stream timestamp;
            // startSeconds is first-keyframe-relative and must NOT be used here).
            // The seek lands at/BEFORE the target; the scan-forward gate below
            // advances to the first keyframe at/after the segment start.
            d.seek(to: Double(seg.startPts) * tbSec)
            // Two independent stamps position + size each single-sample moof:
            //  1. tfdt (baseMediaDecodeTime) is derived by the mp4 fragmenter
            //     from the packet DTS we set below (dts −= firstKeyframePts,
            //     then rescale to the muxer timebase). So fragment i lands at
            //     media time seg[i].startPts − firstKeyframePts — the SAME
            //     convention the playback producer uses for its segment tfdt, so
            //     previews and media segments share one timeline (a scrub maps a
            //     thumbnail to the right playhead position).
            //  2. the segment span below sets the sample's duration → the
            //     fragment's declared length (its EXTINF, "lasts until the next
            //     I-frame") and guarantees a positive trun.sample_duration even
            //     when the source packet reports 0.
            let spanTicks = seg.endPts - seg.startPts
            let sampleDurationTicks = spanTicks > 0 ? spanTicks : fallbackDurationTicks
            packetLoop: while !isCancelled {
                let pktOrNil: UnsafeMutablePointer<AVPacket>?
                do { pktOrNil = try d.readPacket() }
                catch {
                    EngineLog.emit("[PreviewSweep] read error at seg \(i), skipping: \(error)",
                                   category: .session)
                    break packetLoop
                }
                guard let pkt = pktOrNil else { break segmentLoop }        // EOF
                var consumed = false
                defer { if !consumed { av_packet_unref(pkt); av_packet_free_safe(pkt) } }
                if pkt.pointee.stream_index != vIdx { continue }
                // Scan-forward gate: skip keyframes before the segment start.
                if pkt.pointee.pts != Int64.min, pkt.pointee.pts < seg.startPts { continue }
                // Media-timeline rebase (producer convention); stamp the
                // segment-span duration computed above.
                if pkt.pointee.pts != Int64.min { pkt.pointee.pts -= firstKeyframePts }
                pkt.pointee.dts = pkt.pointee.dts == Int64.min
                    ? pkt.pointee.pts
                    : pkt.pointee.dts - firstKeyframePts
                pkt.pointee.duration = sampleDurationTicks
                // The muxer's video output stream is index 0; the source video
                // stream may not be, so retarget before av_interleaved_write_frame.
                pkt.pointee.stream_index = muxer.videoOutputStreamIndex
                // Rescale the finished SOURCE-tick pts/dts/duration into the
                // muxer's output timescale, which the mp4 muxer auto-picks and
                // latches from the output stream AFTER avformat_write_header
                // (MP4SegmentMuxer.muxerVideoTimeBase — usually NOT the source's,
                // e.g. 1/16000 for 24fps). writePacket's contract requires the
                // caller to do this; mirrors the production video pump
                // (HLSSegmentProducer.swift:2629). Rebase + span are computed in
                // source ticks above, so rescale is the LAST step. Without it a
                // source whose video timescale differs from the muxer's pick
                // (e.g. matroska 1/1000) lands every fragment at the wrong media
                // time and AVKit misplaces every thumbnail.
                av_packet_rescale_ts(pkt, videoTimeBase, muxer.muxerVideoTimeBase)
                let ret = muxer.writePacket(pkt)   // consumes/unrefs the packet's ref
                consumed = true
                av_packet_unref(pkt); av_packet_free_safe(pkt)
                if ret < 0 {
                    EngineLog.emit("[PreviewSweep] write failed at seg \(i) (\(ret)), skipping",
                                   category: .session)
                    break packetLoop
                }
                // Cut the just-written keyframe as segment `i`'s fragment and
                // rotate the muxer to the next staging file. Adopt from the cut
                // only — never from finalize() (see below).
                if let cut = muxer.cutFragmentForNextSegment(i + 1) {
                    if cache.adopt(stagingPath: cut.path, forIndex: i) { produced += 1 }
                }
                break packetLoop
            }
        }
        // Every produced segment was cut + adopted inside the loop, so the
        // muxer's current staging file here is the empty trailing one it
        // rotated to after the last cut. finalize() is therefore pure
        // flush + trailer + fd close: its own zero-byte guard removes that
        // empty file and returns nil, so there is nothing to adopt (adopting
        // it would double-count the last plan segment).
        _ = muxer.finalize()
        EngineLog.emit("[PreviewSweep] done: \(produced)/\(plan.count) fragments, " +
                       "\(cache.totalBytes / 1024) KiB in " +
                       "\(String(format: "%.1f", Date().timeIntervalSince(sweepStart)))s",
                       category: .session)
    }
}
