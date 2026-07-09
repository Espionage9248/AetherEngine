import Foundation
import AetherEngine

// MARK: - switchrepro (#187 diagnosis harness)

// Mirrors the tvOS host's same-engine episode advance: load source A on a
// full AetherEngine, let the producer + preview sweep spin for a while,
// then re-enter load() with source B and preserveDisplayCriteria set.
// Device capture showed the second session's pump dying on corrupt source
// reads (Invalid NAL / partial file → readFailed(-1)) while a cold load of
// the same source B is healthy; this reproduces the sequence headlessly.
func runSwitchRepro(urlA: URL, urlB: URL, dwellSeconds: Double) -> Never {
    EngineLog.handler = { line in
        let timestamp = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [.withTime, .withFractionalSeconds]
        )
        print("[\(timestamp)] \(line)")
    }

    print("aetherctl switchrepro: A=\(urlA.absoluteString) B=\(urlB.absoluteString) dwell=\(dwellSeconds)s")
    print("")

    Task { @MainActor in
        let engine: AetherEngine
        do {
            engine = try AetherEngine()
        } catch {
            print("ERROR: engine init failed: \(error)")
            exit(1)
        }
        do {
            _ = try await engine.load(url: urlA, options: LoadOptions())
            print(">>> SESSION A LOADED, dwelling \(dwellSeconds)s")
        } catch {
            print("ERROR: session A load failed: \(error)")
            exit(1)
        }
        try? await Task.sleep(for: .seconds(dwellSeconds))

        var opts = LoadOptions()
        opts.preserveDisplayCriteria = true
        do {
            print(">>> SWITCHING to B (preserveDisplayCriteria=true)")
            _ = try await engine.load(url: urlB, startPosition: nil, options: opts)
            print(">>> SESSION B LOADED, observing 20s")
        } catch {
            print("ERROR: session B load failed: \(error)")
            exit(2)
        }
        try? await Task.sleep(for: .seconds(20))
        print(">>> REPRO-DONE state=\(engine.state)")
        engine.stop()
        exit(0)
    }

    RunLoop.main.run()
    exit(0)
}
