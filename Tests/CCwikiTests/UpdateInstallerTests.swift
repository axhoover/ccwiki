import CryptoKit
import Foundation
import Testing
@testable import CCwiki

/// The parts of the installer that decide whether a download is ours and
/// what it contains, and the swap that puts it in place, run against fake
/// bundles in temporary directories. The download and unpack need a network
/// and a real release, and are exercised by `make package` plus a real
/// update.
struct UpdateInstallerTests {

    @Test("a signature made by the private key verifies, and nothing else does")
    func signatureRoundTrip() throws {
        let key = Curve25519.Signing.PrivateKey()
        let archive = Data("the release zip".utf8)
        let signature = try key.signature(for: archive)
        let text = signature.base64EncodedString() + "\n"

        #expect(UpdateInstaller.verify(archive: archive, signatureText: text, publicKey: key.publicKey))
        #expect(!UpdateInstaller.verify(
            archive: Data("the release zip, tampered".utf8), signatureText: text,
            publicKey: key.publicKey))
        #expect(!UpdateInstaller.verify(
            archive: archive, signatureText: text,
            publicKey: Curve25519.Signing.PrivateKey().publicKey), "another key")
        #expect(!UpdateInstaller.verify(archive: archive, signatureText: "not base64!", publicKey: key.publicKey))
        #expect(!UpdateInstaller.verify(
            archive: archive, signatureText: Data([1, 2, 3]).base64EncodedString(),
            publicKey: key.publicKey), "wrong length")
    }

    @Test("the signing script's file format is what the app reads")
    func signatureFileFormat() {
        // release-sign.swift writes base64 of the 64 raw bytes plus a newline.
        let raw = Data((0..<64).map { UInt8($0) })
        #expect(UpdateInstaller.signature(from: raw.base64EncodedString() + "\n") == raw)
        #expect(UpdateInstaller.signature(from: "  " + raw.base64EncodedString() + "  ") == raw)
        #expect(UpdateInstaller.signature(from: Data(raw.prefix(63)).base64EncodedString()) == nil)
    }

    @Test("an unpacked bundle is identified by its Info.plist")
    func bundleInspection() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-installer-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "CCwiki.app")
        try FileManager.default.createDirectory(
            at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.axhoover.ccwiki",
            "CFBundleShortVersionString": "0.2.0",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appending(path: "Contents/Info.plist"))

        let info = try UpdateInstaller.bundle(in: root)
        #expect(info.identifier == "com.axhoover.ccwiki")
        #expect(info.version == "0.2.0")
        #expect(info.url.lastPathComponent == "CCwiki.app")
    }

    @Test("a directory with no app in it is an error, not a crash")
    func noBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-installer-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: UpdateInstaller.Failure.noBundle) {
            try UpdateInstaller.bundle(in: root)
        }
    }

    @Test("the release's zip and its .sig are picked out of the assets")
    func assets() throws {
        let json = """
            {"tag_name": "v0.2.0", "html_url": "https://github.com/axhoover/ccwiki/releases/tag/v0.2.0",
             "assets": [
               {"name": "CCwiki-0.2.0-macos.zip.sha256", "browser_download_url": "https://example.com/sha"},
               {"name": "CCwiki-0.2.0-macos.zip", "browser_download_url": "https://example.com/zip"},
               {"name": "CCwiki-0.2.0-macos.zip.sig", "browser_download_url": "https://example.com/sig"}
             ]}
            """
        let release = try #require(try UpdateChecker.parse(Data(json.utf8)))
        #expect(release.archiveURL?.absoluteString == "https://example.com/zip")
        #expect(release.signatureURL?.absoluteString == "https://example.com/sig")
        #expect(release.isInstallable)

        let bare = try #require(try UpdateChecker.parse(Data(
            #"{"tag_name": "v0.2.0", "html_url": "https://example.com/r"}"#.utf8)))
        #expect(!bare.isInstallable)
    }

    @Test("the embedded key is either absent or a real Ed25519 public key")
    func embeddedKey() {
        #expect(ReleaseKey.isConfigured == !ReleaseKey.publicKeyBase64.isEmpty)
    }

    // MARK: Swapping

    @Test("the swap exchanges two bundles, one staged on the other's volume")
    func swapExchangesBundles() throws {
        let root = try makeRoot("swap")
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appending(path: "CCwiki.app")
        try makeBundle(at: installed, version: "0.1.0")
        let staging = try UpdateInstaller.stagingDirectory(appropriateFor: installed)
        defer { try? FileManager.default.removeItem(at: staging) }
        let empty = try names(in: staging)
        #expect(empty.isEmpty)
        let incoming = staging.appending(path: "CCwiki.app")
        try makeBundle(at: incoming, version: "0.2.0")

        try UpdateInstaller.exchange(installed, incoming)

        let now = try UpdateInstaller.inspect(bundle: installed)
        let then = try UpdateInstaller.inspect(bundle: incoming)
        #expect(now.version == "0.2.0")
        #expect(then.version == "0.1.0")
    }

    @Test("without RENAME_SWAP, three renames do the same and leave nothing behind")
    func swapByRenaming() throws {
        let root = try makeRoot("renames")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "CCwiki.app")
        let second = root.appending(path: "Incoming.app")
        try makeBundle(at: first, version: "0.1.0")
        try makeBundle(at: second, version: "0.2.0")

        try UpdateInstaller.exchangeByRenaming(first, second)

        let now = try UpdateInstaller.inspect(bundle: first)
        let then = try UpdateInstaller.inspect(bundle: second)
        let left = try names(in: root)
        #expect(now.version == "0.2.0")
        #expect(then.version == "0.1.0")
        #expect(left == ["CCwiki.app", "Incoming.app"])
    }

    @Test("three renames that cannot finish put the first item back")
    func swapByRenamingRollsBack() throws {
        let root = try makeRoot("rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "CCwiki.app")
        try makeBundle(at: first, version: "0.1.0")

        // Nothing at the second path: the second rename fails, the first is undone.
        #expect(throws: UpdateInstaller.Failure.self) {
            try UpdateInstaller.exchangeByRenaming(first, root.appending(path: "Missing.app"))
        }
        let still = try UpdateInstaller.inspect(bundle: first)
        let left = try names(in: root)
        #expect(still.version == "0.1.0")
        #expect(left == ["CCwiki.app"])
    }

    @Test("replace leaves the new version installed and deletes the old one")
    func replaceInstallsAndCleansUp() throws {
        let root = try makeRoot("replace")
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appending(path: "CCwiki.app")
        try makeBundle(at: installed, version: "0.1.0")
        let staging = try UpdateInstaller.stagingDirectory(appropriateFor: installed)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appending(path: "CCwiki.app")
        try makeBundle(at: staged, version: "0.2.0")

        try UpdateInstaller.replace(installed, with: staged, refreshingLaunchServices: false)

        let now = try UpdateInstaller.inspect(bundle: installed)
        #expect(now.version == "0.2.0")
        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)),
                "the old bundle is deleted, not kept anywhere")
        // The staging directory is the caller's to remove; once it is gone,
        // nothing but the app is left beside it: no `.previous`, no `.update`.
        try FileManager.default.removeItem(at: staging)
        let left = try names(in: root)
        #expect(left == ["CCwiki.app"])
    }

    @Test("replace refuses a replacement that is not an app and leaves the installed one alone")
    func replaceRefusesBadReplacement() throws {
        let root = try makeRoot("refuse")
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appending(path: "CCwiki.app")
        try makeBundle(at: installed, version: "0.1.0")
        let broken = root.appending(path: "Broken.app")
        try FileManager.default.createDirectory(
            at: broken.appending(path: "Contents"), withIntermediateDirectories: true)

        #expect(throws: UpdateInstaller.Failure.self) {
            try UpdateInstaller.replace(installed, with: broken, refreshingLaunchServices: false)
        }
        #expect(throws: UpdateInstaller.Failure.self) {
            try UpdateInstaller.replace(
                installed, with: root.appending(path: "Missing.app"), refreshingLaunchServices: false)
        }
        let still = try UpdateInstaller.inspect(bundle: installed)
        let left = try names(in: root)
        #expect(still.version == "0.1.0")
        #expect(left == ["Broken.app", "CCwiki.app"])
    }

    @Test("leftovers from older updaters go only when they are copies of this app")
    func legacyLeftovers() throws {
        let root = try makeRoot("leftovers")
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appending(path: "CCwiki.app")
        try makeBundle(at: installed, version: "0.2.0")
        try makeBundle(at: root.appending(path: "CCwiki.app.previous"), version: "0.1.0")
        try makeBundle(at: root.appending(path: "CCwiki.app.update"),
                       identifier: "com.example.other", version: "1.0")
        try makeBundle(at: root.appending(path: "Other.app.previous"), version: "0.1.0")

        UpdateInstaller.removeLegacyLeftovers(besides: installed, identifier: "com.axhoover.ccwiki")
        let afterFirst = try names(in: root)
        #expect(afterFirst == ["CCwiki.app", "CCwiki.app.update", "Other.app.previous"])

        // The right names on a plain folder and on a file: both stay.
        let update = root.appending(path: "CCwiki.app.update")
        try FileManager.default.removeItem(at: update)
        try FileManager.default.createDirectory(at: update, withIntermediateDirectories: false)
        try Data("not an app".utf8).write(to: root.appending(path: "CCwiki.app.previous"))

        UpdateInstaller.removeLegacyLeftovers(besides: installed, identifier: "com.axhoover.ccwiki")
        let afterSecond = try names(in: root)
        let still = try UpdateInstaller.inspect(bundle: installed)
        #expect(afterSecond
            == ["CCwiki.app", "CCwiki.app.previous", "CCwiki.app.update", "Other.app.previous"])
        #expect(still.version == "0.2.0")
    }

    // MARK: Where a copy is

    @Test("a copy in a Trash, behind App Translocation, or in Applications is told by its path")
    func bundleLocations() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        func at(_ path: String) -> URL { URL(filePath: path) }

        #expect(BundleLocation.isInTrash(at("/Users/someone/.Trash/CCwiki.app")))
        #expect(BundleLocation.isInTrash(at("/Volumes/Backup/.Trashes/501/CCwiki.app")))
        #expect(!BundleLocation.isInTrash(at("/Applications/CCwiki.app")))
        #expect(!BundleLocation.isInTrash(at("/Users/someone/Trash Notes/CCwiki.app")))

        #expect(BundleLocation.isTranslocated(at(
            "/private/var/folders/xy/abc123/T/AppTranslocation/0A1B2C3D-4E5F/d/CCwiki.app")))
        #expect(!BundleLocation.isTranslocated(at("/Users/someone/Downloads/CCwiki.app")))

        for inside in [
            "/Applications/CCwiki.app",
            "/Applications/CCwiki.app/",
            "/Applications/Reading/CCwiki.app",
            "/System/Volumes/Data/Applications/CCwiki.app",
            "/Users/someone/Applications/CCwiki.app",
            "/Users/someone/Applications/Tools/Reading/CCwiki.app",
        ] {
            #expect(BundleLocation.isInApplicationsFolder(at(inside), home: home), "\(inside)")
        }
        for outside in [
            "/Users/someone/Downloads/CCwiki.app",
            "/Users/other/Applications/CCwiki.app",
            "/Applications Old/CCwiki.app",
            "/Volumes/Backup/Applications/CCwiki.app",
            "/Applications",
        ] {
            #expect(!BundleLocation.isInApplicationsFolder(at(outside), home: home), "\(outside)")
        }
    }

    @Test("a symbolic link into a Trash is followed")
    func bundleLocationResolvesLinks() throws {
        let root = try makeRoot("location")
        defer { try? FileManager.default.removeItem(at: root) }
        let trashed = root.appending(path: ".Trash/CCwiki.app")
        try makeBundle(at: trashed, version: "0.1.0")
        let link = root.appending(path: "Shortcut")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: root.appending(path: ".Trash"))

        #expect(BundleLocation.isInTrash(link.appending(path: "CCwiki.app")))
    }

    // MARK: Fake bundles

    /// A fresh directory under the temporary directory; the caller removes it.
    private func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-installer-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A directory that passes for an app: `Contents/Info.plist` and nothing else.
    private func makeBundle(at app: URL, identifier: String = "com.axhoover.ccwiki",
                            version: String) throws {
        try FileManager.default.createDirectory(
            at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appending(path: "Contents/Info.plist"))
    }

    /// What is in `directory`, hidden names included, sorted.
    private func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .sorted()
    }
}
