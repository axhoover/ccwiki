import Foundation

/// Where a copy of the app sits, as far as replacing it or trusting it goes.
///
/// Tests on the path alone: nothing here asks LaunchServices or reads the
/// bundle. Each one standardizes the URL and resolves symbolic links first
/// (for a path that exists), and reads `/System/Volumes/Data/...` as `/...`.
/// Since macOS 10.15 the two are one folder, joined by a firmlink, and
/// LaunchServices reports either spelling.
enum BundleLocation {

    /// In the user's Trash (`~/.Trash`) or a volume's (`/Volumes/X/.Trashes/501`).
    /// LaunchServices refuses to launch anything there (`kLSAppInTrashErr`).
    static func isInTrash(_ url: URL) -> Bool {
        let components = canonicalComponents(url)
        return components.contains(".Trash") || components.contains(".Trashes")
    }

    /// Run through App Translocation: the read-only mirror macOS runs a
    /// quarantined app from when it is opened where it was unpacked. That
    /// copy cannot be replaced, and replacing it would not change the one
    /// in Downloads anyway.
    static func isTranslocated(_ url: URL) -> Bool {
        canonicalPath(url).contains("/AppTranslocation/")
    }

    /// Inside `/Applications` or `~/Applications`, at any depth, so
    /// `/Applications/Reading/CCwiki.app` counts. The folder itself does not.
    static func isInApplicationsFolder(
        _ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let components = canonicalComponents(url)
        let folders = [["Applications"], canonicalComponents(home) + ["Applications"]]
        return folders.contains { folder in
            components.count > folder.count && components.starts(with: folder)
        }
    }

    // MARK: Canonical form

    private static let dataVolume = "/System/Volumes/Data"

    /// Standardized, symlinks resolved, and the data volume's prefix dropped.
    static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        if path == dataVolume || path == dataVolume + "/" { return "/" }
        if path.hasPrefix(dataVolume + "/") { return String(path.dropFirst(dataVolume.count)) }
        return path
    }

    /// `/Applications/CCwiki.app/` → `["Applications", "CCwiki.app"]`.
    private static func canonicalComponents(_ url: URL) -> [String] {
        canonicalPath(url).split(separator: "/").map(String.init)
    }
}
