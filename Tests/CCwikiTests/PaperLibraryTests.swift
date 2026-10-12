import Foundation
import Testing
@testable import CCwiki

/// The state each paper window shows, driven through a scripted transport.
@MainActor
struct PaperLibraryTests {

    /// A transport that never answers until its fetch is cancelled.
    private struct StallingTransport: PaperTransport {
        func download(
            _ url: URL, maximumBytes: Int64,
            progress: @escaping @Sendable (Int64, Int64?) -> Void
        ) async throws -> PaperDownload {
            try await Task.sleep(for: .seconds(60))
            throw URLError(.timedOut)
        }
    }

    /// A landing page, longer than the PDF has yet arrived of, that names
    /// its PDF; then the PDF, which reports part of itself and stalls until
    /// its fetch is cancelled.
    private struct LandingThenStall: PaperTransport {
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
            let page = String(repeating: " ", count: 300)
                + #"<meta name="citation_pdf_url" content="\#(Self.pdf)">"#
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

    private let aabn = PaperFixtures.reference("AABN02", source: "https://eprint.iacr.org/2002/022")
    private let eprintPDF = "https://eprint.iacr.org/2002/022.pdf"

    private static var pdf: Data {
        (try? Data(contentsOf: PaperFixtures.fixturePDF)) ?? Data()
    }

    private func library(
        _ transport: any PaperTransport, in root: URL
    ) -> (PaperLibrary, PaperStore) {
        let trash = root.appending(path: "Trash")
        let store = PaperStore(directory: root.appending(path: "papers")) { file in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: trash.appending(path: file.lastPathComponent))
        }
        return (PaperLibrary(store: store, transport: transport), store)
    }

