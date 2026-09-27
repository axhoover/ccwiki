import Foundation

/// The two HTTP shapes the app uses against GitHub: a JSON `GET` and a
/// download to a file. One place for the headers, the status handling and
/// the temporary-file hygiene, used by the update check, the installer and
/// the snapshot fetch.
///
/// Errors from `URLSession` are rethrown untouched, so callers can tell an
/// outage (`URLError`) from a refusal (`Failure.badStatus`).
enum GitHubHTTP {

    enum Failure: LocalizedError, Equatable {
        case badStatus(Int, String)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code, let what): "GitHub answered \(code) for \(what)."
            }
        }
    }

    static var userAgent: String { "CCwiki/\(Bundle.main.shortVersion)" }

    static func request(_ url: URL, json: Bool, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if json { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        return request
    }

    /// A JSON `GET`. Returns the body and the status; the caller decides
    /// which statuses mean what (the releases endpoint's 404 is an answer).
    static func get(_ url: URL, timeout: TimeInterval = 20, session: URLSession = .shared)
        async throws -> (data: Data, status: Int) {
        let (data, response) = try await session.data(for: request(url, json: true, timeout: timeout))
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Download to `destination`, replacing it. Anything but 200 is a
    /// `Failure.badStatus`, and the temporary file is removed either way.
    static func download(_ url: URL, to destination: URL, timeout: TimeInterval = 300,
                         session: URLSession = .shared) async throws -> URL {
        let (temporary, response) = try await session.download(
            for: request(url, json: false, timeout: timeout))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.badStatus(status, url.lastPathComponent)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
