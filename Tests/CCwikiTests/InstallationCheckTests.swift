import Foundation
import Testing
@testable import CCwiki

/// The launch check's decision, where a remembered version goes, and how a
/// location is named. LaunchServices itself is not asked: `copies` is tested
/// on bundles made in a temporary folder instead.
struct InstallationCheckTests {

    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    private func copy(_ path: String, _ version: String, build: String = "202610110900") -> InstalledCopy {
        InstalledCopy(url: URL(fileURLWithPath: path, isDirectory: true), version: version, build: build)
    }

    private func advice(
        running: InstalledCopy, inApplications: Bool, others: [InstalledCopy],
        ignoring ignored: Set<String> = []
    ) -> InstallationAdvice {
        InstallationCheck.advice(
            running: running, runningInApplicationsFolder: inApplications, others: others,
            ignoredPaths: ignored, home: home)
    }

    /// A bundle at `relative` under `root` with only an `Info.plist`, or with
    /// an empty `Contents` folder when `identifier` is nil.
    private func makeBundle(_ relative: String, in root: URL, identifier: String?,
                            version: String, build: String = "202610110900") throws -> URL {
        let manager = FileManager.default
        let app = root.appending(path: relative)
        let contents = app.appending(path: "Contents")
        try manager.createDirectory(at: contents, withIntermediateDirectories: true)
        guard let identifier else { return app }
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        return app
    }

    // MARK: advice

