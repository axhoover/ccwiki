import Foundation
import Testing
@testable import CCwiki

/// A transport that answers from a script, and remembers what it was asked.
struct ScriptedTransport: PaperTransport {

    enum Reply: Sendable {
        /// A response: its status, its media type and its body, from
        /// `finalURL` when a redirect led there, with a declared length
        /// when the server sent one.
        case body(status: Int, type: String?, data: Data, finalURL: URL? = nil,
                  declaredLength: Int64? = nil)
        /// The request fails, as `URLSession` fails it.
        case failure(URLError)
    }

    actor Log {
        private(set) var requests: [URL] = []
        func record(_ url: URL) { requests.append(url) }
    }

    let replies: [String: Reply]
    let log = Log()

    func download(
        _ url: URL, maximumBytes: Int64,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> PaperDownload {
        await log.record(url)
        guard let reply = replies[url.absoluteString] else { throw URLError(.cannotFindHost) }
        switch reply {
        case .failure(let error):
            throw error
        case .body(let status, let type, let data, let finalURL, let declaredLength):
            guard let response = HTTPURLResponse(
                url: finalURL ?? url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: type.map { ["Content-Type": $0] } ?? [:])
            else { throw URLError(.badServerResponse) }
            if let declaredLength, declaredLength > maximumBytes {
                return PaperDownload(response: response, file: nil, bytes: declaredLength)
            }
            if Int64(data.count) > maximumBytes {
                return PaperDownload(response: response, file: nil, bytes: Int64(data.count))
            }
            let file = FileManager.default.temporaryDirectory
                .appending(path: "ccwiki-scripted-\(UUID().uuidString)")
            try data.write(to: file)
            progress(Int64(data.count), Int64(data.count))
            return PaperDownload(response: response, file: file, bytes: Int64(data.count))
        }
    }
}

extension Result where Failure == PaperFailure {
    /// The failure, for comparing: a `FetchedPaper` is not `Equatable`.
    var failureValue: PaperFailure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

struct PaperFetcherTests {

    private static var pdf: Data {
        (try? Data(contentsOf: PaperFixtures.fixturePDF)) ?? Data()
    }

    private static func pdfReply() -> ScriptedTransport.Reply {
        .body(status: 200, type: "application/pdf", data: pdf)
    }

    private static func html(_ body: String, from finalURL: URL? = nil) -> ScriptedTransport.Reply {
        .body(status: 200, type: "text/html; charset=utf-8", data: Data(body.utf8), finalURL: finalURL)
    }

    private static func failing(_ code: URLError.Code) -> ScriptedTransport.Reply {
        .failure(URLError(code))
    }

    private func fetch(
        _ page: WikiPage, _ replies: [String: ScriptedTransport.Reply],
        maximumBytes: Int64 = PaperFetcher.defaultMaximumBytes
    ) async -> (result: Result<FetchedPaper, PaperFailure>, requests: [URL]) {
        let transport = ScriptedTransport(replies: replies)
        let fetcher = PaperFetcher(transport: transport, maximumBytes: maximumBytes)
        let result = await fetcher.fetch(PaperSource(page: page)) { _, _ in }
        if case .success(let paper) = result { try? FileManager.default.removeItem(at: paper.file) }
        return (result, await transport.log.requests)
    }

    private let aabn = PaperFixtures.reference("AABN02", source: "https://eprint.iacr.org/2002/022")
    private let eprintPDF = "https://eprint.iacr.org/2002/022.pdf"

    @Test("the fixture is a one-page PDF CoreGraphics reads")
    func fixture() {
        #expect(PaperFetcher.isReadablePDF(PaperFixtures.fixturePDF))
        #expect(Self.pdf.starts(with: Data("%PDF-".utf8)))
    }

    @Test("an ePrint reference downloads its full text")
    func eprint() async throws {
        let transport = ScriptedTransport(replies: [eprintPDF: Self.pdfReply()])
        let result = await PaperFetcher(transport: transport).fetch(PaperSource(page: aabn)) { _, _ in }
        let paper = try result.get()
        defer { try? FileManager.default.removeItem(at: paper.file) }
        #expect(paper.from == URL(string: eprintPDF))
        #expect(PaperFetcher.isReadablePDF(paper.file))
        #expect(await transport.log.requests == [URL(string: eprintPDF)!])
    }

    @Test("a DOI leads to a landing page whose citation_pdf_url is the PDF")
    func landingPageToPDF() async throws {
        let page = PaperFixtures.reference("BGI15", source: "https://doi.org/10.1007/abc")
        let springer = URL(string: "https://link.springer.com/chapter/10.1007/abc")!
        let (result, requests) = await fetch(page, [
            "https://doi.org/10.1007/abc": Self.html(
                #"<meta name="citation_pdf_url" content="/content/pdf/10.1007/abc.pdf">"#,
                from: springer),
            "https://link.springer.com/content/pdf/10.1007/abc.pdf": Self.pdfReply(),
        ])
        let paper = try result.get()
        #expect(paper.from == URL(string: "https://link.springer.com/content/pdf/10.1007/abc.pdf"))
        #expect(requests.map { $0.host() } == ["doi.org", "link.springer.com"])
    }

