import Testing
import Foundation
@testable import AetherEngine

@Suite("Standalone subtitle reader")
@MainActor
struct StandaloneSubtitleReaderTests {

    @Test("Start flips subtitle state on without a load()")
    func startSetsState() throws {
        let e = try AetherEngine()
        e.startStandaloneEmbeddedSubtitleReader(
            url: URL(fileURLWithPath: "/nonexistent.mkv"), streamIndex: 2, startAt: 0)
        #expect(e.isSubtitleActive)
        #expect(e.subtitleCues.isEmpty)
        #expect(e.activeEmbeddedSubtitleStreamIndex == 2)
        e.clearSubtitle()
        #expect(!e.isSubtitleActive)
    }
}
