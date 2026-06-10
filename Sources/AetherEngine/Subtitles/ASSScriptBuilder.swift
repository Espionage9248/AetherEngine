import Foundation

/// Reassembles a complete ASS script from the raw event lines the
/// engine emits with `LoadOptions.preserveASSMarkup` (AetherEngine#30).
///
/// libavcodec normalizes every ASS/SSA event to
/// `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`
/// WITHOUT timestamps; timing travels on the cue (`startTime` /
/// `endTime`, absolute source-PTS seconds). Whole-file renderers
/// (e.g. swift-ass-renderer's `loadTrack(content:)`) want a full
/// script with `Dialogue:` lines instead. This builder accumulates
/// events as they stream in from the paced side demuxer, dedupes
/// re-emits by CONTENT (line text + cue times), and renders
/// `header + Dialogue lines` on demand.
///
/// Dedupe is deliberately NOT keyed on ReadOrder: the spec says it is
/// unique per event, but real files ship with ReadOrder hardcoded to
/// 0 on every line (field repro: an anime MKV whose whole track
/// collapsed to one event under ReadOrder-keyed dedupe). The content
/// key still absorbs the engine's re-emits after seeks, which are
/// byte-identical.
///
/// Pure string assembly, no rendering, no UI: the engine stays
/// backend-only; hosts hand the script to whatever renderer they ship.
/// Not thread-safe; confine to one actor (hosts typically call it
/// from their MainActor cue sink).
public final class ASSScriptBuilder {

    private let header: String
    /// Synthesized Dialogue lines with their cue start (for ordering)
    /// and arrival sequence (stable tie-break).
    private var events: [(start: Double, seq: Int, line: String)] = []
    /// Content keys (`start|end|raw line`) of everything in `events`.
    private var seen: Set<String> = []

    public var eventCount: Int { events.count }

    /// `header` is the track's script header, i.e.
    /// `TrackInfo.assHeader` (`[Script Info]` + `[V4+ Styles]` +
    /// the `[Events]` Format line). NUL bytes are stripped: MKV
    /// CodecPrivate is frequently NUL-terminated, and libass parses
    /// C-string-style, so a single embedded NUL would make it ignore
    /// every line appended after the header (field repro: "2 styles,
    /// 0 events" for a script that visibly contained the events).
    public init(header: String) {
        self.header = header.replacingOccurrences(of: "\0", with: "")
    }

    /// Add one cue body. `rawEventText` is `SubtitleCue.body`'s text
    /// under `preserveASSMarkup`; it may contain SEVERAL raw event
    /// lines joined by newlines (one per packet rect). `start` / `end`
    /// are the cue's times in seconds. Returns true when at least one
    /// NEW event (unseen content) was added.
    @discardableResult
    public func add(rawEventText: String, start: Double, end: Double) -> Bool {
        var addedAny = false
        for line in rawEventText.split(separator: "\n", omittingEmptySubsequences: true) {
            // ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
            // The numeric-ReadOrder check validates the line SHAPE
            // (so plain text with many commas is rejected); the value
            // itself is untrustworthy and unused.
            let fields = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9, Int(fields[0]) != nil else { continue }
            let key = "\(start)|\(end)|\(line)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let layer = fields[1]
            let tail = fields[2...].joined(separator: ",")
            events.append((
                start: start,
                seq: events.count,
                line: "Dialogue: \(layer),\(Self.timestamp(start)),\(Self.timestamp(end)),\(tail)"
            ))
            addedAny = true
        }
        return addedAny
    }

    /// The full script: header, then all known events ordered by
    /// ReadOrder.
    ///
    /// MKV codec private data usually ends after the last `Style:`
    /// line WITHOUT an `[Events]` section (mkvmerge and friends strip
    /// it together with the events). Appending `Dialogue:` lines
    /// straight after such a header leaves them inside `[V4+ Styles]`
    /// and libass parses 0 events (field repro: "Added subtitle file:
    /// <memory> (2 styles, 0 events)"). Synthesize the section plus
    /// the standard Format line whenever the header lacks it.
    public func script() -> String {
        var lines = [header]
        lines.reserveCapacity(events.count + 2)
        if !header.contains("[Events]") {
            lines.append("""

            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            """)
        }
        let ordered = events.sorted {
            ($0.start, $0.seq) < ($1.start, $1.seq)
        }
        for event in ordered {
            lines.append(event.line)
        }
        return lines.joined(separator: "\n")
    }

    /// Drop all accumulated events. The header is PER-TRACK
    /// (`TrackInfo.assHeader` carries that track's `[V4+ Styles]`):
    /// on a subtitle track switch build a NEW instance with the new
    /// track's header instead of resetting this one, or the new
    /// track's events render against the old track's styles. reset()
    /// is for same-track re-feeds only.
    public func reset() {
        events.removeAll(keepingCapacity: true)
        seen.removeAll(keepingCapacity: true)
    }

    /// ASS timestamp `H:MM:SS.cc` (centiseconds). Negative input
    /// clamps to zero.
    public static func timestamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        var centis = Int((total * 100).rounded())
        let h = centis / 360_000
        centis %= 360_000
        let m = centis / 6_000
        centis %= 6_000
        let s = centis / 100
        centis %= 100
        return String(format: "%d:%02d:%02d.%02d", h, m, s, centis)
    }
}
