import CryptoKit
import Foundation
import OSLog

/// What the clone's files held when a load read them: a digest of every file
/// `WikiIndex` lists, plus the manifest and the macro table
/// (plans/reader-comforts.md §3.3). Two of them compared say what a pull
/// changed, for a clone and a snapshot alike, without asking git: no previous
/// commit is needed, a clone edited by hand is caught, and tests drive it
/// with a temporary directory.
struct ContentFingerprints: Equatable, Sendable {

    /// Nothing read yet.
    static let empty = ContentFingerprints(pages: [:], manifest: nil, macros: nil)

    /// `content/`-relative path → digest, for every listed file.
    let pages: [String: String]
    /// `.reductions/relations.json`.
    let manifest: String?
    /// `macros.ts`.
    let macros: String?

    /// The fingerprints of the clone at `cloneRoot`: every file read and
    /// hashed, nothing parsed.
    static func scan(cloneRoot: URL) -> ContentFingerprints {
        ContentScan.read(cloneRoot: cloneRoot, parsingPages: false).fingerprints
    }

    /// The first 16 bytes of the SHA-256 of `data`, in hex: plenty to tell
    /// two versions of a wiki page apart, and half the size to keep.
    static func digest(_ data: Data) -> String {
        var hex: [UInt8] = []
        hex.reserveCapacity(32)
        for byte in SHA256.hash(data: data).prefix(16) {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// Stands for a listed file that could not be read. No digest looks like
    /// it, so a file that becomes readable again reads as modified.
    static let unreadable = "unreadable"
}

/// One read of the clone: every file a load lists, read once, hashed, and
/// for a page parsed from those same bytes, so a page and its fingerprint
/// always describe the same version of the file (§3.5). `LoadedLibrary.build`
/// assembles the index from it; `ContentFingerprints.scan` keeps only the
/// digests.
struct ContentScan: Sendable {
    /// What `WikiIndex.contentFiles` lists, sorted, assets included.
    let files: [String]
    /// Every `.md` file among them that parsed, by path.
    let pages: [String: WikiPage]
    /// The manifest's bytes; nil when it is missing or cannot be read, which
    /// `RelationsManifest.load` then explains.
    let manifest: Data?
    let fingerprints: ContentFingerprints

    static func read(cloneRoot: URL) -> ContentScan {
        read(cloneRoot: cloneRoot, parsingPages: true)
    }

    fileprivate static func read(cloneRoot: URL, parsingPages: Bool) -> ContentScan {
        let contentRoot = cloneRoot.appending(path: "content")
        let files = WikiIndex.contentFiles(root: contentRoot)
        var digests: [String: String] = [:]
        digests.reserveCapacity(files.count)
        var pages: [String: WikiPage] = [:]
        for path in files {
            guard let data = try? Data(contentsOf: contentRoot.appending(path: path)) else {
                digests[path] = ContentFingerprints.unreadable
                continue
            }
            digests[path] = ContentFingerprints.digest(data)
            if parsingPages, path.hasSuffix(".md"), let page = WikiPage.load(path: path, data: data) {
                pages[path] = page
            }
        }
        let manifest = try? Data(contentsOf: cloneRoot.appending(path: RelationsManifest.displayPath))
        let macros = try? Data(contentsOf: cloneRoot.appending(path: "macros.ts"))
        return ContentScan(
            files: files, pages: pages, manifest: manifest,
            fingerprints: ContentFingerprints(
                pages: digests,
                manifest: manifest.map(ContentFingerprints.digest),
                macros: macros.map(ContentFingerprints.digest)))
    }
}

/// The difference between two scans: which content files came, changed or
/// went, and whether the manifest or the macros changed.
struct LibraryChanges: Equatable, Sendable {

    /// `content/`-relative paths, as `ContentFingerprints.pages` keys them.
    var added: Set<String>
    var modified: Set<String>
    var deleted: Set<String>
    var manifestChanged: Bool
    var macrosChanged: Bool

    static let none = LibraryChanges(
        added: [], modified: [], deleted: [], manifestChanged: false, macrosChanged: false)

    /// What changed from `old` to `new`.
    static func between(_ old: ContentFingerprints, _ new: ContentFingerprints) -> LibraryChanges {
        var changes = LibraryChanges.none
        for (path, digest) in new.pages {
            if let before = old.pages[path] {
                if before != digest { changes.modified.insert(path) }
            } else {
                changes.added.insert(path)
            }
        }
        for path in old.pages.keys where new.pages[path] == nil {
            changes.deleted.insert(path)
        }
        changes.manifestChanged = old.manifest != new.manifest
        changes.macrosChanged = old.macros != new.macros
        return changes
    }

    var isEmpty: Bool {
        added.isEmpty && modified.isEmpty && deleted.isEmpty && !manifestChanged && !macrosChanged
    }

    /// Every content file that came, changed or went, assets included.
    var changedFiles: Set<String> {
        added.union(modified).union(deleted)
    }

    /// The pages among the three sets: an asset that changed is not a page
    /// that changed, for the sync's summary.
    var changedPages: Set<String> {
        changedFiles.filter { $0.hasSuffix(".md") }
    }

    /// `CCWIKI_FULL_RELOAD=1`, for diagnosis: no load trusts a comparison,
    /// so every one builds and renders everything and the search index is
    /// written again in full (§3.5).
    static var areIgnored: Bool {
        ProcessInfo.processInfo.environment["CCWIKI_FULL_RELOAD"] == "1"
    }
}

extension Logger {
    /// Category `library`: what each load read, built and wrote, and how long
    /// each part took (plans/reader-comforts.md §3.5, §3.8). Under the app's
    /// own subsystem, as the launch log is, so `log show --predicate
    /// 'subsystem BEGINSWITH "com.axhoover.ccwiki"'` finds both.
    static var library: Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.axhoover.ccwiki", category: "library")
    }
}
