import Foundation

/// Pure cursor over successive refreshes of a live media playlist.
/// Feed it each freshly parsed playlist; it returns the segments to fetch,
/// in order, exactly once each. Handles the three live realities:
/// initial join (start near the live edge), normal forward growth, and the
/// provider window sliding past our cursor (rejoin at the edge, flagged as
/// a discontinuity so downstream timestamp rebase has a deterministic cue).
/// Policy notes: joins are bounded by DURATION, not segment count: at most
/// `edgeOffset` segments AND at most ~`maxJoinSeconds` of content (always
/// at least one segment). Joining on segment count alone burst up to 36s
/// of backlog on providers with long segments, which made the local live
/// playlist grow many times faster than real time and reliably tripped a
/// one-time AVPlayer pacing stall a few seconds into every direct session
/// (device repro 2026-06-11); the duration cap keeps the startup shape
/// close to the proven stall-free server-remux cushion (~8s). A rejoin
/// after a window slide resets `stallCount`; a playlist that SHRINKS
/// (spec-violating server) is indistinguishable from a stall and counts as
/// one, which is the desired pressure toward the stall budget.
struct HLSPlaylistTracker {
    /// Hard cap on how many segments behind the live edge to start.
    private let edgeOffset: Int
    /// Duration cap for the join backlog; the join takes the newest
    /// segments whose summed duration stays at or under this, minimum one.
    private let maxJoinSeconds: Double
    /// Next media-sequence number we have NOT yet returned. nil until primed.
    private(set) var nextSequence: Int?
    /// Consecutive refreshes that produced no new segment.
    private(set) var stallCount = 0

    init(edgeOffset: Int = 3, maxJoinSeconds: Double = 8) {
        self.edgeOffset = edgeOffset
        self.maxJoinSeconds = maxJoinSeconds
    }

    mutating func newSegments(in playlist: HLSMediaPlaylist) -> [HLSMediaSegment] {
        let windowStart = playlist.mediaSequence
        let windowEnd = playlist.mediaSequence + playlist.segments.count // exclusive

        func segments(from sequence: Int, markFirstDiscontinuity: Bool) -> [HLSMediaSegment] {
            let startIndex = sequence - windowStart
            guard startIndex < playlist.segments.count else { return [] }
            var result = Array(playlist.segments[max(0, startIndex)...])
            if markFirstDiscontinuity, !result.isEmpty {
                let first = result[0]
                result[0] = HLSMediaSegment(
                    uri: first.uri, duration: first.duration, discontinuityBefore: true
                )
            }
            return result
        }

        /// Join sequence: walk back from the live edge, taking the newest
        /// segments while both caps hold (count < edgeOffset, summed
        /// duration <= maxJoinSeconds). Always at least one segment.
        func joinStart() -> Int {
            var taken = 0
            var seconds = 0.0
            for segment in playlist.segments.reversed() {
                if taken >= edgeOffset { break }
                if taken > 0, seconds + segment.duration > maxJoinSeconds { break }
                taken += 1
                seconds += segment.duration
            }
            return windowEnd - taken
        }

        guard let cursor = nextSequence else {
            // Initial join near the live edge, duration-capped.
            nextSequence = windowEnd
            return segments(from: joinStart(), markFirstDiscontinuity: false)
        }

        if cursor < windowStart {
            // Window slid past us: rejoin near the edge, mark the seam.
            nextSequence = windowEnd
            stallCount = 0
            return segments(from: joinStart(), markFirstDiscontinuity: true)
        }

        let fresh = segments(from: cursor, markFirstDiscontinuity: false)
        if fresh.isEmpty {
            stallCount += 1
        } else {
            stallCount = 0
            nextSequence = windowEnd
        }
        return fresh
    }
}
