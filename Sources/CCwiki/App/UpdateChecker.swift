import Foundation

/// A published release, reduced to what the app needs from it.
struct ReleaseInfo: Equatable, Sendable {
    /// The tag without its leading `v`: `0.2.0`.
    let version: String
    /// The release page, where the zip is.
    let url: URL
    /// `CCwiki-<version>-macos.zip`, when the release carries one.
    var archiveURL: URL? = nil
    /// The Ed25519 signature beside it, `<zip>.sig`.
    var signatureURL: URL? = nil

    /// Everything the installer needs is attached.
    var isInstallable: Bool { archiveURL != nil && signatureURL != nil }
}

/// The lightweight update check: tier 1 of `plans/distribution.md` §3.
///
/// One request to the GitHub releases API, a numeric comparison against
/// `CFBundleShortVersionString`, and a link to the release page. No download,
/// no install, no signing keys, no feed to maintain: the GitHub release *is*
/// the feed. Sparkle is the tier above this, if it is ever needed.
enum UpdateChecker {

    static let repository = "axhoover/ccwiki"
    static let releasesPage = "https://github.com/\(repository)/releases"
    private static let endpoint = "https://api.github.com/repos/\(repository)/releases/latest"

    enum Outcome: Equatable, Sendable {
        case available(ReleaseInfo)
        case upToDate
        /// Nothing published yet (the API answers 404).
        case noReleases
    }

    enum Failure: LocalizedError, Equatable {
        case badURL
        case badStatus(Int)
        case badPayload

        var errorDescription: String? {
            switch self {
            case .badURL: "The releases URL is malformed."
            case .badStatus(let code): "GitHub answered \(code)."
            case .badPayload: "GitHub's answer could not be read."
            }
        }
    }

    static func check(currentVersion: String, session: URLSession = .shared) async throws -> Outcome {
        guard let url = URL(string: endpoint) else { throw Failure.badURL }
        let (data, status) = try await GitHubHTTP.get(url, timeout: 15, session: session)
        if status == 404 { return .noReleases }
        guard status == 200 else { throw Failure.badStatus(status) }
        guard let release = try parse(data) else { return .noReleases }
        return isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
    }

    /// The fields used from `GET /repos/{owner}/{repo}/releases/latest`.
    /// `nil` for a draft or a pre-release, which the endpoint should never
    /// return but the app should never offer.
    static func parse(_ data: Data) throws -> ReleaseInfo? {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        struct Payload: Decodable {
            let tag_name: String
            let html_url: String
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]?
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw Failure.badPayload
        }
        if payload.draft == true || payload.prerelease == true { return nil }
        guard let url = URL(string: payload.html_url) else { throw Failure.badPayload }
        var release = ReleaseInfo(version: normalize(payload.tag_name), url: url)
        let assets = payload.assets ?? []
        if let archive = assets.first(where: { isArchiveName($0.name) }) {
            release.archiveURL = URL(string: archive.browser_download_url)
            release.signatureURL = assets
                .first { $0.name == archive.name + ".sig" }
                .flatMap { URL(string: $0.browser_download_url) }
        }
        return release
    }

    /// What `make package` names the zip: `CCwiki-<version>-macos.zip`.
    static func isArchiveName(_ name: String) -> Bool {
        name.hasPrefix("CCwiki-") && name.hasSuffix("-macos.zip")
    }

    /// `v0.2.0` → `0.2.0`.
    static func normalize(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "v" || first == "V" else { return trimmed }
        return String(trimmed.dropFirst())
    }

    /// `1.2.3-beta+7` → `[1, 2, 3]`. A missing or non-numeric component is 0.
    static func components(_ version: String) -> [Int] {
        let core = normalize(version)
            .split(whereSeparator: { $0 == "-" || $0 == "+" })
            .first.map(String.init) ?? ""
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// Component-wise, so `1.10` is newer than `1.9` and `1.2` equals `1.2.0`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate)
        let b = components(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// A build that is not a tagged release: the Makefile stamps `-dev` on
    /// those, and `build.sh` run by hand stamps `0.0.0`. Such a build never
    /// checks on its own and is never replaced by the updater: it is
    /// somebody's work in progress, and a release is not newer than it in
    /// any sense that matters.
    static func isDevelopmentVersion(_ version: String) -> Bool {
        version.lowercased().contains("-dev") || components(version).allSatisfy { $0 == 0 }
    }
}