    @Test("a landing page without a PDF link is a web page, naming both hosts")
    func landingPageWithoutPDF() async {
        let page = PaperFixtures.reference("BGI15", source: "https://doi.org/10.1007/abc")
        let springer = URL(string: "https://link.springer.com/chapter/10.1007/abc")!
        let (result, _) = await fetch(page, [
            "https://doi.org/10.1007/abc": Self.html("<html><title>Buy this chapter</title></html>",
                                                     from: springer),
        ])
        let failure = PaperFailure.notAPDF(
            landingPage: springer, redirectedFrom: URL(string: "https://doi.org/10.1007/abc"))
        #expect(result.failureValue == failure)
        #expect(failure.message.contains("doi.org led to a page on link.springer.com, not a PDF."))
        #expect(failure.openURL == springer)

        let dblp = PaperFixtures.reference("KGH83", source: "https://dblp.org/search?q=Karnin")
        let (search, _) = await fetch(dblp, [
            "https://dblp.org/search?q=Karnin": Self.html("<html>results</html>"),
        ])
        let searchFailure = search.failureValue
        #expect(searchFailure?.message.hasPrefix("dblp.org sent a web page, not a PDF.") == true)
    }

    @Test("403 is refused, 404 not found, 429 busy, 500 and PostScript unexpected")
    func statuses() async {
        let page = PaperFixtures.reference("X", source: "https://dl.acm.org/doi/10.1145/1")
        let url = "https://dl.acm.org/doi/10.1145/1"
        let link = URL(string: url)!
        func failure(_ reply: ScriptedTransport.Reply) async -> PaperFailure? {
            await fetch(page, [url: reply]).result.failureValue
        }

        #expect(await failure(.body(status: 403, type: "text/html", data: Data()))
            == .refused(status: 403, host: "dl.acm.org", page: link))
        #expect(await failure(.body(status: 404, type: "text/html", data: Data()))
            == .notFound(url: link))
        #expect(await failure(.body(status: 429, type: nil, data: Data()))
            == .busy(host: "dl.acm.org", status: 429))
        #expect(await failure(.body(status: 500, type: "text/html", data: Data()))
            == .unexpected(host: "dl.acm.org", detail: "answered 500", url: link))
        #expect(await failure(.body(status: 200, type: "application/postscript",
                                    data: Data("%!PS-Adobe-3.0".utf8)))
            == .unexpected(host: "dl.acm.org", detail: "sent a PostScript file, not a PDF", url: link))
    }

    @Test("offline stops at once; an unreachable host moves on to the next link")
    func networkFailures() async throws {
        let page = PaperFixtures.reference(
            "HPS98", source: "https://ntru.org/f/ntru-20190330.pdf",
            bibtex: "@misc{HPS98, url = {https://eprint.iacr.org/1998/005}}")
        let ntru = "https://ntru.org/f/ntru-20190330.pdf"
        let eprint = "https://eprint.iacr.org/1998/005.pdf"

        let offline = await fetch(page, [
            ntru: Self.failing(.notConnectedToInternet), eprint: Self.pdfReply(),
        ])
        #expect(offline.result.failureValue == .offline)
        #expect(offline.requests == [URL(string: ntru)!], "nothing else is tried while offline")

        let moved = await fetch(page, [ntru: Self.failing(.cannotFindHost), eprint: Self.pdfReply()])
        let paper = try moved.result.get()
        #expect(paper.from == URL(string: eprint))
        #expect(moved.requests.count == 2)

        let neither = await fetch(page, [
            ntru: Self.failing(.timedOut), eprint: Self.failing(.cannotConnectToHost),
        ])
        #expect(neither.result.failureValue == .unreachable(host: "ntru.org", url: URL(string: ntru)!))
    }

    @Test("a body over the cap, declared or streamed, is too large and keeps nothing")
    func tooLarge() async throws {
        let declared = await fetch(aabn, [
            eprintPDF: .body(status: 200, type: "application/pdf", data: Self.pdf,
                             declaredLength: 240 << 20),
        ])
        #expect(declared.result.failureValue == .tooLarge(
            bytes: 240 << 20, host: "eprint.iacr.org", url: URL(string: eprintPDF)!))

        let streamed = await fetch(aabn, [eprintPDF: Self.pdfReply()], maximumBytes: 100)
        guard case .tooLarge(let bytes, _, _)? = streamed.result.failureValue else {
            Issue.record("expected tooLarge, got \(streamed.result)")
            return
        }
        #expect(bytes > 100)

        // The streaming transport stops at the cap and deletes what it wrote.
        let directory = try PaperFixtures.temporaryDirectory("receive")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stream = AsyncStream<UInt8> { continuation in
            for _ in 0..<5_000 { continuation.yield(0x25) }
            continuation.finish()
        }
        let over = try await URLSessionPaperTransport.receive(
            stream, expected: nil, maximumBytes: 1_000, into: directory) { _, _ in }
        #expect(over.file == nil)
        #expect(over.bytes > 1_000)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false)).isEmpty, "nothing is kept")

        let small = AsyncStream<UInt8> { continuation in
            for byte in Data("%PDF-1.4".utf8) { continuation.yield(byte) }
            continuation.finish()
        }
        let under = try await URLSessionPaperTransport.receive(
            small, expected: 8, maximumBytes: 1_000, into: directory) { _, _ in }
        let file = try #require(under.file)
        #expect(try Data(contentsOf: file) == Data("%PDF-1.4".utf8))
        #expect(under.bytes == 8)
    }

    @Test("a file that claims to be a PDF but has no pages is rejected")
    func unreadable() async {
        let (result, _) = await fetch(aabn, [
            eprintPDF: .body(status: 200, type: "application/pdf", data: Data("%PDF-1.4 garbage".utf8)),
        ])
        #expect(result.failureValue == .unreadable(host: "eprint.iacr.org"))
    }

    @Test("the most useful failure is the one shown")
    func mostUseful() async {
        let page = PaperFixtures.reference(
            "ABC", source: "https://dl.acm.org/doi/10.1145/2",
            bibtex: "@misc{ABC, url = {https://example.org/abc.pdf}}")
        let (result, requests) = await fetch(page, [
            "https://dl.acm.org/doi/10.1145/2": .body(status: 503, type: nil, data: Data()),
            "https://example.org/abc.pdf": .body(status: 403, type: nil, data: Data()),
        ])
        #expect(requests.count == 2)
        #expect(result.failureValue == .refused(
            status: 403, host: "example.org", page: URL(string: "https://example.org/abc.pdf")!))

        let url = URL(string: "https://example.org/x")!
        #expect(PaperFailure.mostUseful([
            .unexpected(host: "a", detail: "answered 500", url: url),
            .unreachable(host: "b", url: url),
            .notFound(url: url),
            .busy(host: "c", status: 429),
        ]) == .notFound(url: url))
        #expect(PaperFailure.mostUseful([]) == nil)

        let none = await fetch(PaperFixtures.reference("NONE", source: nil), [:])
        #expect(none.result.failureValue == .noLink(source: nil))
        #expect(none.requests.isEmpty)
    }

    @Test("failure text names the host and never says 'error' alone")
    func messages() {
        let url = URL(string: "https://dl.acm.org/doi/10.1145/1")!
        let named: [PaperFailure] = [
            .notAPDF(landingPage: url, redirectedFrom: nil),
            .refused(status: 403, host: "dl.acm.org", page: url),
            .notFound(url: url),
            .busy(host: "dl.acm.org", status: 429),
            .unreachable(host: "dl.acm.org", url: url),
            .tooLarge(bytes: 240 << 20, host: "dl.acm.org", url: url),
            .unreadable(host: "dl.acm.org"),
            .unexpected(host: "dl.acm.org", detail: "answered 500", url: url),
            PaperFetcher.failure(for: URLError(.secureConnectionFailed), url: url),
            PaperFetcher.failure(for: URLError(.badServerResponse), url: url),
        ]
        for failure in named {
            #expect(failure.message.contains("dl.acm.org"), "\(failure)")
            #expect(!failure.title.isEmpty && !failure.systemImage.isEmpty)
        }
        let all = named + [.offline, .noLink(source: nil)]
        for failure in all {
            let text = (failure.title + " " + failure.message).lowercased()
            #expect(text != "error" && !text.hasPrefix("error"), "\(failure)")
            #expect(failure.message.hasSuffix("."), "a sentence: \(failure.message)")
        }

        #expect(PaperFailure.notFound(url: URL(string: "https://eprint.iacr.org/2002/022.pdf")!).message
            == "eprint.iacr.org has nothing at /2002/022.pdf. The reference's link may be wrong.")
        // Formatting is the system's; the number and the host are ours.
        let large = PaperFailure.tooLarge(bytes: 240_000_000, host: "ntru.org", url: url).message
        #expect(large.hasPrefix("The PDF from ntru.org is 240"))
        #expect(large.contains("100"))
        #expect(PaperFailure.unreachable(host: "ntru.org", url: url).title == "Couldn't Reach ntru.org")
        #expect(PaperFailure.busy(host: "arxiv.org", status: 429).openURL == nil)
        #expect(PaperFailure.refused(status: 403, host: "dl.acm.org", page: url).openURL == url)
    }
}
