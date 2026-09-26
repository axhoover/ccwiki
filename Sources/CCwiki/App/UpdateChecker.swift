import Foundation

/// A published release, reduced to what the app needs from it.
struct ReleaseInfo: Equatable, Sendable {
    /// The tag without its leading `v`: `0.2.0`.
    let version: String
    /// The release page, where the zip is.
    let url: URL
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
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CCwiki/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return .noReleases }
        guard status == 200 else { throw Failure.badStatus(status) }
        guard let release = try parse(data) else { return .noReleases }
        return isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
    }

    /// The fields used from `GET /repos/{owner}/{repo}/releases/latest`.
    /// `nil` for a draft or a pre-release, which the endpoint should never
    /// return but the app should never offer.
    static func parse(_ data: Data) throws -> ReleaseInfo? {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: String
            let draft: Bool?
            let prerelease: Bool?
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw Failure.badPayload
        }
        if payload.draft == true || payload.prerelease == true { return nil }
        guard let url = URL(string: payload.html_url) else { throw Failure.badPayload }
        return ReleaseInfo(version: normalize(payload.tag_name), url: url)
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

    /// `build.sh` stamps `0.0.0` on anything that is not a tagged release.
    /// There is nothing to compare such a build against.
    static func isDevelopmentVersion(_ version: String) -> Bool {
        components(version).allSatisfy { $0 == 0 }
    }
}
