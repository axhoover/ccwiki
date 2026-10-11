import AppKit
import Foundation
import OSLog

/// A copy of CCwiki on this Mac: where it is and what its `Info.plist` says.
struct InstalledCopy: Equatable, Sendable {
    let url: URL
    /// `CFBundleShortVersionString`.
    let version: String
    /// `CFBundleVersion`, the build time, which tells two builds of one
    /// version apart.
    let build: String
}

/// What the launch check says about the other copies. One answer, because a
/// launch shows at most one alert about them.
enum InstallationAdvice: Equatable, Sendable {
    case none
    /// A newer version is on this Mac: open it rather than this one.
    case openNewer(InstalledCopy)
    /// This copy runs from outside Applications, and an older or equal one
    /// sits in Applications, where the Dock and Spotlight find it: put this
    /// one there instead.
    case replaceOlder(InstalledCopy)
    /// Older or same-version copies elsewhere, sorted by path: offer the Trash.
    case removeOthers([InstalledCopy])
}

/// Finds the other copies of CCwiki at launch and decides what to say about
/// them (`plans/update-integrity.md` §2.3).
///
/// The updater replaces only the copy that is running, while the Dock,
/// Spotlight, Launchpad and `ccwiki://` links each open whichever copy
/// LaunchServices picks. So a copy that predates the updater keeps coming
/// back, and it cannot tell that it is stale. The copy that is current has to
/// find it. Everything here but `otherCopies`, which asks LaunchServices, is
/// a pure function of its arguments or of files it is pointed at, so the
/// decision is tested without a second app installed.
enum InstallationCheck {

    // MARK: The decision

    /// What to tell the person about `others`, given the copy that is running.
    ///
    /// Copies at `running`'s path or at a path in `ignoredPaths` are left out
    /// first. Then, in order:
    ///
    /// 1. A newer release elsewhere wins: open it, the newest of them. A
    ///    development version (a stale build from before builds from source
    ///    got an identifier of their own) is never newer.
    /// 2. Running from outside Applications, with another copy in
    ///    Applications: replace that one, preferring `/Applications` over
    ///    `~/Applications`.
    /// 3. Any copy left, same version or older: offer to remove them.
    static func advice(
        running: InstalledCopy,
        runningInApplicationsFolder: Bool,
        others: [InstalledCopy],
        ignoredPaths: Set<String>,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> InstallationAdvice {
        let runningPath = path(of: running.url)
        let ignored = Set(ignoredPaths.map { path(of: URL(fileURLWithPath: $0)) })
        let remaining = others.filter { copy in
            let candidate = path(of: copy.url)
            return candidate != runningPath && !ignored.contains(candidate)
        }

        // Applications first, /Applications before ~/Applications, then by path.
        func rank(_ copy: InstalledCopy) -> Int {
            if path(of: copy.url).hasPrefix("/Applications/") { return 0 }
            if BundleLocation.isInApplicationsFolder(copy.url, home: home) { return 1 }
            return 2
        }
        func precedes(_ a: InstalledCopy, _ b: InstalledCopy) -> Bool {
            (rank(a), path(of: a.url)) < (rank(b), path(of: b.url))
        }

        let newer = remaining.filter {
            !UpdateChecker.isDevelopmentVersion($0.version)
                && UpdateChecker.isNewer($0.version, than: running.version)
        }
        if let newest = newer.sorted(by: { a, b in
            if UpdateChecker.isNewer(a.version, than: b.version) { return true }
            if UpdateChecker.isNewer(b.version, than: a.version) { return false }
            return precedes(a, b)
        }).first {
            return .openNewer(newest)
        }

        if !runningInApplicationsFolder,
           let target = remaining.filter({ rank($0) < 2 }).sorted(by: precedes).first {
            return .replaceOlder(target)
        }

        guard !remaining.isEmpty else { return .none }
        return .removeOthers(remaining.sorted { path(of: $0.url) < path(of: $1.url) })
    }

    // MARK: Finding the copies

    /// Every copy of `identifier` that LaunchServices knows about and that
    /// could start instead of this one, `running` excepted. Leaves out paths
    /// that no longer exist, anything in a Trash (LaunchServices will not
    /// run it), anything on a read-only volume (a disk image, a backup, App
    /// Translocation's mirror), and folders whose `Info.plist` names another
    /// app. Reads the disk; safe to call off the main actor.
    static func otherCopies(of identifier: String, besides running: URL) -> [InstalledCopy] {
        copies(
            of: identifier,
            among: NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier),
            besides: running)
    }