    @Test("no other copy, or only this one under another spelling, is nothing to say")
    func nothingToSay() {
        let running = copy("/Applications/CCwiki.app", "0.2.0")
        #expect(advice(running: running, inApplications: true, others: []) == InstallationAdvice.none)
        let same = [
            copy("/Applications/CCwiki.app/", "0.2.0"),
            copy("/System/Volumes/Data/Applications/CCwiki.app", "0.2.0"),
        ]
        #expect(advice(running: running, inApplications: true, others: same)
            == InstallationAdvice.none)
    }

    @Test("a newer copy wins, and the newest of several is the one offered")
    func newer() {
        let running = copy("/Users/someone/Downloads/CCwiki.app", "0.1.0")
        let older = copy("/Users/someone/Desktop/CCwiki.app", "0.0.9")
        let newer = copy("/Users/someone/Applications/CCwiki.app", "0.2.0")
        let newest = copy("/Applications/Reading/CCwiki.app", "0.10.0")
        // Ahead of replacing the older copy in Applications, too.
        let installed = copy("/Applications/CCwiki.app", "0.0.8")
        #expect(advice(running: running, inApplications: false,
                       others: [older, newer, installed, newest]) == .openNewer(newest))
    }

    @Test("among copies of the newest version, the one in Applications is offered")
    func newestTie() {
        let running = copy("/Applications/CCwiki.app", "0.1.0")
        let downloaded = copy("/Users/someone/Downloads/CCwiki.app", "0.2.0")
        let installed = copy("/Users/someone/Applications/CCwiki.app", "0.2.0")
        #expect(advice(running: running, inApplications: true, others: [downloaded, installed])
            == .openNewer(installed))
    }

    @Test("a development version is never newer, whatever its number")
    func developmentIsNeverNewer() {
        let running = copy("/Applications/CCwiki.app", "0.2.0")
        let stale = copy("/Users/someone/src/ccwiki/build/CCwiki.app", "0.3.0-dev")
        let unstamped = copy("/Users/someone/src/other/build/CCwiki.app", "0.0.0")
        #expect(advice(running: running, inApplications: true, others: [stale, unstamped])
            == .removeOthers([stale, unstamped]))
    }

    @Test("a same-version duplicate is another copy, not a newer one")
    func sameVersion() {
        let running = copy("/Applications/CCwiki.app", "0.2.0")
        let duplicate = copy("/Users/someone/Downloads/CCwiki.app", "0.2.0", build: "202612010000")
        #expect(advice(running: running, inApplications: true, others: [duplicate])
            == .removeOthers([duplicate]))
    }

    @Test("running outside Applications, the copy in Applications is replaced, /Applications first")
    func replaceOlder() {
        let running = copy("/Users/someone/Downloads/CCwiki.app", "0.2.0")
        let system = copy("/Applications/CCwiki.app", "0.1.0")
        let yours = copy("/Users/someone/Applications/CCwiki.app", "0.1.0")
        let elsewhere = copy("/Users/someone/Desktop/CCwiki.app", "0.1.0")
        #expect(advice(running: running, inApplications: false, others: [elsewhere, yours, system])
            == .replaceOlder(system))
        #expect(advice(running: running, inApplications: false, others: [elsewhere, yours])
            == .replaceOlder(yours))
        // A same-version or development copy in Applications is replaced too.
        let sameVersion = copy("/Applications/CCwiki.app", "0.2.0")
        #expect(advice(running: running, inApplications: false, others: [sameVersion])
            == .replaceOlder(sameVersion))
        let development = copy("/Applications/CCwiki.app", "0.9.0-dev")
        #expect(advice(running: running, inApplications: false, others: [development])
            == .replaceOlder(development))
    }

    @Test("running from Applications, older copies are offered to the Trash, sorted by path")
    func removeOthers() {
        let running = copy("/Applications/CCwiki.app", "0.2.0")
        let a = copy("/Users/someone/Downloads/CCwiki.app", "0.1.0")
        let b = copy("/Users/someone/Applications/CCwiki.app", "0.1.2")
        let c = copy("/Applications/Old/CCwiki.app", "0.1.0")
        #expect(advice(running: running, inApplications: true, others: [a, b, c])
            == .removeOthers([c, b, a]))
        // Outside Applications with nothing in it: the same offer.
        let downloaded = copy("/Users/someone/Downloads/CCwiki 2.app", "0.2.0")
        #expect(advice(running: downloaded, inApplications: false, others: [a])
            == .removeOthers([a]))
    }

    @Test("an ignored path is never replaced or offered to the Trash")
    func ignored() {
        let running = copy("/Users/someone/Downloads/CCwiki.app", "0.1.0")
        let installed = copy("/Applications/CCwiki.app", "0.0.9")
        let other = copy("/Volumes/Backup/CCwiki.app", "0.0.9")
        let all = [installed, other]
        #expect(advice(running: running, inApplications: false, others: all)
            == .replaceOlder(installed))
        #expect(advice(running: running, inApplications: false, others: all,
                       ignoring: ["/Applications/CCwiki.app/"]) == .removeOthers([other]))
        #expect(advice(running: running, inApplications: false, others: all,
                       ignoring: Set(all.map { InstallationCheck.path(of: $0.url) }))
            == InstallationAdvice.none)
    }

    @Test("a newer copy at an ignored path is still offered")
    func ignoredButNewer() {
        // "Don't ask again" was said about the 0.0.9 that was there; the
        // copy there has since updated itself past this one.
        let running = copy("/Users/someone/Downloads/CCwiki.app", "0.1.0")
        let updated = copy("/Applications/CCwiki.app", "0.2.0")
        let other = copy("/Volumes/Backup/CCwiki.app", "0.0.9")
        #expect(advice(running: running, inApplications: false, others: [updated, other],
                       ignoring: ["/Applications/CCwiki.app"]) == .openNewer(updated))
    }

    @Test("the canonical /Applications/CCwiki.app is replaced ahead of a Finder duplicate or a subfolder")
    func canonicalFirst() {
        let running = copy("/Users/someone/Downloads/CCwiki.app", "0.2.0")
        let canonical = copy("/Applications/CCwiki.app", "0.1.0")
        let duplicate = copy("/Applications/CCwiki 2.app", "0.1.0")
        let archived = copy("/Applications/Archive/CCwiki.app", "0.1.0")
        #expect(advice(running: running, inApplications: false,
                       others: [duplicate, archived, canonical]) == .replaceOlder(canonical))
        // In ~/Applications, likewise, and after anything in /Applications.
        let yours = copy("/Users/someone/Applications/CCwiki.app", "0.1.0")
        let yoursArchived = copy("/Users/someone/Applications/Archive/CCwiki.app", "0.1.0")
        #expect(advice(running: running, inApplications: false, others: [yoursArchived, yours])
            == .replaceOlder(yours))
        #expect(advice(running: running, inApplications: false, others: [yours, duplicate])
            == .replaceOlder(duplicate))
    }

    @Test("running translocated, the folder the mirror was made from is not another copy")
    func translocated() {
        let mirror = "/private/var/folders/xy/abc123/T/AppTranslocation/"
            + "0F2B4A1C-1111-2222-3333-444455556666/d/CCwiki.app"
        let running = copy(mirror, "0.2.0")
        // LaunchServices lists the original under its own path. Opened from
        // Downloads, it is not offered to the Trash; opened from Applications
        // while still quarantined, it is not replaced by itself.
        let original = copy("/Users/someone/Downloads/CCwiki.app", "0.2.0")
        #expect(advice(running: running, inApplications: false, others: [original])
            == InstallationAdvice.none)
        let installedOriginal = copy("/Applications/CCwiki.app", "0.2.0")
        #expect(advice(running: running, inApplications: false, others: [installedOriginal])
            == InstallationAdvice.none)
        // Every other copy is still what it was: an older one in Applications
        // is replaced, a newer one is opened, another build is another copy.
        let older = copy("/Applications/CCwiki.app", "0.1.0")
        #expect(advice(running: running, inApplications: false, others: [original, older])
            == .replaceOlder(older))
        let newer = copy("/Users/someone/Applications/CCwiki.app", "0.3.0")
        #expect(advice(running: running, inApplications: false, others: [original, newer])
            == .openNewer(newer))
        let rebuilt = copy("/Users/someone/Desktop/CCwiki.app", "0.2.0", build: "202612010000")
        #expect(advice(running: running, inApplications: false, others: [original, rebuilt])
            == .removeOthers([rebuilt]))
        // A copy read from Spotlight has no build number; one of this
        // version may be the original, and is left out too.
        let unknown = copy("/Users/someone/Downloads/CCwiki.app", "0.2.0",
                           build: InstallationCheck.unknownBuild)
        #expect(advice(running: running, inApplications: false, others: [unknown])
            == InstallationAdvice.none)
        // Not translocated, the same copy in Downloads is a duplicate.
        let installed = copy("/Applications/CCwiki.app", "0.2.0")
        #expect(advice(running: installed, inApplications: true, others: [original])
            == .removeOthers([original]))
    }

    @Test("an older or development copy is behind; a same-version release is not")
    func isOlder() {
        #expect(InstallationCheck.isOlder("0.1.0", than: "0.2.0"))
        #expect(InstallationCheck.isOlder("0.9.0", than: "0.10.0"))
        #expect(InstallationCheck.isOlder("0.3.0-dev", than: "0.2.0"))
        #expect(InstallationCheck.isOlder("0.0.0", than: "0.2.0"))
        #expect(!InstallationCheck.isOlder("0.2.0", than: "0.2.0"))
        #expect(!InstallationCheck.isOlder("0.3.0", than: "0.2.0"))
    }

    // MARK: nextSeenVersion

    @Test("the version remembered for What's New only moves forward")
    func nextSeenVersion() {
        #expect(InstallationCheck.nextSeenVersion(lastSeen: nil, current: "0.1.0") == "0.1.0")
        #expect(InstallationCheck.nextSeenVersion(lastSeen: "0.1.0", current: "0.2.0") == "0.2.0")
        #expect(InstallationCheck.nextSeenVersion(lastSeen: "0.2.0", current: "0.2.0") == "0.2.0")
        // An older copy opened by mistake does not rewind it.
        #expect(InstallationCheck.nextSeenVersion(lastSeen: "0.2.0", current: "0.1.0") == "0.2.0")
        #expect(InstallationCheck.nextSeenVersion(lastSeen: "0.10.0", current: "0.9.0") == "0.10.0")
        // A development version on either side has no order to keep.
        #expect(InstallationCheck.nextSeenVersion(lastSeen: "0.2.0", current: "0.1.1-dev") == "0.1.1-dev")
        #expect(InstallationCheck.nextSeenVersion(lastSeen: "0.3.0-dev", current: "0.2.0") == "0.2.0")
        #expect(InstallationCheck.nextSeenVersion(lastSeen: "0.0.0", current: "0.1.0") == "0.1.0")
    }

    @Test("What's New compares with the newer of the two records")
    func seenVersion() {
        #expect(InstallationCheck.seenVersion(recorded: nil, highest: nil) == nil)
        #expect(InstallationCheck.seenVersion(recorded: "0.1.3", highest: nil) == "0.1.3")
        // A copy from before the check wrote its own, older version.
        #expect(InstallationCheck.seenVersion(recorded: "0.1.3", highest: "0.2.0") == "0.2.0")
        #expect(InstallationCheck.seenVersion(recorded: "0.10.0", highest: "0.9.0") == "0.10.0")
        // A development version gives way to the other.
        #expect(InstallationCheck.seenVersion(recorded: "0.3.0-dev", highest: "0.2.0") == "0.2.0")
        #expect(InstallationCheck.seenVersion(recorded: "0.1.3", highest: "0.0.0") == "0.1.3")
        #expect(InstallationCheck.seenVersion(recorded: nil, highest: "0.2.0") == "0.2.0")
    }

    // MARK: Locations

    @Test("a location is named the way a person names the folder")
    func displayLocation() {
        func location(_ path: String) -> String {
            InstallationCheck.displayLocation(URL(fileURLWithPath: path), home: home)
        }
        #expect(location("/Applications/CCwiki.app") == "Applications")
        #expect(location("/System/Volumes/Data/Applications/CCwiki.app") == "Applications")
        #expect(location("/Users/someone/Applications/CCwiki.app") == "~/Applications")
        #expect(location("/Users/someone/Downloads/CCwiki.app") == "Downloads")
        #expect(location("/Users/someone/Desktop/CCwiki.app") == "Desktop")
        #expect(location("/Users/someone/src/ccwiki/build/CCwiki.app") == "~/src/ccwiki/build")
        #expect(location("/Users/someone/CCwiki.app") == "~")
        #expect(location("/Applications/Reading/CCwiki.app") == "/Applications/Reading")
        #expect(location("/Volumes/Backup/Apps/CCwiki.app") == "/Volumes/Backup/Apps")
        #expect(location("/Users/someoneelse/Downloads/CCwiki.app") == "/Users/someoneelse/Downloads")
        #expect(location("/private/var/folders/xy/abc123/T/AppTranslocation/"
            + "0F2B4A1C-1111-2222-3333-444455556666/d/CCwiki.app") == "a temporary folder")
        #expect(InstallationCheck.displayLocation(
            URL(fileURLWithPath: "/Applications/CCwiki.app", isDirectory: true), home: home)
            == "Applications")
    }

    @Test("two copies in folders that read the same are told apart by path")
    func displayLocations() {
        let a = URL(fileURLWithPath: "/Applications/CCwiki.app")
        let b = URL(fileURLWithPath: "/Applications/CCwiki 2.app")
        let c = URL(fileURLWithPath: "/Users/someone/Downloads/CCwiki.app")
        let apart = InstallationCheck.displayLocations(a, c, home: home)
        #expect(apart.first == "Applications")
        #expect(apart.second == "Downloads")
        let together = InstallationCheck.displayLocations(a, b, home: home)
        #expect(together.first == "/Applications/CCwiki.app")
        #expect(together.second == "/Applications/CCwiki 2.app")
        #expect(InstallationCheck.abbreviatedPath(c, home: home) == "~/Downloads/CCwiki.app")
    }

    // MARK: Finding copies

    @Test("other copies leave out this one, missing paths, the Trash, other apps and second spellings")
    func copies() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appending(path: "ccwiki-copies-test-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let identifier = "com.axhoover.ccwiki"

        let running = try makeBundle(
            "Downloads/CCwiki.app", in: root, identifier: identifier, version: "0.2.0")
        let installed = try makeBundle(
            "Applications/CCwiki.app", in: root, identifier: identifier, version: "0.1.0", build: "1")
        let trashed = try makeBundle(
            ".Trash/CCwiki.app", in: root, identifier: identifier, version: "0.1.1")
        let stranger = try makeBundle(
            "Other/CCwiki.app", in: root, identifier: "org.example.other", version: "9.0")
        let unreadable = try makeBundle("Broken/CCwiki.app", in: root, identifier: nil, version: "")
        let missing = root.appending(path: "Gone/CCwiki.app")
        let link = root.appending(path: "Link")
        try manager.createSymbolicLink(at: link, withDestinationURL: root.appending(path: "Applications"))
        let throughLink = link.appending(path: "CCwiki.app")
        let runningAgain = URL(fileURLWithPath: running.path(percentEncoded: false) + "/")

        let found = InstallationCheck.copies(
            of: identifier,
            among: [running, runningAgain, installed, trashed, stranger, unreadable, missing,
                    throughLink, installed],
            besides: running)

        #expect(found.count == 1)
        let only = try #require(found.first)
        #expect(only.version == "0.1.0")
        #expect(only.build == "1")
        #expect(only.url.lastPathComponent == "CCwiki.app")
        #expect(only.url.deletingLastPathComponent().lastPathComponent == "Applications")
        #expect(InstallationCheck.path(of: only.url)
            == InstallationCheck.path(of: installed.resolvingSymlinksInPath()))
    }

    // MARK: Replacing

    @Test("a copy that became newer while the question was open is not replaced")
    func installCopyKeepsNewer() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appending(path: "ccwiki-install-test-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let identifier = "com.axhoover.ccwiki"
        let running = try makeBundle(
            "Downloads/CCwiki.app", in: root, identifier: identifier, version: "0.2.0")
        let installed = try makeBundle(
            "Applications/CCwiki.app", in: root, identifier: identifier, version: "0.3.0")

        await #expect(throws: InstallationCheck.Failure.self) {
            try await InstallationCheck.installCopy(of: running, over: installed)
        }
        #expect(try UpdateInstaller.inspect(bundle: installed).version == "0.3.0")
        #expect(try UpdateInstaller.inspect(bundle: running).version == "0.2.0")
    }
}
