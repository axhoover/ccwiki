import AppKit
import CoreServices
import Foundation
import OSLog

/// A copy of CCwiki on this Mac: where it is and what its `Info.plist` says.
struct InstalledCopy: Equatable, Sendable {
    let url: URL
    /// `CFBundleShortVersionString`.
    let version: String
    /// `CFBundleVersion`, the build time, which tells two builds of one
    /// version apart. `InstallationCheck.unknownBuild` when it could not be
    /// read.
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
    /// Copies at `running`'s path are left out first. When `running` is App
    /// Translocation's read-only mirror, so are copies of its version and
    /// build, or of its version and an unknown build: LaunchServices lists
    /// the folder the mirror was made from under that folder's own path, on
    /// a writable volume, and that folder is this copy. Nothing public says
    /// which copy it is, and a false "other copy" would be offered to the
    /// Trash, or replaced by itself. Then, in order:
    ///
    /// 1. A newer release elsewhere wins: open it, the newest of them. A
    ///    development version (a stale build from before builds from source
    ///    got an identifier of their own) is never newer. Paths in
    ///    `ignoredPaths` count here: "Don't ask again" was said about the
    ///    copy that was there, and a newer one there since is news.
    /// 2. Running from outside Applications, with a copy in Applications
    ///    that is not ignored: replace that one, preferring
    ///    `/Applications/CCwiki.app`, the one the Dock and Spotlight use, then
    ///    the rest of `/Applications`, then `~/Applications`.
    /// 3. Any copy left that is not ignored, same version or older: offer
    ///    to remove them.
    static func advice(
        running: InstalledCopy,
        runningInApplicationsFolder: Bool,
        others: [InstalledCopy],
        ignoredPaths: Set<String>,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> InstallationAdvice {
        let runningPath = path(of: running.url)
        let ignored = Set(ignoredPaths.map { path(of: URL(fileURLWithPath: $0)) })
        let translocated = BundleLocation.isTranslocated(running.url)
        let candidates = others.filter { copy in
            guard path(of: copy.url) != runningPath else { return false }
            return !(translocated && copy.version == running.version
                && (copy.build == running.build || copy.build == unknownBuild))
        }

        // The canonical /Applications/CCwiki.app first, then the rest of
        // /Applications, then ~/Applications/CCwiki.app and the rest of
        // ~/Applications, then anywhere else; by path within each.
        let homeCanonical = path(of: home.appending(path: "Applications/CCwiki.app"))
        let outsideApplications = 4
        func rank(_ copy: InstalledCopy) -> Int {
            let candidate = path(of: copy.url)
            if candidate == "/Applications/CCwiki.app" { return 0 }
            if candidate.hasPrefix("/Applications/") { return 1 }
            if candidate == homeCanonical { return 2 }
            if BundleLocation.isInApplicationsFolder(copy.url, home: home) { return 3 }
            return outsideApplications
        }
        func precedes(_ a: InstalledCopy, _ b: InstalledCopy) -> Bool {
            (rank(a), path(of: a.url)) < (rank(b), path(of: b.url))
        }

        let newer = candidates.filter {
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

        let remaining = candidates.filter { !ignored.contains(path(of: $0.url)) }
        if !runningInApplicationsFolder,
           let target = remaining.filter({ rank($0) < outsideApplications })
               .sorted(by: precedes).first {
            return .replaceOlder(target)
        }

        guard !remaining.isEmpty else { return .none }
        return .removeOthers(remaining.sorted { path(of: $0.url) < path(of: $1.url) })
    }

    /// Whether a copy of `version` is behind the running `current`: older,
    /// or a development version, which has no order. A same-version release
    /// is not. (Whether it updates itself is another matter: every release
    /// does when it runs; only a development version never does.)
    static func isOlder(_ version: String, than current: String) -> Bool {
        UpdateChecker.isDevelopmentVersion(version) || UpdateChecker.isNewer(current, than: version)
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
    ///
    /// A copy in `home`'s Desktop, Documents or Downloads is read from
    /// Spotlight rather than from its `Info.plist` (`isPrivacyProtected`).
    static func copies(of identifier: String, among candidates: [URL],
                       besides running: URL,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [InstalledCopy] {
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
            let found = isPrivacyProtected(url, home: home) ? spotlightIdentity(of: url) : inspect(url)
            guard let copy = found, copy.identifier == identifier else { continue }
            result.append(InstalledCopy(url: url, version: copy.version, build: copy.build))
        }
        return result
    }

    /// What `InstalledCopy.build` says when the build number is not known.
    static let unknownBuild = "?"

    /// The bundle's own `Info.plist`, read from disk: `Bundle(url:)` caches
    /// what it read first, and a copy may have been replaced since.
    private static func inspect(_ bundle: URL) -> (identifier: String, version: String, build: String)? {
        guard let data = try? Data(contentsOf: bundle.appending(path: "Contents/Info.plist")),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = object as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              let version = plist["CFBundleShortVersionString"] as? String
        else { return nil }
        return (identifier, version, plist["CFBundleVersion"] as? String ?? unknownBuild)
    }

    /// In `home`'s Desktop, Documents or Downloads, at any depth. macOS asks
    /// the person before an app reads a file there, so reading a copy's
    /// `Info.plist` would ask at launch, before CCwiki has said why, and a
    /// "Don't Allow" would hide that copy from every later check.
    private static func isPrivacyProtected(_ url: URL, home: URL) -> Bool {
        let full = path(of: url)
        return ["Desktop", "Documents", "Downloads"].contains { folder in
            full.hasPrefix(path(of: home.appending(path: folder)) + "/")
        }
    }

    /// A bundle's identifier and version as Spotlight indexed them, which
    /// opens no file of the bundle's. Spotlight does not keep the build
    /// number. Nil when Spotlight has nothing on it, and the copy is then
    /// left out, as it would be if the person refused access.
    private static func spotlightIdentity(of bundle: URL)
        -> (identifier: String, version: String, build: String)? {
        guard let item = MDItemCreateWithURL(nil, bundle as CFURL) else { return nil }
        let identifierKey = "kMDItemCFBundleIdentifier" as CFString
        let versionKey = "kMDItemVersion" as CFString
        guard let identifier = MDItemCopyAttribute(item, identifierKey) as? String,
              let version = MDItemCopyAttribute(item, versionKey) as? String
        else { return nil }
        return (identifier, version, unknownBuild)
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

    /// Why `installCopy` left the copy in Applications as it was, apart from
    /// the swap's own failures (`UpdateInstaller.Failure`).
    enum Failure: LocalizedError, Equatable {
        /// `ditto` could not copy this bundle onto that volume.
        case copy(String)
        /// That copy was moved, deleted or replaced by another app since.
        case gone(place: String)
        /// That copy updated itself past this one since.
        case newerThere(version: String, place: String)

        var errorDescription: String? {
            switch self {
            case .copy(let why):
                "This copy could not be copied there: \(why)"
            case .gone(let place):
                "The CCwiki in \(place) has been moved, deleted or replaced since, so nothing "
                    + "was put there."
            case .newerThere(let version, let place):
                "The copy in \(place) is now CCwiki \(version), newer than this one, so it was "
                    + "left as it is."
            }
        }
    }

    /// Puts a copy of the bundle at `source` where `destination` is, and
    /// deletes the bundle that was there.
    ///
    /// `ditto` copies the bundle, signature and all, onto `destination`'s
    /// volume. Quarantine is stripped from the copy: this bundle has already
    /// been opened, and a copy still marked would run through App
    /// Translocation, from where it cannot update itself. Then the updater's
    /// own swap puts it in place in one step (`UpdateInstaller.replace`).
    /// Throws, with `destination` as it was, if any step fails, or if
    /// `destination` is by then no longer this app or a newer release than
    /// `source`. The one exception is `replace`'s: a swap it can neither
    /// confirm nor undo, whose error says where the old bundle is. Not on
    /// the main actor: the copy takes a moment.
    static func installCopy(of source: URL, over destination: URL) async throws {
        let manager = FileManager.default
        let staging = try UpdateInstaller.stagingDirectory(appropriateFor: destination)
        // Deleted with whatever is in it, unless that is the bundle that was
        // in Applications: see the catch at the end.
        var keepsStaging = false
        defer {
            if !keepsStaging { try? manager.removeItem(at: staging) }
        }
        let staged = staging.appending(path: destination.lastPathComponent)
        let environment = ProcessInfo.processInfo.environment
        let place = displayLocation(destination)

        let ditto = await Subprocess.run(
            executable: "/usr/bin/ditto",
            arguments: [source.path(percentEncoded: false), staged.path(percentEncoded: false)],
            environment: environment)
        guard ditto.succeeded else {
            let why = ditto.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.copy(why.isEmpty ? "ditto failed." : why)
        }
        _ = await Subprocess.run(
            executable: "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", staged.path(percentEncoded: false)],
            environment: environment)
        guard let incoming = try? UpdateInstaller.inspect(bundle: staged) else {
            throw Failure.copy("the copy has no readable Info.plist.")
        }

        // The question may have been open a long while. The copy there may
        // have gone, or become another app, which `replace` would delete;
        // or it may have updated itself meanwhile, and a newer release is
        // never replaced by an older one (§2.2).
        guard let present = try? UpdateInstaller.inspect(bundle: destination),
              present.identifier == incoming.identifier
        else { throw Failure.gone(place: place) }
        if !UpdateChecker.isDevelopmentVersion(present.version),
           UpdateChecker.isNewer(present.version, than: incoming.version) {
            throw Failure.newerThere(version: present.version, place: place)
        }

        let copied = FileIdentity(staged)
        do {
            try UpdateInstaller.replace(destination, with: staged)
        } catch {
            // A swap that could be neither confirmed nor undone, whose old
            // bundle could not be moved beside `destination` either, leaves
            // that bundle at `staged`, and it is the only copy of it. The
            // error says where; it stays there. It is told from the copy
            // made above by its file, since the two may share a version.
            if manager.fileExists(atPath: staged.path(percentEncoded: false)),
               copied == nil || FileIdentity(staged) != copied {
                keepsStaging = true
            }
            throw error
        }
    }

    // MARK: What's New

    /// The version What's New compares with at launch: the newer of
    /// `recorded` (`ccwiki.lastSeenVersion`, which every copy writes,
    /// those from before this check included, each with its own version)
    /// and `highest` (`ccwiki.highestSeenVersion`, which only copies with
    /// this check write). A development version in either has no order,
    /// and gives way to the other.
    static func seenVersion(recorded: String?, highest: String?) -> String? {
        guard let highest, !UpdateChecker.isDevelopmentVersion(highest) else { return recorded }
        guard let recorded, !UpdateChecker.isDevelopmentVersion(recorded),
              UpdateChecker.isNewer(recorded, than: highest)
        else { return highest }
        return recorded
    }

    /// What to store as seen at launch, given `seenVersion`'s answer. It
    /// only moves forward, so an older copy opened by mistake cannot make
    /// the next launch of this one show What's New again. A development
    /// version on either side has no order to keep, and is simply recorded.
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
    /// "~/Applications", "Downloads", "Desktop"; "a temporary folder" for App
    /// Translocation's mirror, whose path is random and means nothing to
    /// them; otherwise the folder's path, with `~` for the home folder.
    static func displayLocation(
        _ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        if BundleLocation.isTranslocated(url) { return "a temporary folder" }
        let folder = path(of: url.deletingLastPathComponent())
        let homePath = path(of: home)
        switch folder {
        case "/Applications": return "Applications"
        case homePath + "/Applications": return "~/Applications"
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
        let location = path(of: copy.url)
        logger.notice(
            "CCwiki \(copy.version, privacy: .public) (\(copy.build, privacy: .public)) started from \(location, privacy: .public)")
    }
}
