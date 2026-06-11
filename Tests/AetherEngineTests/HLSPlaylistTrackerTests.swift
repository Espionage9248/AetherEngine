import XCTest
@testable import AetherEngine

final class HLSPlaylistTrackerTests: XCTestCase {

    private func playlist(sequence: Int, uris: [String], duration: Double = 4) -> HLSMediaPlaylist {
        HLSMediaPlaylist(
            targetDuration: duration,
            mediaSequence: sequence,
            segments: uris.map { HLSMediaSegment(uri: $0, duration: duration, discontinuityBefore: false) },
            hasEndList: false,
            isEncrypted: false,
            hasMap: false
        )
    }

    func testPrimesAtLiveEdgeWithDurationCap() {
        // 4s segments, 8s cap: two segments fit, the third would exceed.
        var tracker = HLSPlaylistTracker(edgeOffset: 3, maxJoinSeconds: 8)
        let new = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c", "d", "e", "f"]))
        XCTAssertEqual(new.map(\.uri), ["e", "f"])
        XCTAssertEqual(tracker.stallCount, 0)
    }

    func testPrimeRespectsSegmentCountCapWhenDurationAllowsMore() {
        // Tiny 1s segments: the duration cap would allow 8, edgeOffset caps at 3.
        var tracker = HLSPlaylistTracker(edgeOffset: 3, maxJoinSeconds: 8)
        let new = tracker.newSegments(in: playlist(sequence: 0, uris: ["a", "b", "c", "d", "e", "f"], duration: 1))
        XCTAssertEqual(new.map(\.uri), ["d", "e", "f"])
    }

    func testPrimeTakesSingleLongSegment() {
        // 12s segments exceed the cap on their own: still take exactly one.
        var tracker = HLSPlaylistTracker(edgeOffset: 3, maxJoinSeconds: 8)
        let new = tracker.newSegments(in: playlist(sequence: 50, uris: ["a", "b", "c"], duration: 12))
        XCTAssertEqual(new.map(\.uri), ["c"])
    }

    func testPrimesAtWindowStartWhenWindowIsShort() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3, maxJoinSeconds: 8)
        let new = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b"]))
        XCTAssertEqual(new.map(\.uri), ["a", "b"])
    }

    func testReturnsOnlyNewSegmentsOnRefresh() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3, maxJoinSeconds: 8)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        let new = tracker.newSegments(in: playlist(sequence: 101, uris: ["b", "c", "d"]))
        XCTAssertEqual(new.map(\.uri), ["d"])
    }

    func testCountsStallsAndResets() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3, maxJoinSeconds: 8)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        XCTAssertEqual(tracker.stallCount, 1)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        XCTAssertEqual(tracker.stallCount, 2)
        _ = tracker.newSegments(in: playlist(sequence: 101, uris: ["b", "c", "d"]))
        XCTAssertEqual(tracker.stallCount, 0)
    }

    func testWindowSlidePastCursorRejoinsAtEdgeWithDiscontinuity() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3, maxJoinSeconds: 8)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        // Provider window slid far past our cursor: rejoin at the edge
        // (duration-capped to two 4s segments).
        let new = tracker.newSegments(in: playlist(sequence: 500, uris: ["x", "y", "z", "w", "v", "u"]))
        XCTAssertEqual(new.map(\.uri), ["v", "u"])
        XCTAssertTrue(new[0].discontinuityBefore, "rejoin must be marked as a discontinuity")
    }
}
