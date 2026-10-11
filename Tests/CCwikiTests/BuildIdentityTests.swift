import Foundation
import Testing
@testable import CCwiki

/// A build from source is CCwiki Dev and the release is CCwiki: two bundle
/// ids, two data folders, two URL schemes. These pin the mapping, and that
/// the Info.plist and the script that stamps it agree with the app about it.
struct BuildIdentityTests {

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("only the release's exact bundle id is the release")
    func channels() {
        #expect(BuildIdentity.channel(forBundleIdentifier: "com.axhoover.ccwiki") == .release)
        #expect(BuildIdentity.channel(forBundleIdentifier: "com.axhoover.ccwiki.dev") == .dev)
        #expect(BuildIdentity.channel(forBundleIdentifier: nil) == .dev, "swift run has no bundle")
        #expect(BuildIdentity.channel(forBundleIdentifier: "com.apple.dt.xctest.tool") == .dev,
                "a test runner")
        #expect(BuildIdentity.channel(forBundleIdentifier: "") == .dev)
        #expect(BuildIdentity.channel(forBundleIdentifier: "com.axhoover.ccwiki.previous") == .dev)
        #expect(BuildIdentity.releaseBundleIdentifier != BuildIdentity.devBundleIdentifier)
    }

    @Test("the tests never run as the release")
    func testsAreDev() {
        #expect(BuildIdentity.current == .dev)
        #expect(!BuildIdentity.isRelease)
    }

    @Test("each channel has its own data folder, and the dev one has no space")
    func dataFolders() {
        #expect(BuildIdentity.dataFolderName(for: .release) == "CCwiki")
        #expect(BuildIdentity.dataFolderName(for: .dev) == "CCwiki-Dev")
        #expect(!BuildIdentity.dataFolderName(for: .dev).contains(" "),
                "ingestion worktrees live under it, and their tooling fails on %20")
    }

    @Test("each channel answers to its own scheme; the reader's own stays ccwiki")
    func schemes() {
        #expect(BuildIdentity.externalURLScheme(for: .release) == "ccwiki")
        #expect(BuildIdentity.externalURLScheme(for: .dev) == "ccwiki-dev")
        #expect(BuildIdentity.externalURLScheme(for: .release) == CCwikiURL.scheme)
    }

    @Test("CCwiki Dev reads its ccwiki-dev:// links as the reader's ccwiki://")
    func devLinks() throws {
        let link = try #require(URL(string: "ccwiki-dev://wiki/page/Primitives%2Fprf.md#syntax"))
        let mapped = CCwikiURL.internalString(for: link, channel: .dev)
        #expect(mapped == "ccwiki://wiki/page/Primitives%2Fprf.md#syntax")
        #expect(CCwikiURL.destination(of: mapped) == .page(path: "Primitives/prf.md", anchor: "syntax"))

        // The release does not declare ccwiki-dev://, and does not read it.
        let unmapped = CCwikiURL.internalString(for: link, channel: .release)
        #expect(unmapped == link.absoluteString)
        #expect(CCwikiURL.destination(of: unmapped) == nil)

        // The reader's own scheme passes through untouched on either channel.
        let plain = try #require(URL(string: "ccwiki://wiki/folder/Primitives"))
        #expect(CCwikiURL.internalString(for: plain, channel: .release) == plain.absoluteString)
        #expect(CCwikiURL.internalString(for: plain, channel: .dev) == plain.absoluteString)
    }

    /// `build.sh` fills these in through `scripts/stamp-info-plist.sh`. A
    /// literal in place of one would give every build from source the
    /// release's identity again.
    @Test("Resources/Info.plist carries every placeholder the build stamps")
    func infoPlistPlaceholders() throws {
        let values = try Self.identity(
            ofPlistAt: Self.repositoryRoot.appending(path: "Resources/Info.plist"))
        #expect(values["CFBundleIdentifier"] == "__BUNDLE_ID__")
        #expect(values["CFBundleName"] == "__BUNDLE_NAME__")
        #expect(values["CFBundleDisplayName"] == "__BUNDLE_NAME__")
        #expect(values["CFBundleShortVersionString"] == "__SHORT_VERSION__")
        #expect(values["CFBundleVersion"] == "__BUILD_VERSION__")
        #expect(values["URL name"] == "__URL_NAME__")
        #expect(values["URL scheme"] == "__URL_SCHEME__")
    }

    @Test("the dev channel stamps the identity the app reads as CCwiki Dev")
    func stampedDev() throws {
        let values = try #require(try Self.stamp("dev", version: "0.2.0"))
        #expect(values["CFBundleIdentifier"] == BuildIdentity.devBundleIdentifier)
        #expect(BuildIdentity.channel(forBundleIdentifier: values["CFBundleIdentifier"]) == .dev)
        #expect(values["CFBundleName"] == "CCwiki Dev")
        #expect(values["CFBundleDisplayName"] == "CCwiki Dev")
        #expect(values["CFBundleShortVersionString"] == "0.2.0-dev")
        #expect(values["CFBundleVersion"] == "202610111530")
        #expect(values["URL scheme"] == BuildIdentity.devURLScheme)

        let suffixed = try #require(try Self.stamp("dev", version: "0.2.0-dev"))
        #expect(suffixed["CFBundleShortVersionString"] == "0.2.0-dev", "no second suffix")
    }

    @Test("the release channel stamps the release, and refuses anything but X.Y.Z")
    func stampedRelease() throws {
        let values = try #require(try Self.stamp("release", version: "0.2.0"))
        #expect(values["CFBundleIdentifier"] == BuildIdentity.releaseBundleIdentifier)
        #expect(BuildIdentity.channel(forBundleIdentifier: values["CFBundleIdentifier"]) == .release)
        #expect(values["CFBundleName"] == "CCwiki")
        #expect(values["CFBundleShortVersionString"] == "0.2.0")
        #expect(values["URL scheme"] == BuildIdentity.releaseURLScheme)

        #expect(try Self.stamp("release", version: "0.1.3-dev") == nil)
        #expect(try Self.stamp("release", version: "0.0.0") == nil)
        #expect(try Self.stamp("beta", version: "0.2.0") == nil)
    }

    // MARK: Helpers

    /// Runs `scripts/stamp-info-plist.sh` on the repository's Info.plist. The
    /// stamped identity, or nil when the script refused.
    private static func stamp(_ channel: String, version: String) throws -> [String: String]? {
        let output = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-stamp-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            repositoryRoot.appending(path: "scripts/stamp-info-plist.sh").path(percentEncoded: false),
            channel, version, "202610111530",
            repositoryRoot.appending(path: "Resources/Info.plist").path(percentEncoded: false),
            output.path(percentEncoded: false),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try identity(ofPlistAt: output)
    }

    /// The plist's top-level strings, plus its first URL type's name and
    /// scheme as "URL name" and "URL scheme".
    private static func identity(ofPlistAt url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any] ?? [:]
        var values = plist.compactMapValues { $0 as? String }
        let urlType = (plist["CFBundleURLTypes"] as? [[String: Any]])?.first
        values["URL name"] = urlType?["CFBundleURLName"] as? String
        values["URL scheme"] = (urlType?["CFBundleURLSchemes"] as? [String])?.first
        return values
    }
}
