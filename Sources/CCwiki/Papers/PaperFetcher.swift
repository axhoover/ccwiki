import CoreGraphics
import Foundation

/// Why a paper could not be fetched, in words the paper window shows
/// (plans/reader-comforts.md §2.4, §2.7).
///
/// Every case that comes from a site names the real host it heard from, so
/// a reader can tell a publisher's refusal from their own Mac being offline.
enum PaperFailure: Error, Equatable, Sendable {
    /// The reference has no link CCwiki can download from.
    case noLink(source: URL?)
    /// The Mac is offline. Not a fault: a paper already kept opens anyway.
    case offline
    /// A web page with no PDF named on it, reached from `redirectedFrom`
    /// when that was another host.
    case notAPDF(landingPage: URL, redirectedFrom: URL?)
    /// 401, 402 or 403: a subscription, or a site that refuses apps.
    case refused(status: Int, host: String, page: URL)
    /// 404 or 410.
    case notFound(url: URL)
    /// 429 or 503: asked to wait.
    case busy(host: String, status: Int)
    /// The host did not answer: gone, or slow.
    case unreachable(host: String, url: URL)
    /// Over the download cap. A PDF you add can be any size.
    case tooLarge(bytes: Int64, host: String, url: URL)
    /// It said it was a PDF, and CoreGraphics found no pages in it.
    case unreadable(host: String)
    /// Anything else, with what the host did: "answered 500".
    case unexpected(host: String, detail: String, url: URL)

    var title: String {
        switch self {
        case .noLink: "No Link to Download"
        case .offline: "Offline"
        case .notAPDF: "Web Page, Not a PDF"
        case .refused: "Download Refused"
        case .notFound: "Nothing at This Link"
        case .busy: "Site Busy"
        case .unreachable(let host, _): "Couldn't Reach \(host)"
        case .tooLarge: "Too Large to Keep"
        case .unreadable: "Not a Readable PDF"
        case .unexpected: "Couldn't Download the Paper"
        }
    }

    var message: String {
        let browser = "If you can get the paper in your browser, download it and drop it here."
        switch self {
        case .noLink:
            return "This reference has no link CCwiki can download from. "
                + "If you have the paper, drop the PDF here."
        case .offline:
            return "The paper is not in the library yet. Connect to the internet and try again, "
                + "or drop in a copy of the PDF."
        case .notAPDF(let landingPage, let redirectedFrom):
            let host = Self.host(of: landingPage)
            if let redirectedFrom {
                let from = Self.host(of: redirectedFrom)
                return "\(from) led to a page on \(host), not a PDF. \(browser)"
            }
            return "\(host) sent a web page, not a PDF. \(browser)"
        case .refused(let status, let host, _):
            return "\(host) answered \(status). The paper may need a subscription, or the site "
                + "may not accept downloads from apps. \(browser)"
        case .notFound(let url):
            return "\(Self.host(of: url)) has nothing at \(url.path(percentEncoded: false)). "
                + "The reference's link may be wrong."
        case .busy(let host, let status):
            return "\(host) asked CCwiki to wait (\(status))."
        case .unreachable(let host, _):
            return "\(host) did not answer. The site may be down, or the link may be out of date."
        case .tooLarge(let bytes, let host, _):
            // The cap is 100 << 20 bytes, which binary units call 100 MB.
            let cap = PaperFetcher.defaultMaximumBytes
            let capText = ByteCountFormatter.string(fromByteCount: cap, countStyle: .binary)
            // A declared length is exact; a stream stopped at the cap is not.
            let size = bytes > cap + (1 << 20)
                ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                : "over " + capText
            return "The PDF from \(host) is \(size). CCwiki downloads papers up to \(capText); "
                + "a PDF you add yourself can be any size."
        case .unreadable(let host):
            return "The file from \(host) does not open as a PDF."
        case .unexpected(let host, let detail, _):
            return "\(host) \(detail)."
        }
    }

    var systemImage: String {
        switch self {
        case .noLink, .notFound, .unreadable: "doc.questionmark"
        case .offline: "wifi.slash"
        case .notAPDF: "globe"
        case .refused: "lock.doc"
        case .busy: "clock"
        case .unreachable: "network.slash"
        case .tooLarge: "doc"
        case .unexpected: "exclamationmark.triangle"
        }
    }

