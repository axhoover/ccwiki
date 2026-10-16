import Foundation
import Testing
@testable import CCwiki

/// Every progress report's host, in order, whichever thread made it.
///
/// `@unchecked Sendable` with a lock, as `ProgressLog` is: the fetcher
/// reports from wherever its transport runs.
private final class HostLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(url.host() ?? url.absoluteString)
    }

    var hosts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// A DOI whose landing page names its PDF on another host; the PDF reports
/// part of itself and stalls until its fetch is cancelled.
private struct PDFOnAnotherHost: PaperTransport {
    static let landing = "https://doi.org/10.1007/abc"
    static let pdf = "https://link.springer.com/content/pdf/10.1007/abc.pdf"

    func download(
        _ url: URL, maximumBytes: Int64,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> PaperDownload {
        guard url.absoluteString == Self.landing else {
            progress(100, 250)
            try await Task.sleep(for: .seconds(60))
            throw URLError(.timedOut)
        }
        let page = #"<meta name="citation_pdf_url" content="\#(Self.pdf)">"#
        let file = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-landing-\(UUID().uuidString)")
        try Data(page.utf8).write(to: file)
        guard let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html"])
        else { throw URLError(.badServerResponse) }
        let size = Int64(page.utf8.count)
        progress(size, size)
        return PaperDownload(response: response, file: file, bytes: size)
    }
}

/// Regressions in the palettes and the paper window's download.
@Suite @MainActor
struct FixesSearchTests {

    // MARK: Return before the results are in

    @Test("Return on rows that are the results for the text opens at once")
    func returnOnSettledResults() {
        var key = PaletteReturn()
        let opened = key.press(.here, query: "lwe", resultsQuery: "lwe")
        #expect(opened == .here)
        #expect(key.pending?.query == nil)
    }

    @Test("Return on the last query's rows waits for its own results, then opens")
    func returnWaitsForResults() {
        var key = PaletteReturn()
        // "ot" typed over "lwe", Return inside the debounce: the rows are LWE's.
        let pressed = key.press(.here, query: "ot", resultsQuery: "lwe")
        #expect(pressed == nil)
        #expect(key.pending?.query == "ot")

        // Results for other text open nothing, and the Return still waits.
        let early = key.resultsChanged(to: "o", query: "ot")
        #expect(early == nil)
        #expect(key.pending?.query == "ot")

        let landed = key.resultsChanged(to: "ot", query: "ot")
        #expect(landed == .here)
        #expect(key.pending?.query == nil)

        // Opened once only.
        let again = key.resultsChanged(to: "ot", query: "ot")
        #expect(again == nil)
    }

    @Test("⌘Return waits as Return does, and opens where it asked")
    func commandReturnWaits() {
        var key = PaletteReturn()
        let pressed = key.press(.newTab(inBackground: true), query: "ot", resultsQuery: "lwe")
        #expect(pressed == nil)
        let landed = key.resultsChanged(to: "ot", query: "ot")
        #expect(landed == .newTab(inBackground: true))
    }

    @Test("typing after Return drops it; a late report of its own keystroke does not")
    func typingDropsReturn() {
        var key = PaletteReturn()
        _ = key.press(.here, query: "ot", resultsQuery: "lwe")
        key.queryChanged(to: "otx")
        #expect(key.pending?.query == nil)
        let typedOn = key.resultsChanged(to: "otx", query: "otx")
        #expect(typedOn == nil)

        // Back to text the rows are already for: the Return was for other text.
        _ = key.press(.here, query: "lwex", resultsQuery: "lwe")
        key.queryChanged(to: "lwe")
        #expect(key.pending?.query == nil)

        // The change to the text Return was pressed on, reported after it.
        _ = key.press(.here, query: "ot", resultsQuery: "lwe")
        key.queryChanged(to: "ot")
        #expect(key.pending?.query == "ot")
        let landed = key.resultsChanged(to: "ot", query: "ot")
        #expect(landed == .here)
    }

    // MARK: The host a download is from

    private static var pdf: Data {
        (try? Data(contentsOf: PaperFixtures.fixturePDF)) ?? Data()
    }

    @Test("each progress report names its own request's URL, not the first link's")
    func progressNamesEachRequest() async throws {
        let page = PaperFixtures.reference("BGI15", source: "https://doi.org/10.1007/abc")
        let landing = #"<meta name="citation_pdf_url" content="/content/pdf/10.1007/abc.pdf">"#
        let transport = ScriptedTransport(replies: [
            "https://doi.org/10.1007/abc": .body(
                status: 200, type: "text/html", data: Data(landing.utf8),
                finalURL: URL(string: "https://link.springer.com/chapter/10.1007/abc")!),
            "https://link.springer.com/content/pdf/10.1007/abc.pdf": .body(
                status: 200, type: "application/pdf", data: Self.pdf),
        ])
        let log = HostLog()
        let result = await PaperFetcher(transport: transport).fetch(PaperSource(page: page)) {
            _, _, url in log.record(url)
        }
        let paper = try result.get()
        defer { try? FileManager.default.removeItem(at: paper.file) }
        #expect(log.hosts == ["doi.org", "doi.org", "link.springer.com", "link.springer.com"])

        // A link that fails hands over to the next, on a host of its own.
        let moved = PaperFixtures.reference(
            "HPS98", source: "https://ntru.org/f/ntru-20190330.pdf",
            bibtex: "@misc{HPS98, url = {https://eprint.iacr.org/1998/005}}")
        let fallback = ScriptedTransport(replies: [
            "https://ntru.org/f/ntru-20190330.pdf": .failure(URLError(.cannotFindHost)),
            "https://eprint.iacr.org/1998/005.pdf": .body(
                status: 200, type: "application/pdf", data: Self.pdf),
        ])
        let movedLog = HostLog()
        let second = await PaperFetcher(transport: fallback).fetch(PaperSource(page: moved)) {
            _, _, url in movedLog.record(url)
        }
        let secondPaper = try second.get()
        defer { try? FileManager.default.removeItem(at: secondPaper.file) }
        #expect(movedLog.hosts == ["ntru.org", "eprint.iacr.org", "eprint.iacr.org"])
    }

    @Test("while a landing page's PDF downloads, the paper window names the PDF's host")
    func downloadingNamesTheCurrentHost() async throws {
        let root = try PaperFixtures.temporaryDirectory("library")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PaperStore(directory: root.appending(path: "papers")) {
            try FileManager.default.removeItem(at: $0)
        }
        let papers = PaperLibrary(store: store, transport: PDFOnAnotherHost())
        let page = PaperFixtures.reference("BGI15", source: PDFOnAnotherHost.landing)

        papers.show(page)
        guard case .downloading(let first, _, _) = papers.state(for: page.path) else {
            Issue.record("Show Paper starts a download")
            return
        }
        #expect(first == "doi.org")

        // Up to ten seconds: the suites share the main actor, and a loaded
        // runner is slow. A pass leaves as soon as the PDF's bytes arrive.
        var state = papers.state(for: page.path)
        for _ in 0..<1_000 {
            if case .downloading(_, let received, _) = state, received == 100 { break }
            try await Task.sleep(for: .milliseconds(10))
            state = papers.state(for: page.path)
        }
        guard case .downloading(let host, let received, _) = state, received == 100 else {
            Issue.record("expected the PDF's download, got \(state)")
            return
        }
        #expect(host == "link.springer.com")
        papers.cancel(page.path)
    }
}
