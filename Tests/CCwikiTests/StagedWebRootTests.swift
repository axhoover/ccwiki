import Foundation
import Testing
@testable import CCwiki

/// The reader's web pipeline is served from a per-build copy in Caches. A
/// launch must not delete the copy another running CCwiki is serving from:
/// only copies no launch has touched for a week go.
struct StagedWebRootTests {

    private static let day: TimeInterval = 24 * 60 * 60

    @Test("only other builds' copies untouched since the cutoff are pruned")
    func pruning() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-web-prune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let monthAgo = now.addingTimeInterval(-30 * Self.day)
        let entries: [(name: String, modified: Date)] = [
            ("202610010000", monthAgo),          // this build, however old
            ("202609010000", monthAgo),          // another build, unused for a month
            ("202610100000", now.addingTimeInterval(-3600)),  // another, in use an hour ago
            ("202609010000.partial", monthAgo),  // a copy that never finished
        ]
        for entry in entries {
            try Self.makeCopy(at: root.appending(path: entry.name), modified: entry.modified)
        }

        AppPaths.pruneStagedWebCopies(
            in: root, keeping: "202610010000",
            olderThan: now.addingTimeInterval(-AppPaths.stagedWebRetention))

        let left = try FileManager.default.contentsOfDirectory(
            atPath: root.path(percentEncoded: false)).sorted()
        #expect(left == ["202610010000", "202610100000"])
    }

    @Test("a missing directory is nothing to prune")
    func missingRoot() {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-web-missing-\(UUID().uuidString)")
        AppPaths.pruneStagedWebCopies(in: root, keeping: "1", olderThan: Date())
        #expect(!FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
    }

    @Test("a launch serves its build's copy, marks it in use, and prunes only stale ones")
    func launchTouchesItsCopy() throws {
        let support = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-web-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let web = support.appending(path: "web-builds")
        let monthAgo = Date().addingTimeInterval(-30 * Self.day)
        let mine = web.appending(path: AppPaths.stagedWebBuild)
        let running = web.appending(path: "another-running-build")
        let stale = web.appending(path: "a-stale-build")
        try Self.makeCopy(at: mine, modified: monthAgo)
        try Self.makeCopy(at: running, modified: Date())
        try Self.makeCopy(at: stale, modified: monthAgo)

        let served = AppPaths(support: support).stagedWebRoot()

        #expect(served.path(percentEncoded: false) == mine.path(percentEncoded: false))
        let touched = try #require(try Self.modificationDate(of: mine))
        #expect(touched > Date().addingTimeInterval(-Self.day), "its date says it is in use")
        #expect(FileManager.default.fileExists(atPath: running.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: stale.path(percentEncoded: false)))
    }

    // MARK: Helpers

    /// A stand-in for a staged copy: a directory with an `index.html`, dated
    /// `modified`. The date is set last, since adding the file changes it.
    private static func makeCopy(at directory: URL, modified: Date) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("<!doctype html>".utf8).write(to: directory.appending(path: "index.html"))
        try FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: directory.path(percentEncoded: false))
    }

    private static func modificationDate(of url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false))[.modificationDate] as? Date
    }
}