    /// The URL an "Open on <host>" button opens, if the state has one: the
    /// URL that was tried (the landing page, the missing file), never the
    /// host's front page.
    var openURL: URL? {
        switch self {
        case .notAPDF(let landingPage, _): landingPage
        case .refused(_, _, let page): page
        case .notFound(let url), .unreachable(_, let url), .tooLarge(_, _, let url),
             .unexpected(_, _, let url): url
        case .noLink, .offline, .busy, .unreadable: nil
        }
    }

    /// When no candidate succeeds, the failure worth showing: the one that
    /// says most about why, and so what to do. Ties go to the earliest.
    static func mostUseful(_ failures: [PaperFailure]) -> PaperFailure? {
        failures.min { $0.usefulness < $1.usefulness }
    }

    /// Lower is more useful (§2.4).
    private var usefulness: Int {
        switch self {
        case .refused: 0
        case .notAPDF: 1
        case .notFound: 2
        case .busy: 3
        case .unreachable: 4
        case .tooLarge: 5
        case .unreadable: 6
        case .unexpected: 7
        case .offline: 8
        case .noLink: 9
        }
    }

    private static func host(of url: URL) -> String {
        url.host() ?? url.absoluteString
    }
}

/// One answer from a `PaperTransport`.
struct PaperDownload: Sendable {
    let response: HTTPURLResponse
    /// The body, in a temporary file the caller now owns. Nil when it was
    /// over the cap, and then nothing is kept.
    let file: URL?
    /// Received, or the declared length.
    let bytes: Int64
}

/// How a paper is fetched: `URLSessionPaperTransport` for real, a fake in
/// the tests, `FixturePaperTransport` for the shots.
protocol PaperTransport: Sendable {
    /// Streams `url` to a temporary file, stopping at `maximumBytes`.
    /// Throws `URLError` when the request fails.
    func download(
        _ url: URL, maximumBytes: Int64,
        progress: @escaping @Sendable (_ received: Int64, _ expected: Int64?) -> Void
    ) async throws -> PaperDownload
}

/// A paper, fetched and verified, in a temporary file the caller now owns.
struct FetchedPaper: Sendable {
    let file: URL
    /// The link it was asked for at: what the paper window names as its
    /// source.
    let from: URL
}

/// Works through a reference's candidates until one yields a PDF
/// (plans/reader-comforts.md §2.4).
///
/// A landing page that names its PDF (`citation_pdf_url`) has that link
/// tried next. Offline stops at once; any other failure is recorded and the
/// next candidate tried, and if none succeeds the most useful failure is the
/// answer. A PDF is accepted only when CoreGraphics finds a page in it.
struct PaperFetcher: Sendable {

    /// 100 MB: a long thesis with figures is a few tens.
    static let defaultMaximumBytes: Int64 = 100 << 20
    /// Landing pages that name a PDF that is another landing page could go
    /// on for ever; nothing real needs more requests than this.
    static let maximumRequests = 8

    private let transport: any PaperTransport
    private let maximumBytes: Int64

    init(transport: any PaperTransport, maximumBytes: Int64 = 100 << 20) {
        self.transport = transport
        self.maximumBytes = maximumBytes
    }

