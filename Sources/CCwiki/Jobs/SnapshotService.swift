import Foundation

/// The wiki without git: a tarball of the branch head from GitHub, unpacked
/// with the `tar` every Mac ships in its base system.
///
/// This is what makes reading need nothing installed. A Mac without Apple's
/// Command Line Tools has no working `git`, and asking a reader to download
/// them to read a wiki was the audit's first finding. The snapshot is a plain
/// directory with the same layout as a clone (`content/`, `macros.ts`,
/// `.reductions/`), plus a marker file recording which commit it is, so the
/// rest of the app reads it exactly as it reads a clone.
///
/// Ingestion jobs still need real git: they add worktrees to a clone. When
/// git appears later, the next sync replaces the snapshot with a clone.
struct SnapshotService: Sendable {

    static let markerName = ".ccwiki-snapshot"

    /// What the snapshot is. Written last, so a directory without one is not
    /// a snapshot.
    struct Marker: Codable, Equatable, Sendable {
        let sha: String
        let commitDate: Date?
        let fetchedAt: Date
    }

    struct Head: Equatable, Sendable {
        let sha: String
        let date: Date?
    }

    enum Failure: LocalizedError {
        case badURL
        case badStatus(Int)
        case badPayload
        case unpack(String)
        case noRoot

        var errorDescription: String? {
            switch self {
            case .badURL: "The download URL is malformed."
            case .badStatus(let code): "GitHub answered \(code)."
            case .badPayload: "GitHub's answer could not be read."
            case .unpack(let why): "The archive could not be unpacked: \(why)"
            case .noRoot: "The archive did not contain the repository."
            }
        }
    }

    let repository: String
    let branch: String
    var session: URLSession = .shared

    // MARK: Marker

    static func marker(in directory: URL) -> Marker? {
        guard let data = try? Data(contentsOf: directory.appending(path: markerName)) else {
            return nil
        }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    static func write(_ marker: Marker, in directory: URL) throws {
        let data = try JSONEncoder().encode(marker)
        try data.write(to: directory.appending(path: markerName), options: .atomic)
    }

    // MARK: The branch head

    /// The commit the branch points at, from GitHub's REST API. One
    /// unauthenticated request; the limit is 60 an hour per address.
    func remoteHead() async throws -> Head {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/branches/\(branch)")
        else { throw Failure.badURL }
        let (data, status) = try await GitHubHTTP.get(url, timeout: 20, session: session)
        guard status == 200 else { throw Failure.badStatus(status) }
        return try Self.head(from: data)
    }

    /// The fields used from `GET /repos/{owner}/{repo}/branches/{branch}`.
    static func head(from data: Data) throws -> Head {
        struct Committer: Decodable { let date: String? }
        struct Details: Decodable { let committer: Committer? }
        struct Commit: Decodable { let sha: String; let commit: Details? }
        struct Payload: Decodable { let commit: Commit }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw Failure.badPayload
        }
        let date = payload.commit.commit?.committer?.date.flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        return Head(sha: payload.commit.sha, date: date)
    }

    // MARK: Sync

    /// Fetch the branch head as a snapshot at `destination`, replacing what
    /// is there. Same outcomes as `GitService.sync`, so the model treats the
    /// two alike.
    func sync(destination: URL, onLine: @Sendable (ProcessLine) -> Void) async
        -> GitService.SyncOutcome {
        func say(_ text: String) {
            onLine(ProcessLine(stream: .stdout, text: text, isProgress: false))
        }
        let existing = Self.marker(in: destination)

        say("Asking GitHub for the head of \(repository)@\(branch)…")
        let head: Head
        do {
            head = try await remoteHead()
        } catch {
            say("Failed: \(error.localizedDescription)")
            if Self.isNetworkFailure(error) {
                return existing == nil
                    ? .failed("Could not reach GitHub to download the wiki. Check your "
                        + "connection and sync again.")
                    : .offline
            }
            return .failed("Could not read the wiki's branch head: \(error.localizedDescription)")
        }
        if let existing, existing.sha == head.sha {
            say("Already at \(head.sha.prefix(7)).")
            return .alreadyCurrent(at: head.sha)
        }

        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appending(path: "ccwiki-snapshot-\(ProcessInfo.processInfo.processIdentifier)")
        try? manager.removeItem(at: staging)
        defer { try? manager.removeItem(at: staging) }

        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            // The tarball of the exact commit just read, so the marker and the
            // content cannot disagree.
            say("Downloading \(repository) at \(head.sha.prefix(7))…")
            let archive = try await download(sha: head.sha, to: staging.appending(path: "wiki.tgz"))
            say("Unpacking…")
            let unpacked = staging.appending(path: "unpacked")
            try manager.createDirectory(at: unpacked, withIntermediateDirectories: true)
            let tar = await Subprocess.run(
                executable: "/usr/bin/tar",
                arguments: ["-xzf", archive.path(percentEncoded: false),
                            "-C", unpacked.path(percentEncoded: false)],
                environment: ProcessInfo.processInfo.environment)
            guard tar.succeeded else { throw Failure.unpack(tar.output) }
            let root = try Self.unpackedRoot(in: unpacked)
            try Self.write(
                Marker(sha: head.sha, commitDate: head.date, fetchedAt: Date()), in: root)

            // Into place: beside the destination first, so the final move is
            // a rename on one volume, then the old one out and the new one in.
            let parent = destination.deletingLastPathComponent()
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            let partial = parent.appending(path: destination.lastPathComponent + ".partial")
            try? manager.removeItem(at: partial)
            try manager.moveItem(at: root, to: partial)
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: partial, to: destination)
        } catch {
            say("Failed: \(error.localizedDescription)")
            if Self.isNetworkFailure(error) {
                return existing == nil
                    ? .failed("The download did not finish. Check your connection and sync again.")
                    : .offline
            }
            return .failed("The wiki could not be downloaded: \(error.localizedDescription)")
        }

        say("Snapshot at \(head.sha.prefix(7)).")
        if let existing { return .updated(from: existing.sha, to: head.sha) }
        return .cloned
    }

    private func download(sha: String, to destination: URL) async throws -> URL {
        guard let url = URL(string: "https://codeload.github.com/\(repository)/tar.gz/\(sha)")
        else { throw Failure.badURL }
        return try await GitHubHTTP.download(url, to: destination, timeout: 300, session: session)
    }

    /// GitHub's tarballs hold one directory, `<repo>-<sha>/`. That is the
    /// snapshot; anything else in there is not ours.
    static func unpackedRoot(in directory: URL) throws -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let directories = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard directories.count == 1, let root = directories.first else { throw Failure.noRoot }
        return root
    }

    static func isNetworkFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .timedOut,
             .networkConnectionLost, .dnsLookupFailed, .internationalRoamingOff,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}
