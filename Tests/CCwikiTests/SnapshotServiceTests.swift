import Foundation
import Testing
@testable import CCwiki

/// The reader's no-git path, minus the network.
struct SnapshotServiceTests {

    @Test("the marker round-trips through the file it is kept in")
    func marker() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-snapshot-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(SnapshotService.marker(in: root) == nil, "no marker, not a snapshot")
        let written = SnapshotService.Marker(
            sha: "75f254251cd77489c40df4e664b9ccf4521b976a",
            commitDate: Date(timeIntervalSince1970: 1_756_000_000),
            fetchedAt: Date(timeIntervalSince1970: 1_756_100_000))
        try SnapshotService.write(written, in: root)
        #expect(SnapshotService.marker(in: root) == written)
    }

    @Test("the branch API's answer yields the sha and the committer date")
    func head() throws {
        let json = """
            {"name": "main",
             "commit": {"sha": "abc123",
                        "commit": {"committer": {"name": "x", "date": "2026-08-24T10:11:12Z"}}}}
            """
        let head = try SnapshotService.head(from: Data(json.utf8))
        #expect(head.sha == "abc123")
        #expect(head.date == ISO8601DateFormatter().date(from: "2026-08-24T10:11:12Z"))

        let bare = try SnapshotService.head(from: Data(#"{"commit": {"sha": "def"}}"#.utf8))
        #expect(bare.sha == "def")
        #expect(bare.date == nil)

        #expect(throws: (any Error).self) {
            try SnapshotService.head(from: Data("nope".utf8))
        }
    }

    @Test("a tarball unpacks to exactly one directory, which is the snapshot")
    func unpackedRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-unpack-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appending(path: "cryptology.city-abc123")
        try FileManager.default.createDirectory(
            at: repo.appending(path: "content"), withIntermediateDirectories: true)
        // A stray file beside it does not count; a second directory does.
        try Data().write(to: root.appending(path: "pax_global_header"))
        // Compare names, not URLs: a directory listing yields URLs with a
        // trailing slash and the resolved /private/var form of the temp dir.
        #expect(try SnapshotService.unpackedRoot(in: root).lastPathComponent == repo.lastPathComponent)

        try FileManager.default.createDirectory(
            at: root.appending(path: "another"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try SnapshotService.unpackedRoot(in: root) }
    }

    @Test("only a network error is an outage")
    func networkErrors() {
        #expect(SnapshotService.isNetworkFailure(URLError(.notConnectedToInternet)))
        #expect(SnapshotService.isNetworkFailure(URLError(.timedOut)))
        #expect(!SnapshotService.isNetworkFailure(URLError(.badServerResponse)))
        #expect(!SnapshotService.isNetworkFailure(SnapshotService.Failure.badStatus(403)))
    }
}
