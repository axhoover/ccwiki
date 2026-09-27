import CryptoKit
import Foundation
import Testing
@testable import CCwiki

/// The parts of the installer that decide whether a download is ours and
/// what it contains. The download, unpack and swap need a network and a
/// real bundle, and are exercised by `make package` plus a real update.
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
}