    /// `otherCopies` once LaunchServices has answered, so the filtering can
    /// be tested on bundles made for the purpose.
    ///
    /// Two spellings of one folder count once: each candidate's symbolic
    /// links are resolved and the data volume's `/System/Volumes/Data`
    /// prefix dropped, and a candidate that is the same file as one already
    /// seen, or as `running`, is skipped. A false "other copy" would be
    /// offered to the Trash, so this errs towards leaving one out.
    static func copies(of identifier: String, among candidates: [URL],
                       besides running: URL) -> [InstalledCopy] {
        let manager = FileManager.default
        let runningURL = running.resolvingSymlinksInPath()
        var seenPaths: Set<String> = [path(of: runningURL)]
        var seenFiles: Set<FileIdentity> = []
        if let identity = FileIdentity(runningURL) { seenFiles.insert(identity) }

        var result: [InstalledCopy] = []
        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath()
            let candidatePath = path(of: resolved)
            guard seenPaths.insert(candidatePath).inserted,
                  manager.fileExists(atPath: candidatePath),
                  !BundleLocation.isInTrash(resolved),
                  !isOnReadOnlyVolume(resolved),
                  let identity = FileIdentity(resolved),
                  seenFiles.insert(identity).inserted
            else { continue }
            let url = URL(fileURLWithPath: candidatePath, isDirectory: true)
            guard let copy = inspect(url), copy.identifier == identifier else { continue }
            result.append(InstalledCopy(url: url, version: copy.version, build: copy.build))
        }
        return result
    }

    /// The bundle's own `Info.plist`, read from disk: `Bundle(url:)` caches
    /// what it read first, and a copy may have been replaced since.
    private static func inspect(_ bundle: URL) -> (identifier: String, version: String, build: String)? {
        guard let data = try? Data(contentsOf: bundle.appending(path: "Contents/Info.plist")),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = object as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              let version = plist["CFBundleShortVersionString"] as? String
        else { return nil }
        return (identifier, version, plist["CFBundleVersion"] as? String ?? "?")
    }

    private static func isOnReadOnlyVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
    }

    /// The device and inode of a file, which no second spelling of its path
    /// can change.
    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64

        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(
                      atPath: url.path(percentEncoded: false)),
                  let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            else { return nil }
            self.device = device
            self.inode = inode
        }
    }

    // MARK: Replacing the copy in Applications

    /// Puts a copy of the bundle at `source` where `destination` is, and
    /// deletes the bundle that was there.
    ///
    /// `ditto` copies the bundle, signature and all, onto `destination`'s
    /// volume. Quarantine is stripped from the copy: this bundle has already
    /// been opened, and a copy still marked would run through App
    /// Translocation, from where it cannot update itself. Then the updater's
    /// own swap puts it in place in one step (`UpdateInstaller.replace`).
    /// Throws, with `destination` as it was, if any step fails. Not on the
    /// main actor: the copy takes a moment.
    static func installCopy(of source: URL, over destination: URL) async throws {
        let manager = FileManager.default
        let staging = try UpdateInstaller.stagingDirectory(appropriateFor: destination)
        defer { try? manager.removeItem(at: staging) }
        let staged = staging.appending(path: destination.lastPathComponent)
        let environment = ProcessInfo.processInfo.environment

        let ditto = await Subprocess.run(
            executable: "/usr/bin/ditto",
            arguments: [source.path(percentEncoded: false), staged.path(percentEncoded: false)],
            environment: environment)
        guard ditto.succeeded else {
            throw UpdateInstaller.Failure.swap("This copy could not be duplicated: \(ditto.output)")
        }
        _ = await Subprocess.run(
            executable: "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", staged.path(percentEncoded: false)],
            environment: environment)
        try UpdateInstaller.replace(destination, with: staged)
    }

    // MARK: What's New

    /// What to store as `ccwiki.lastSeenVersion` at launch. It only moves
    /// forward, so an older copy opened by mistake cannot make the next
    /// launch of this one show What's New again. A development version on
    /// either side has no order to keep, and is simply recorded.
    static func nextSeenVersion(lastSeen: String?, current: String) -> String {
        guard let lastSeen,
              !UpdateChecker.isDevelopmentVersion(lastSeen),
              !UpdateChecker.isDevelopmentVersion(current),
              !UpdateChecker.isNewer(current, than: lastSeen)
        else { return current }
        return lastSeen
    }

    // MARK: Saying where

    /// The folder a bundle is in, as a person names it: "Applications",
    /// "Applications (yours)" for `~/Applications`, "Downloads", "Desktop";
    /// otherwise the folder's path, with `~` for the home folder.
    static func displayLocation(
        _ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let folder = path(of: url.deletingLastPathComponent())
        let homePath = path(of: home)
        switch folder {
        case "/Applications": return "Applications"
        case homePath + "/Applications": return "Applications (yours)"
        case homePath + "/Downloads": return "Downloads"
        case homePath + "/Desktop": return "Desktop"
        default: return abbreviatedPath(URL(fileURLWithPath: folder), home: home)
        }
    }

    /// Two copies' locations for one sentence: their folders, or their full
    /// paths when the folders read the same, so the sentence tells them apart.
    static func displayLocations(
        _ first: URL, _ second: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> (first: String, second: String) {
        let a = displayLocation(first, home: home)
        let b = displayLocation(second, home: home)
        guard a == b else { return (a, b) }
        return (abbreviatedPath(first, home: home), abbreviatedPath(second, home: home))
    }

    /// `/Users/me/Downloads/CCwiki.app` → `~/Downloads/CCwiki.app`.
    static func abbreviatedPath(
        _ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let full = path(of: url)
        let homePath = path(of: home)
        guard homePath != "/" else { return full }
        if full == homePath { return "~" }
        if full.hasPrefix(homePath + "/") { return "~" + String(full.dropFirst(homePath.count)) }
        return full
    }

    /// The form a copy's location is compared and remembered in: standardized,
    /// without a trailing slash, and without the `/System/Volumes/Data`
    /// prefix, since LaunchServices reports either spelling of one folder.
    /// Symbolic links are left as they are; `copies` resolves them first.
    static func path(of url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        let dataVolume = "/System/Volumes/Data"
        if path == dataVolume {
            path = "/"
        } else if path.hasPrefix(dataVolume + "/") {
            path.removeFirst(dataVolume.count)
        }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: The launch log

    /// One line a launch, under category `launch`, so that
    /// `log show --last 7d --predicate 'subsystem BEGINSWITH "com.axhoover.ccwiki"'`
    /// answers which copy ran when. `notice`, because `info` is not kept.
    static func logLaunch(of copy: InstalledCopy) {
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? BuildIdentity.releaseBundleIdentifier,
            category: "launch")
        let location = copy.url.path(percentEncoded: false)
        logger.notice(
            "CCwiki \(copy.version, privacy: .public) (\(copy.build, privacy: .public)) started from \(location, privacy: .public)")
    }
}