    /// Until the reference is no longer downloading, or two seconds pass.
    private func settled(_ library: PaperLibrary, _ path: String) async -> PaperLibrary.State {
        for _ in 0..<200 {
            guard case .downloading = library.state(for: path) else { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return library.state(for: path)
    }

    @Test("Show Paper downloads once and keeps the paper")
    func showKeeps() async throws {
        let root = try PaperFixtures.temporaryDirectory("library")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ScriptedTransport(replies: [
            eprintPDF: .body(status: 200, type: "application/pdf", data: Self.pdf),
        ])
        let (papers, store) = library(transport, in: root)

        #expect(papers.state(for: aabn.path) == .notDownloaded)
        papers.show(aabn)
        guard case .downloading(let host, _, _) = papers.state(for: aabn.path) else {
            Issue.record("Show Paper starts a download")
            return
        }
        #expect(host == "eprint.iacr.org")

        guard case .ready(let record, let file) = await settled(papers, aabn.path) else {
            Issue.record("expected the paper, got \(papers.state(for: aabn.path))")
            return
        }
        #expect(record.origin == .downloaded(from: URL(string: eprintPDF)!))
        #expect(file == store.fileURL(for: record))
        #expect(PaperFetcher.isReadablePDF(file))

        // Kept: showing it again asks nothing more of the network, and a
        // library opened afterwards finds it.
        papers.show(aabn)
        #expect(await transport.log.requests.count == 1)
        let (reopened, _) = library(transport, in: root)
        #expect(reopened.state(for: aabn.path) == .ready(record, file: file))
    }

    @Test("the PDF's progress shows after a larger landing page's, not once it passes it")
    func progressPerRequest() async throws {
        let root = try PaperFixtures.temporaryDirectory("library")
        defer { try? FileManager.default.removeItem(at: root) }
        let (papers, _) = library(LandingThenStall(), in: root)
        let page = PaperFixtures.reference("BGI15", source: LandingThenStall.landing)

        papers.show(page)
        var state = papers.state(for: page.path)
        for _ in 0..<200 {
            if case .downloading(_, let received, let expected) = state,
               received == 100, expected == 250 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
            state = papers.state(for: page.path)
        }
        guard case .downloading(_, let received, let expected) = state else {
            Issue.record("expected a download, got \(state)")
            return
        }
        #expect(received == 100)
        #expect(expected == 250)
        papers.cancel(page.path)
    }

    @Test("a paper CCwiki cannot save is CCwiki's failure, in one sentence")
    func keepFails() async throws {
        let root = try PaperFixtures.temporaryDirectory("library")
        defer { try? FileManager.default.removeItem(at: root) }
        // A file where the papers folder goes: nothing can be kept there.
        try Data().write(to: root.appending(path: "papers"))
        let (papers, _) = library(
            ScriptedTransport(replies: [
                eprintPDF: .body(status: 200, type: "application/pdf", data: Self.pdf),
            ]),
            in: root)

        papers.show(aabn)
        guard case .failed(let failure) = await settled(papers, aabn.path) else {
            Issue.record("expected a failure, got \(papers.state(for: aabn.path))")
            return
        }
        #expect(failure.message.hasPrefix(
            "eprint.iacr.org sent the paper, but CCwiki couldn't save it: "), "\(failure.message)")
        #expect(failure.message.hasSuffix(".") && !failure.message.hasSuffix(".."),
                "\(failure.message)")
    }

    @Test("a failure is kept until Try Again, which fetches afresh")
    func failureAndRetry() async throws {
        let root = try PaperFixtures.temporaryDirectory("library")
        defer { try? FileManager.default.removeItem(at: root) }
        let (papers, _) = library(
            ScriptedTransport(replies: [eprintPDF: .failure(URLError(.notConnectedToInternet))]),
            in: root)

        papers.show(aabn)
        #expect(await settled(papers, aabn.path) == .failed(.offline))
        #expect(papers.lastFailure(for: aabn.path) == .offline)

        papers.retry(aabn)
        guard case .downloading = papers.state(for: aabn.path) else {
            Issue.record("Try Again starts a download")
            return
        }
        #expect(await settled(papers, aabn.path) == .failed(.offline))
    }

    @Test("a reference with no link fails at once, without a request")
    func noLink() throws {
        let root = try PaperFixtures.temporaryDirectory("library")
        defer { try? FileManager.default.removeItem(at: root) }
        let (papers, _) = library(ScriptedTransport(replies: [:]), in: root)
        let page = PaperFixtures.reference("NONE", source: nil)

        papers.show(page)
        #expect(papers.state(for: page.path) == .failed(.noLink(source: nil)))
    }

    @Test("Cancel goes back to not downloaded, and the stopped fetch never lands")
    func cancel() async throws {
        let root = try PaperFixtures.temporaryDirectory("library")
        defer { try? FileManager.default.removeItem(at: root) }
        let (papers, _) = library(StallingTransport(), in: root)

        papers.show(aabn)
        guard case .downloading = papers.state(for: aabn.path) else {
            Issue.record("Show Paper starts a download")
            return
        }
        papers.cancel(aabn.path)
        #expect(papers.state(for: aabn.path) == .notDownloaded)
        try await Task.sleep(for: .milliseconds(200))
        #expect(papers.state(for: aabn.path) == .notDownloaded)
    }

    @Test("a PDF you add replaces a failure, and a file that is not a PDF is refused")
    func adopt() async throws {
        let root = try PaperFixtures.temporaryDirectory("library")
        defer { try? FileManager.default.removeItem(at: root) }
        let (papers, _) = library(
            ScriptedTransport(replies: [eprintPDF: .body(status: 403, type: nil, data: Data())]),
            in: root)

        papers.show(aabn)
        guard case .failed(.refused) = await settled(papers, aabn.path) else {
            Issue.record("expected a refusal")
            return
        }

        let notAPDF = root.appending(path: "notes.pdf")
        try Data("just text".utf8).write(to: notAPDF)
        #expect(throws: PaperLibrary.AdoptionError.self) { try papers.adopt(notAPDF, for: aabn) }

        try papers.adopt(PaperFixtures.fixturePDF, for: aabn)
        guard case .ready(let record, _) = papers.state(for: aabn.path) else {
            Issue.record("expected your PDF, got \(papers.state(for: aabn.path))")
            return
        }
        #expect(record.origin == .addedByYou)
        #expect(papers.lastFailure(for: aabn.path) != nil, "remembered for Remove's warning")
    }

    @Test("Remove From Library goes back to not downloaded")
    func remove() async throws {
        let root = try PaperFixtures.temporaryDirectory("library")
        defer { try? FileManager.default.removeItem(at: root) }
        let (papers, store) = library(ScriptedTransport(replies: [:]), in: root)

        try papers.adopt(PaperFixtures.fixturePDF, for: aabn)
        guard case .ready(let record, _) = papers.state(for: aabn.path) else {
            Issue.record("expected your PDF")
            return
        }
        papers.remove(aabn.path)
        #expect(papers.state(for: aabn.path) == .notDownloaded)
        #expect(store.record(for: aabn.path) == nil)
        #expect(FileManager.default.fileExists(
            atPath: root.appending(path: "Trash/\(record.fileName)").path(percentEncoded: false)))
    }

    @Test("a kept paper whose file is deleted in Finder is not downloaded")
    func fileDeleted() async throws {
        let root = try PaperFixtures.temporaryDirectory("library")
        defer { try? FileManager.default.removeItem(at: root) }
        let (papers, _) = library(ScriptedTransport(replies: [:]), in: root)

        try papers.adopt(PaperFixtures.fixturePDF, for: aabn)
        guard case .ready(_, let file) = papers.state(for: aabn.path) else {
            Issue.record("expected your PDF")
            return
        }
        try FileManager.default.removeItem(at: file)
        #expect(papers.state(for: aabn.path) == .notDownloaded)
    }
}
