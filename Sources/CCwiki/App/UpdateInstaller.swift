import AppKit
import CryptoKit
import Foundation

/// Downloads a release, proves it is ours, and puts it where this app is.
///
/// No Developer ID is involved, and none is needed: Gatekeeper assesses
/// only files carrying the quarantine attribute, which browsers add to
/// their downloads and this app does not add to its own. A bundle that
/// arrives this way is ad-hoc signed and unquarantined, and launches like
/// the one `make install` put there. What stands in for Apple's signature
/// is an Ed25519 signature over the zip, checked against `ReleaseKey`.
///
/// Every step that could leave the user worse off is ordered so that it
/// cannot: the download and the checks happen in a temporary directory,
/// and the swap moves the old bundle aside before the new one in, and back
/// again if that fails. The relaunch is last, and only after the swap.
enum UpdateInstaller {

    enum Failure: LocalizedError, Equatable {
        case installInProgress
        case keyNotConfigured
        case noArchive
        case noSignature
        case download(String)
        case badSignature
        case extraction(String)
        case noBundle
        case wrongBundle(found: String)
        case wrongVersion(found: String)
        case invalidSignature(String)
        case notWritable(String)
        case swap(String)

        var errorDescription: String? {
            switch self {
            case .installInProgress:
                "An update is already being installed. The status bar shows its progress."
            case .keyNotConfigured:
                "This build has no release key, so it cannot verify a download. "
                    + "Install the update from the release page instead."
            case .noArchive:
                "The release has no macOS zip attached."
            case .noSignature:
                "The release has no .sig file attached, so it cannot be verified."
            case .download(let why):
                "The download failed: \(why)"
            case .badSignature:
                "The download's signature does not verify against CCwiki's release key. "
                    + "Nothing was installed."
            case .extraction(let why):
                "The archive could not be unpacked: \(why)"
            case .noBundle:
                "The archive does not contain an app."
            case .wrongBundle(let found):
                "The archive contains \(found), not CCwiki."
            case .wrongVersion(let found):
                "The archive says it is version \(found), not the version the release promised."
            case .invalidSignature(let why):
                "The unpacked app's code signature is not valid: \(why)"
            case .notWritable(let path):
                "CCwiki cannot replace itself at \(path). Move it to a folder you can write "
                    + "to, or replace it by hand from the release page."
            case .swap(let why):
                "The new app could not be put in place: \(why)"
            }
        }
    }

    /// The name and location of an unpacked app, read from its `Info.plist`.
    struct BundleInfo: Equatable, Sendable {
        let url: URL
        let identifier: String
        let version: String
    }

    // MARK: Verification

    /// The `.sig` file's contents → the 64-byte signature.
    static func signature(from text: String) -> Data? {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              data.count == 64
        else { return nil }
        return data
    }

    static func verify(archive: Data, signatureText: String,
                       publicKey: Curve25519.Signing.PublicKey) -> Bool {
        guard let signature = signature(from: signatureText) else { return false }
        return publicKey.isValidSignature(signature, for: archive)
    }

    /// The first `.app` directly inside `directory`, with what its plist says.
    static func bundle(in directory: URL) throws -> BundleInfo {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        guard let app = entries.first(where: { $0.pathExtension == "app" }) else {
            throw Failure.noBundle
        }
        return try inspect(bundle: app)
    }

