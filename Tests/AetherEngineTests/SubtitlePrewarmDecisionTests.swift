import Testing
@testable import AetherEngine

@Suite("Subtitle prewarm decision")
struct SubtitlePrewarmDecisionTests {

    @Test("Positive duration without a skip hint prewarms")
    func prewarmsWithDuration() {
        #expect(AetherEngine.shouldPrewarmSubtitleCueTable(durationSeconds: 5621, skipPrewarmHint: false))
    }

    @Test("Zero, negative, or NaN duration never prewarms (no-Cues class reads dur=0)")
    func zeroDurationSkips() {
        #expect(!AetherEngine.shouldPrewarmSubtitleCueTable(durationSeconds: 0, skipPrewarmHint: false))
        #expect(!AetherEngine.shouldPrewarmSubtitleCueTable(durationSeconds: -1, skipPrewarmHint: false))
        #expect(!AetherEngine.shouldPrewarmSubtitleCueTable(durationSeconds: .nan, skipPrewarmHint: false))
    }

    @Test("Caller hint forces the skip even when a duration is advertised")
    func hintForcesSkip() {
        #expect(!AetherEngine.shouldPrewarmSubtitleCueTable(durationSeconds: 5621, skipPrewarmHint: true))
    }
}
