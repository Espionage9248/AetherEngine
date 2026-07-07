// Tests/AetherEngineTests/PreviewCacheTests.swift
import Testing
import Foundation
@testable import AetherEngine

@Suite("PreviewCache")
struct PreviewCacheTests {
    private func makeStaging(_ cache: PreviewCache, bytes: Int = 16) throws -> URL {
        let staging = cache.sessionDir.appendingPathComponent("staging-\(UUID().uuidString)")
        try Data(repeating: 0x5A, count: bytes).write(to: staging)
        return staging
    }

    @Test func adoptAndExactLookup() throws {
        let cache = PreviewCache(); defer { cache.close() }
        #expect(cache.fileURL(exactly: 3) == nil)                      // empty → nil
        #expect(cache.adopt(stagingPath: try makeStaging(cache), forIndex: 3))
        let url = cache.fileURL(exactly: 3)
        #expect(url?.lastPathComponent == "preview-3.m4s")
        #expect(FileManager.default.fileExists(atPath: url!.path))
    }

    @Test func unsweptIndexReturnsNil() throws {
        let cache = PreviewCache(); defer { cache.close() }
        _ = cache.adopt(stagingPath: try makeStaging(cache), forIndex: 10)
        _ = cache.adopt(stagingPath: try makeStaging(cache), forIndex: 20)
        #expect(cache.fileURL(exactly: 10)?.lastPathComponent == "preview-10.m4s") // exact hit still works
        #expect(cache.fileURL(exactly: 15) == nil)   // in-between, not yet swept → nil (was nearest)
        #expect(cache.fileURL(exactly: 500) == nil)  // past the tail (cap/skip) → nil (was nearest)
        #expect(cache.fileURL(exactly: 5) == nil)    // before the first present index → nil
    }

    @Test func totalBytesAccumulates() throws {
        let cache = PreviewCache(); defer { cache.close() }
        _ = cache.adopt(stagingPath: try makeStaging(cache, bytes: 100), forIndex: 0)
        _ = cache.adopt(stagingPath: try makeStaging(cache, bytes: 50), forIndex: 1)
        #expect(cache.totalBytes == 150)
    }

    @Test func initRoundTrip() throws {
        let cache = PreviewCache(); defer { cache.close() }
        #expect(cache.initData() == nil)
        cache.setInit(Data([0x66, 0x74, 0x79, 0x70]))
        #expect(cache.initData() == Data([0x66, 0x74, 0x79, 0x70]))
    }

    @Test func closeRemovesSessionDir() throws {
        let cache = PreviewCache()
        _ = cache.adopt(stagingPath: try makeStaging(cache), forIndex: 0)
        let dir = cache.sessionDir
        cache.close()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(cache.fileURL(exactly: 0) == nil)
    }
}
