import AppKit
import CoreServices
import CryptoKit
import Darwin
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
/// cannot. Whether this copy can be replaced at all is settled before
/// anything is downloaded. The download and the checks happen in a
/// temporary directory. The new bundle is then staged on the installed
/// one's volume and exchanged with it in one atomic step where the volume
/// supports it (`renamex_np` with `RENAME_SWAP`; elsewhere three renames
/// that undo themselves on failure), so on APFS the app's path holds a
/// whole bundle, old or new, at every moment. The old bundle is deleted
/// rather than kept in the Trash as a second copy, and LaunchServices is
/// told the path now holds the new version. The relaunch is last, and only
/// after the swap.
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
        case moved
        case inTrash
        case translocated
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
            case .moved:
                "This copy of CCwiki was moved or deleted after it was opened, so it cannot "
                    + "replace itself. Quit it, open CCwiki from Applications, and update again."
            case .inTrash:
                "This copy of CCwiki is in the Trash, so it does not replace itself. "
                    + "Move it to Applications, open it from there, and update again."
            case .translocated:
                "macOS is running this copy of CCwiki from a read-only location because it "
                    + "was opened where it was unzipped. Move it to Applications in the Finder, "
                    + "open it from there, and update again."
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
        guard let dictionary = infoDictionary(of: app),
              let identifier = dictionary["CFBundleIdentifier"] as? String,
              let version = dictionary["CFBundleShortVersionString"] as? String
        else { throw Failure.noBundle }
        return BundleInfo(url: app, identifier: identifier, version: version)
    }

    /// `Contents/Info.plist`, read from disk rather than through `Bundle`,
    /// which caches what it read the first time.
    private static func infoDictionary(of app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return object as? [String: Any]
    }

    // MARK: The whole procedure

    /// Download, verify, unpack, check, swap. Returns the installed bundle's
    /// URL, which is the same place `current` was. Does not relaunch. When
    /// `current` already holds this release or a newer one, it is left as
    /// it is and that URL is returned all the same.
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
        // A copy that cannot be replaced is refused before anything is
        // downloaded, or the daily check would fetch the whole release every
        // day only to refuse it. Step 5 asks again.
        _ = try replaceableCopy(at: current, identifier: expectedIdentifier)

        let manager = FileManager.default
        let scratch = manager.temporaryDirectory
            .appending(path: "ccwiki-update-\(ProcessInfo.processInfo.processIdentifier)")
        try? manager.removeItem(at: scratch)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: scratch) }

        // 1. Download both files into a scratch directory.
        report("Downloading CCwiki \(release.version)…")
        let archive = try await download(archiveURL, to: scratch.appending(path: "release.zip"),
                                         session: session)
        let signatureFile = try await download(
            signatureURL, to: scratch.appending(path: "release.zip.sig"), session: session)

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
        let unpacked = scratch.appending(path: "unpacked")
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

        // 5. Whether this copy can still be replaced, since the download
        //    took a while, and whether it should be. Something may have put
        //    this version or a newer one here since this copy started:
        //    another copy's update, or a download by hand. That bundle
        //    stays. A development version with our identifier is a stale
        //    build from before the dev channel, and counts as older.
        report("Installing…")
        let present = try replaceableCopy(at: current, identifier: expectedIdentifier)
        if !UpdateChecker.isDevelopmentVersion(present.version),
           !UpdateChecker.isNewer(release.version, than: present.version) {
            return current
        }

        // 6. Stage the new bundle on the installed one's volume, so the swap
        //    is a rename and never a copy, then swap it in and delete the old
        //    one (`replace`). A running bundle can be swapped out: the
        //    process keeps its mapped files.
        let staging: URL
        do {
            staging = try stagingDirectory(appropriateFor: current)
        } catch {
            throw Failure.swap(error.localizedDescription)
        }
        // Deleted with whatever is in it, unless that is the bundle that was
        // installed: see the last catch below.
        var keepsStaging = false
        defer {
            if !keepsStaging { try? manager.removeItem(at: staging) }
        }
        let staged = staging.appending(path: current.lastPathComponent)
        do {
            try manager.moveItem(at: info.url, to: staged)
        } catch {
            throw Failure.swap(error.localizedDescription)
        }
        do {
            try replace(current, with: staged)
        } catch {
            // A swap that could not be undone, whose old bundle could not be
            // moved beside the app either, leaves that bundle here, and it
            // is the only copy of it. The error says where; it stays there.
            // Anything here that is not plainly the new bundle stays too.
            if manager.fileExists(atPath: staged.path(percentEncoded: false)),
               (try? inspect(bundle: staged))?.version != info.version {
                keepsStaging = true
            }
            throw error
        }
        return current
    }

    /// The copy at `current`, provided it can be replaced. It must still be
    /// there and still be this app: `current` is `Bundle.main.bundleURL`,
    /// fixed at launch, and a running copy can be moved to the Trash or
    /// deleted after that. It must not be in a Trash or behind App
    /// Translocation, where replacing it would not help, and its folder must
    /// be writable. Each refusal says how to fix it.
    private static func replaceableCopy(at current: URL, identifier: String) throws -> BundleInfo {
        guard let present = try? inspect(bundle: current), present.identifier == identifier else {
            throw Failure.moved
        }
        if BundleLocation.isInTrash(current) { throw Failure.inTrash }
        if BundleLocation.isTranslocated(current) { throw Failure.translocated }
        let parent = current.deletingLastPathComponent().path(percentEncoded: false)
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw Failure.notWritable(parent)
        }
        return present
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