    static func inspect(bundle app: URL) throws -> BundleInfo {
        let plist = app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any],
              let identifier = dictionary["CFBundleIdentifier"] as? String,
              let version = dictionary["CFBundleShortVersionString"] as? String
        else { throw Failure.noBundle }
        return BundleInfo(url: app, identifier: identifier, version: version)
    }

    // MARK: The whole procedure

    /// Download, verify, unpack, check, swap. Returns the installed bundle's
    /// URL, which is the same place `current` was. Does not relaunch.
    static func install(
        _ release: ReleaseInfo,
        replacing current: URL,
        expectedIdentifier: String,
        publicKey: Curve25519.Signing.PublicKey?,
        session: URLSession = .shared,
        report: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        guard let publicKey else { throw Failure.keyNotConfigured }
        guard let archiveURL = release.archiveURL else { throw Failure.noArchive }
        guard let signatureURL = release.signatureURL else { throw Failure.noSignature }

        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appending(path: "ccwiki-update-\(ProcessInfo.processInfo.processIdentifier)")
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        // 1. Download both files into the staging directory.
        report("Downloading CCwiki \(release.version)…")
        let archive = try await download(archiveURL, to: staging.appending(path: "release.zip"),
                                         session: session)
        let signatureFile = try await download(
            signatureURL, to: staging.appending(path: "release.zip.sig"), session: session)

        // 2. Verify before anything is unpacked, let alone run.
        report("Verifying the signature…")
        let archiveData = try Data(contentsOf: archive)
        let signatureText = String(decoding: try Data(contentsOf: signatureFile), as: UTF8.self)
        guard verify(archive: archiveData, signatureText: signatureText, publicKey: publicKey) else {
            throw Failure.badSignature
        }

        // 3. Unpack with ditto, which keeps the bundle's structure and
        //    signatures intact; then make sure nothing about it is quarantined.
        report("Unpacking…")
        let unpacked = staging.appending(path: "unpacked")
        try manager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let ditto = await Subprocess.run(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", archive.path(percentEncoded: false),
                        unpacked.path(percentEncoded: false)],
            environment: ProcessInfo.processInfo.environment)
        guard ditto.succeeded else { throw Failure.extraction(ditto.output) }

        let info = try bundle(in: unpacked)
        guard info.identifier == expectedIdentifier else {
            throw Failure.wrongBundle(found: info.identifier)
        }
        guard info.version == release.version else {
            throw Failure.wrongVersion(found: info.version)
        }
        _ = await Subprocess.run(
            executable: "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", info.url.path(percentEncoded: false)],
            environment: ProcessInfo.processInfo.environment)

        // 4. The bundle's own seal, as macOS will check it at launch.
        let codesign = await Subprocess.run(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", info.url.path(percentEncoded: false)],
            environment: ProcessInfo.processInfo.environment)
        guard codesign.succeeded else { throw Failure.invalidSignature(codesign.output) }

        // 5. Swap. A running bundle can be moved: the process keeps its
        //    mapped files. Old aside, new in, old back if that fails.
        report("Installing…")
        let parent = current.deletingLastPathComponent()
        guard manager.isWritableFile(atPath: parent.path(percentEncoded: false)) else {
            throw Failure.notWritable(parent.path(percentEncoded: false))
        }
        let staged = parent.appending(path: current.lastPathComponent + ".update")
        let retired = parent.appending(path: current.lastPathComponent + ".previous")
        try? manager.removeItem(at: staged)
        try? manager.removeItem(at: retired)
        do {
            // Same volume as the destination, so the final rename is atomic.
            try manager.moveItem(at: info.url, to: staged)
            try manager.moveItem(at: current, to: retired)
        } catch {
            try? manager.removeItem(at: staged)
            throw Failure.swap(error.localizedDescription)
        }
        do {
            try manager.moveItem(at: staged, to: current)
        } catch {
            try? manager.moveItem(at: retired, to: current)
            try? manager.removeItem(at: staged)
            throw Failure.swap(error.localizedDescription)
        }
        // The old version goes to the Trash rather than nowhere; if the new
        // one will not launch, it is one drag away.
        try? manager.trashItem(at: retired, resultingItemURL: nil)
        return current
    }

    private static func download(_ url: URL, to destination: URL,
                                 session: URLSession) async throws -> URL {
        do {
            return try await GitHubHTTP.download(url, to: destination, timeout: 120, session: session)
        } catch {
            throw Failure.download(error.localizedDescription)
        }
    }

    // MARK: Relaunch

    /// Start the bundle at `url` as a new process. The new instance is a
    /// different executable, so `NSWorkspace` needs to be told not to just
    /// activate the running one. Throws if it did not start; the caller
    /// quits this instance only on success, so a launch failure never
    /// leaves the user with no app at all.
    @MainActor
    static func relaunch(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
