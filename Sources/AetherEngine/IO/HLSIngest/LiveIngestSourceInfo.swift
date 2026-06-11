import Foundation

/// Implemented by custom live readers that know their upstream's
/// segment cadence; the engine uses it to shape the local playlist
/// (TARGETDURATION floor, blocking-reload eligibility) so AVPlayer's
/// timing model matches the real arrival pattern.
protocol LiveIngestSourceInfo: AnyObject {
    /// The upstream media playlist's EXT-X-TARGETDURATION in seconds,
    /// once known (after the resolver fetched the playlist). nil before.
    var upstreamTargetDuration: Double? { get }
}