    func fetch(
        _ source: PaperSource, progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async -> Result<FetchedPaper, PaperFailure> {
        guard !source.candidates.isEmpty else { return .failure(.noLink(source: source.sourceURL)) }

        var queue = source.candidates.map(\.url)
        var tried: Set<String> = []
        var failures: [PaperFailure] = []

        while !queue.isEmpty, tried.count < Self.maximumRequests, !Task.isCancelled {
            let url = queue.removeFirst()
            guard tried.insert(url.absoluteString).inserted else { continue }

            switch await attempt(url, progress: progress) {
            case .paper(let paper):
                return .success(paper)
            case .follow(let link, let otherwise):
                // Next, ahead of the reference's other links: the page named
                // it. A page that names a link already tried is just a page.
                guard !tried.contains(link.absoluteString) else {
                    failures.append(otherwise)
                    continue
                }
                queue.removeAll { $0.absoluteString == link.absoluteString }
                queue.insert(link, at: 0)
            case .failed(.offline):
                return .failure(.offline)
            case .failed(let failure):
                failures.append(failure)
            }
        }
        return .failure(PaperFailure.mostUseful(failures) ?? .noLink(source: source.sourceURL))
    }

    private enum Attempt {
        case paper(FetchedPaper)
        /// A page that names its PDF: try that, or count the page as one.
        case follow(URL, otherwise: PaperFailure)
        case failed(PaperFailure)
    }

    /// One request, and what its answer means.
    private func attempt(
        _ url: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async -> Attempt {
        let download: PaperDownload
        do {
            download = try await transport.download(
                url, maximumBytes: maximumBytes, progress: progress)
        } catch let error as URLError {
            return .failed(Self.failure(for: error, url: url))
        } catch {
            return .failed(.unexpected(
                host: url.host() ?? url.absoluteString,
                detail: "did not send the paper: \(Self.clause(error))", url: url))
        }

        let response = download.response
        let finalURL = response.url ?? url
        let host = finalURL.host() ?? url.host() ?? finalURL.absoluteString
        let status = response.statusCode
        guard (200..<300).contains(status) else {
            if let file = download.file { try? FileManager.default.removeItem(at: file) }
            return .failed(Self.failure(forStatus: status, host: host, url: finalURL))
        }
        guard let file = download.file else {
            return .failed(.tooLarge(bytes: download.bytes, host: host, url: finalURL))
        }

        let classified = PaperResponse.classify(
            prefix: Self.read(file, upTo: 1024),
            contentType: response.mimeType ?? response.value(forHTTPHeaderField: "Content-Type"),
            finalURL: finalURL,
            html: { String(decoding: Self.read(file, upTo: 2 << 20), as: UTF8.self) })

        switch classified {
        case .pdf:
            guard Self.isReadablePDF(file) else {
                try? FileManager.default.removeItem(at: file)
                return .failed(.unreadable(host: host))
            }
            return .paper(FetchedPaper(file: file, from: url))
        case .html(let link):
            try? FileManager.default.removeItem(at: file)
            let redirected = finalURL.host()?.lowercased() != url.host()?.lowercased()
            let page = PaperFailure.notAPDF(
                landingPage: finalURL, redirectedFrom: redirected ? url : nil)
            if let link, let secure = PaperSource.secure(link) {
                return .follow(secure, otherwise: page)
            }
            return .failed(page)
        case .other(let contentType):
            try? FileManager.default.removeItem(at: file)
            return .failed(.unexpected(
                host: host, detail: "sent \(Self.describe(contentType)), not a PDF", url: finalURL))
        }
    }

    // MARK: Classifying failures

    static func failure(forStatus status: Int, host: String, url: URL) -> PaperFailure {
        switch status {
        case 401, 402, 403: .refused(status: status, host: host, page: url)
        case 404, 410: .notFound(url: url)
        case 429, 503: .busy(host: host, status: status)
        default: .unexpected(host: host, detail: "answered \(status)", url: url)
        }
    }

    /// `SnapshotService.isNetworkFailure` is not this: four of its codes
    /// mean "no network" only when the host is GitHub. For a publisher,
    /// a host that cannot be found or does not answer is that host's
    /// problem, so the next candidate is tried.
    static func failure(for error: URLError, url: URL) -> PaperFailure {
        let host = url.host() ?? url.absoluteString
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff:
            return .offline
        case .cannotFindHost, .cannotConnectToHost, .timedOut, .dnsLookupFailed:
            return .unreachable(host: host, url: url)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .clientCertificateRejected, .clientCertificateRequired:
            return .unexpected(
                host: host, detail: "did not offer a secure connection CCwiki could trust", url: url)
        case .appTransportSecurityRequiresSecureConnection:
            return .unexpected(host: host, detail: "would only answer over plain HTTP", url: url)
        case .httpTooManyRedirects:
            return .unexpected(host: host, detail: "redirected in a loop", url: url)
        case .redirectToNonExistentLocation:
            return .unexpected(host: host, detail: "redirected to nowhere", url: url)
        default:
            return .unexpected(
                host: host, detail: "did not send the paper: \(clause(error))", url: url)
        }
    }

    /// "a PostScript file": what a body that is not a PDF was, for
    /// "<host> sent …, not a PDF".
    static func describe(_ contentType: String?) -> String {
        guard let type = contentType?.lowercased() else { return "a file" }
        switch type {
        case "application/postscript": return "a PostScript file"
        case "application/zip", "application/x-zip-compressed": return "a ZIP archive"
        case "application/gzip", "application/x-gzip", "application/x-tar": return "a compressed file"
        case "text/plain": return "plain text"
        case "application/octet-stream": return "a file"
        default: return type.hasPrefix("image/") ? "an image" : "a \(type) file"
        }
    }

    /// An error's description as the end of "<host> did not send the
    /// paper: …", without its own full stop.
    private static func clause(_ error: any Error) -> String {
        var text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: Files

    /// Whether `url` opens as a PDF with at least one page: what a download
    /// must be before it is kept, and a PDF you add before it is copied.
    static func isReadablePDF(_ url: URL) -> Bool {
        guard let document = CGPDFDocument(url as CFURL) else { return false }
        return document.numberOfPages > 0
    }

    private static func read(_ file: URL, upTo count: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: count)) ?? Data()
    }
}

