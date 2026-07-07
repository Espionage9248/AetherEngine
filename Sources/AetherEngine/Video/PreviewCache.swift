// Sources/AetherEngine/Video/PreviewCache.swift
import Foundation

/// Dedicated on-disk store for #158 v2 preview fragments. Fully separate
/// from SegmentCache — different directory tree (`aether-previews/` vs
/// `aether-segments/`), no windowing, no pruning: entries only accumulate
/// until `close()`. Thread-safe: the sweep writes while the HTTP server
/// reads. Session-scoped (tvOS tmpdir is cache-only — by design).
final class PreviewCache: @unchecked Sendable {
    private let lock = NSLock()
    private var indices: [Int] = []          // sorted ascending
    private var initBytes: Data?
    private var _totalBytes = 0
    private var closed = false
    let sessionDir: URL

    init() {
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("aether-previews", isDirectory: true)
        let sessionID = UUID().uuidString
        sessionDir = baseDir.appendingPathComponent(sessionID, isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDir,
                                                 withIntermediateDirectories: true)
        Self.sweepStaleSessionDirs(baseDir: baseDir, currentSession: sessionID)
    }

    /// Same crash-recovery discipline as SegmentCache.sweepStaleSessionDirs
    /// (SegmentCache.swift:142): sibling session dirs are leftovers from a
    /// previous (possibly crashed) run. Age-gated at 1 hour — a
    /// concurrently-live sibling session (stream switch, producer restart, or
    /// resume-seek each spin up a second engine session) is younger than the
    /// cutoff and is spared, so its live fragments are never deleted out from
    /// under the server. Only siblings older than the cutoff (or with no
    /// creation date) are removed.
    private static func sweepStaleSessionDirs(baseDir: URL, currentSession: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: baseDir,
                                                        includingPropertiesForKeys: [.creationDateKey],
                                                        options: [.skipsHiddenFiles]) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-3600)
        for entry in entries where entry.lastPathComponent != currentSession {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if created == nil || created! < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }

    func setInit(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        initBytes = data
    }

    func initData() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return initBytes
    }

    /// Rename a just-cut muxer staging file into its servable name.
    /// Same-volume rename (muxer sessionDir == cache sessionDir) → metadata-only.
    func adopt(stagingPath: URL, forIndex index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { try? FileManager.default.removeItem(at: stagingPath); return false }
        let dest = sessionDir.appendingPathComponent("preview-\(index).m4s")
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: stagingPath.path)[.size] as? Int) ?? 0
            try FileManager.default.moveItem(at: stagingPath, to: dest)
            let insertAt = indices.firstIndex { $0 > index } ?? indices.count
            indices.insert(index, at: insertAt)
            _totalBytes += size
            return true
        } catch {
            EngineLog.emit("[PreviewCache] adopt failed for \(index): \(error)", category: .session)
            return false
        }
    }

    /// Exact index only. nil when that index is not present (not yet swept, or
    /// never produced — cap-tail / skipped keyframe), or when empty/closed.
    func fileURL(exactly index: Int) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard !closed, indices.contains(index) else { return nil }
        return sessionDir.appendingPathComponent("preview-\(index).m4s")
    }

    var totalBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return _totalBytes
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        indices = []
        initBytes = nil
        try? FileManager.default.removeItem(at: sessionDir)
    }
}