// MARK: - Replacing a bundle

/// The swap on its own, apart from the download and the checks, so the
/// launch check can put a newer copy over an older one the same way.
extension UpdateInstaller {

    /// A fresh, empty directory on `destination`'s volume, for a bundle that
    /// will be swapped in: within one volume a move is a rename, across
    /// volumes it is a copy. The system's item-replacement directory when it
    /// gives one, else a hidden sibling of `destination`. The caller deletes
    /// it.
    static func stagingDirectory(appropriateFor destination: URL) throws -> URL {
        let manager = FileManager.default
        if let directory = try? manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: destination, create: true) {
            return directory
        }
        let sibling = destination.deletingLastPathComponent().appending(
            path: ".\(destination.lastPathComponent).staging-\(UUID().uuidString)",
            directoryHint: .isDirectory)
        try manager.createDirectory(at: sibling, withIntermediateDirectories: false)
        return sibling
    }

    /// Puts the bundle at `replacement` where `installed` is, and deletes the
    /// one that was there.
    ///
    /// The two are exchanged (`exchange`: in one step where the volume can,
    /// so `installed`'s path never stands empty), and the result is read
    /// back: unless the path now reports the replacement's identifier and
    /// version, the exchange is undone. The old bundle, now at
    /// `replacement`'s path, is deleted and never moved to the Trash. If it
    /// cannot be deleted it stays there, which is a temporary directory when
    /// `replacement` came from `stagingDirectory`. Last, LaunchServices hears
    /// about the new bundle; tests pass `false` so as not to register their
    /// fake apps.
    ///
    /// `replacement` must be on `installed`'s volume. Throws `Failure.swap`,
    /// leaving `installed` as it was. The one exception is a read-back that
    /// fails and an undo that fails after it: then the old bundle is moved
    /// beside `installed` as `<name>.previous` rather than left for the
    /// caller to delete with its staging directory, and the error says
    /// where it is.
    static func replace(_ installed: URL, with replacement: URL,
                        refreshingLaunchServices refresh: Bool = true) throws {
        let incoming: BundleInfo
        do {
            incoming = try inspect(bundle: replacement)
        } catch {
            throw Failure.swap("The new copy has no readable Info.plist.")
        }
        try exchange(installed, replacement)
        let present = try? inspect(bundle: installed)
        guard present?.identifier == incoming.identifier, present?.version == incoming.version else {
            let mismatch = "After the swap, \(installed.lastPathComponent) did not report "
                + "version \(incoming.version)"
            do {
                try exchange(installed, replacement)
            } catch {
                let kept = keepPrevious(replacement, besides: installed)
                throw Failure.swap(mismatch + ", and the swap could not be undone. The previous "
                    + "copy is at \(kept.path(percentEncoded: false)).")
            }
            throw Failure.swap(mismatch + ", so the swap was undone.")
        }
        try? FileManager.default.removeItem(at: replacement)
        if refresh { refreshLaunchServices(installed) }
    }

    /// Moves the bundle at `old` beside `installed` as `<name>.previous`, the
    /// name older updaters used, so the next launch of a working copy there
    /// clears it away (`removeLegacyLeftovers`). Returns where the bundle
    /// is: `old` itself when it could not be moved.
    private static func keepPrevious(_ old: URL, besides installed: URL) -> URL {
        let previous = installed.deletingLastPathComponent()
            .appending(path: installed.lastPathComponent + ".previous")
        do {
            try renameItem(at: old, to: previous)
            return previous
        } catch {
            return old
        }
    }

    /// Exchanges the items at two paths on one volume: in one step where the
    /// file system can (`renamex_np` with `RENAME_SWAP`, which APFS supports),
    /// else in three renames that undo themselves if one fails.
    static func exchange(_ first: URL, _ second: URL) throws {
        let code: Int32 = first.withUnsafeFileSystemRepresentation { from in
            second.withUnsafeFileSystemRepresentation { to in
                // errno straight after the call, before anything can reset it.
                renamex_np(from, to, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
            }
        }
        switch code {
        case 0:
            return
        case ENOTSUP, EINVAL:
            // A volume that cannot swap, such as HFS+ or a network share.
            try exchangeByRenaming(first, second)
        case EXDEV:
            throw Failure.swap("The new copy is not on the same volume as the installed one.")
        default:
            throw Failure.swap(describe(code))
        }
    }

    /// The exchange in three renames, through a temporary name beside
    /// `first`: `first` aside, `second` into its place, the aside into
    /// `second`'s. A failure undoes the renames already made. Unlike the
    /// one-step swap, it leaves `first`'s path empty for a moment.
    static func exchangeByRenaming(_ first: URL, _ second: URL) throws {
        let aside = first.deletingLastPathComponent()
            .appending(path: ".\(first.lastPathComponent).swap-\(UUID().uuidString)")
        try renameItem(at: first, to: aside)
        do {
            try renameItem(at: second, to: first)
        } catch {
            try? renameItem(at: aside, to: first)
            throw error
        }
        do {
            try renameItem(at: aside, to: second)
        } catch {
            try? renameItem(at: first, to: second)
            try? renameItem(at: aside, to: first)
            throw error
        }
    }

    /// `rename(2)`: one step on one volume, and never the copy that
    /// `FileManager.moveItem` falls back to across volumes.
    private static func renameItem(at source: URL, to destination: URL) throws {
        let code: Int32 = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                rename(from, to) == 0 ? 0 : errno
            }
        }
        guard code == 0 else { throw Failure.swap(describe(code)) }
    }

    /// `ENOTSUP` → "Operation not supported".
    private static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    /// Tells LaunchServices, and through it the Finder, Spotlight and the
    /// Dock, that the bundle at `url` changed: a fresh modification date,
    /// then a forced re-registration, as Sparkle does after an update.
    /// Failures are ignored; the record would catch up by itself, later.
    static func refreshLaunchServices(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path(percentEncoded: false))
        _ = LSRegisterURL(url as CFURL, true)
    }

    /// Deletes what earlier versions of the updater could leave beside the
    /// bundle: `<name>.previous`, the old bundle when the Trash would not
    /// take it, and `<name>.update`, the new one when a swap failed half way.
    /// `replace` still keeps a `<name>.previous` when it can neither confirm
    /// a swap nor undo it. Each goes only if it is a directory whose own
    /// Info.plist names `identifier`, so nothing else that happens to share
    /// the name is touched. Called at launch.
    static func removeLegacyLeftovers(besides bundle: URL, identifier: String) {
        let manager = FileManager.default
        let parent = bundle.deletingLastPathComponent()
        for suffix in [".previous", ".update"] {
            let leftover = parent.appending(path: bundle.lastPathComponent + suffix)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: leftover.path(percentEncoded: false),
                                     isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let named = infoDictionary(of: leftover)?["CFBundleIdentifier"] as? String,
                  named == identifier
            else { continue }
            try? manager.removeItem(at: leftover)
        }
    }
}