// MARK: - Transports

/// The real transport: one ephemeral session per paper, which keeps and
/// sends no cookies, names CCwiki in its User-Agent (arXiv asks automated
/// clients to), and streams the body to a temporary file.
struct URLSessionPaperTransport: PaperTransport {

    init() {}

    static var userAgent: String {
        "CCwiki/\(Bundle.main.shortVersion) (macOS; +https://cryptology.city)"
    }

    static let timeout: TimeInterval = 60

    func download(
        _ url: URL, maximumBytes: Int64,
        progress: @escaping @Sendable (_ received: Int64, _ expected: Int64?) -> Void
    ) async throws -> PaperDownload {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = Self.timeout
        let session = URLSession(configuration: configuration)
        // Stops a body abandoned at the cap, and frees the session.
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/pdf, text/html;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            return PaperDownload(response: http, file: nil, bytes: 0)
        }

        let expected = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        // Refused before a byte is read.
        if let expected, expected > maximumBytes {
            return PaperDownload(response: http, file: nil, bytes: expected)
        }
        let received = try await Self.receive(
            bytes, expected: expected, maximumBytes: maximumBytes,
            into: FileManager.default.temporaryDirectory, progress: progress)
        return PaperDownload(response: http, file: received.file, bytes: received.bytes)
    }

    /// Writes `bytes` to a new file in `directory`, reporting progress, and
    /// stops once more than `maximumBytes` have arrived: then the file is
    /// deleted and nil returned with the count received so far.
    static func receive<Bytes: AsyncSequence>(
        _ bytes: Bytes, expected: Int64?, maximumBytes: Int64, into directory: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> (file: URL?, bytes: Int64) where Bytes.Element == UInt8 {
        let file = directory.appending(path: "ccwiki-paper-\(UUID().uuidString).download")
        guard FileManager.default.createFile(
            atPath: file.path(percentEncoded: false), contents: nil)
        else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: file)

        let chunkSize = 256 << 10
        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        var received: Int64 = 0

        func flush() throws {
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
            progress(received, expected)
        }

        do {
            for try await byte in bytes {
                buffer.append(byte)
                received += 1
                if received > maximumBytes {
                    try? handle.close()
                    try? FileManager.default.removeItem(at: file)
                    return (nil, received)
                }
                if buffer.count >= chunkSize { try flush() }
            }
            try flush()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return (file, received)
    }
}

/// The shots' transport: never the network (reader-comforts §4.4).
///
/// It serves `<directory>/<last path component of the URL>`, so
/// `https://eprint.iacr.org/2002/022.pdf` is `022.pdf`, and answers anything
/// else, or everything when there is no directory, as an offline Mac would.
struct FixturePaperTransport: PaperTransport {
    let directory: URL?

    func download(
        _ url: URL, maximumBytes: Int64,
        progress: @escaping @Sendable (_ received: Int64, _ expected: Int64?) -> Void
    ) async throws -> PaperDownload {
        guard let directory else { throw URLError(.notConnectedToInternet) }
        let fixture = directory.appending(path: url.lastPathComponent)
        guard !url.lastPathComponent.isEmpty,
              FileManager.default.fileExists(atPath: fixture.path(percentEncoded: false)),
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/pdf"])
        else { throw URLError(.notConnectedToInternet) }

        let copy = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-paper-\(UUID().uuidString).download")
        try FileManager.default.copyItem(at: fixture, to: copy)
        let size = Int64((try? copy.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        progress(size, size)
        return PaperDownload(response: response, file: copy, bytes: size)
    }
}
