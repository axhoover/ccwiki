import AppKit
import Observation
import SwiftUI

/// The papers behind reference pages: fetched only when asked, kept in
/// `AppPaths.papers`, shown in a window of their own
/// (plans/reader-comforts.md §2).
///
/// One state per reference, which every paper window and Show Paper button
/// reads. A paper is fetched only from Show Paper, Download or Try Again:
/// never at launch, never when a reference page is opened, never when the
/// Mac comes back online. One fetch runs per reference at a time.
@MainActor
@Observable
final class PaperLibrary {

    enum State: Equatable {
        case notDownloaded
        case downloading(host: String, received: Int64, expected: Int64?)
        case ready(PaperRecord, file: URL)
        case failed(PaperFailure)
    }

    private let store: PaperStore
    private let fetcher: PaperFetcher

    /// What `papers.json` holds, read once and kept in step with every
    /// change made here: this library is its only writer.
    private var records: [String: PaperRecord]
    /// Downloads and failures. A reference with neither is ready when its
    /// record's file is there, and not downloaded otherwise.
    private var transient: [String: State] = [:]

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// Which fetch a reference is waiting for, so one cancelled or
    /// replaced cannot land afterwards.
    @ObservationIgnored private var fetches: [String: UUID] = [:]
    /// The last fetch's failure for each reference, kept after you add your
    /// own copy: Remove From Library warns that it cannot download again.
    @ObservationIgnored private var lastFailures: [String: PaperFailure] = [:]

    /// Under the screenshot harness, a temporary store and the fixture
    /// transport, never the real library or the network (§4.4): a fixture
    /// must never be recorded in CCwiki Dev's library as the real paper.
    convenience init(paths: AppPaths) {
        if ScreenshotRunner.directory != nil {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "ccwiki-shot-papers-\(UUID().uuidString)")
            let fixtures = ProcessInfo.processInfo.environment["CCWIKI_PAPER_FIXTURES"]
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            self.init(store: PaperStore(directory: directory),
                      transport: FixturePaperTransport(directory: fixtures))
        } else {
            self.init(store: PaperStore(directory: paths.papers),
                      transport: URLSessionPaperTransport())
        }
    }

    init(store: PaperStore, transport: any PaperTransport) {
        self.store = store
        self.fetcher = PaperFetcher(transport: transport)
        self.records = store.records()
    }

    // MARK: State

    func state(for referencePath: String) -> State {
        if let state = transient[referencePath] { return state }
        if let record = records[referencePath], store.fileExists(for: record) {
            return .ready(record, file: store.fileURL(for: record))
        }
        return .notDownloaded
    }

    /// The failure of the last fetch for this reference, if it failed.
    func lastFailure(for referencePath: String) -> PaperFailure? {
        lastFailures[referencePath]
    }

    // MARK: Fetching

    /// Show Paper: fetch the paper unless it is there or on its way.
    func show(_ page: WikiPage) {
        switch state(for: page.path) {
        case .ready, .downloading: return
        case .notDownloaded, .failed: fetch(page)
        }
    }

    /// Try Again: fetch the paper unless it is on its way.
    func retry(_ page: WikiPage) {
        if case .downloading = state(for: page.path) { return }
        fetch(page)
    }

    /// Stop a fetch. The reference goes back to what it was before it:
    /// not downloaded, or the paper already kept.
    func cancel(_ referencePath: String) {
        tasks.removeValue(forKey: referencePath)?.cancel()
        fetches[referencePath] = nil
        if case .downloading = transient[referencePath] { transient[referencePath] = nil }
    }

    private func fetch(_ page: WikiPage) {
        let path = page.path
        cancel(path)
        let source = PaperSource(page: page)
        guard let first = source.candidates.first else {
            fail(path, .noLink(source: source.sourceURL))
            return
        }

        let token = UUID()
        fetches[path] = token
        transient[path] = .downloading(host: first.url.host() ?? "", received: 0, expected: nil)
        let fetcher = self.fetcher
        tasks[path] = Task {
            let result = await fetcher.fetch(source) { received, expected in
                Task { @MainActor in
                    self.progressed(path, token: token, received: received, expected: expected)
                }
            }
            self.finish(path, token: token, source: source, result: result)
        }
    }

    private func progressed(_ path: String, token: UUID, received: Int64, expected: Int64?) {
        guard fetches[path] == token,
              case .downloading(let host, let before, _) = transient[path],
              received > before
        else { return }
        transient[path] = .downloading(host: host, received: received, expected: expected)
    }

    private func finish(
        _ path: String, token: UUID, source: PaperSource, result: Result<FetchedPaper, PaperFailure>
    ) {
        guard fetches[path] == token else {
            // Cancelled or replaced: nothing of it is kept.
            if case .success(let paper) = result { try? FileManager.default.removeItem(at: paper.file) }
            return
        }
        fetches[path] = nil
        tasks[path] = nil

        switch result {
        case .success(let paper):
            do {
                records[path] = try store.keep(paper.file, for: source, origin: .downloaded(from: paper.from))
                transient[path] = nil
                lastFailures[path] = nil
            } catch {
                try? FileManager.default.removeItem(at: paper.file)
                let host = paper.from.host() ?? paper.from.absoluteString
                fail(path, .unexpected(
                    host: host,
                    detail: "sent a PDF CCwiki could not keep: \(error.localizedDescription)",
                    url: paper.from))
            }
        case .failure(let failure):
            fail(path, failure)
        }
    }

    private func fail(_ path: String, _ failure: PaperFailure) {
        transient[path] = .failed(failure)
        lastFailures[path] = failure
    }

    // MARK: Your own copy

    /// Choose PDF… or a drop on the paper window: keep a copy of `pdf` as
    /// this reference's paper, replacing any other, and stop a fetch.
    func adopt(_ pdf: URL, for page: WikiPage) throws {
        guard PaperFetcher.isReadablePDF(pdf) else {
            throw AdoptionError.unreadable(name: pdf.lastPathComponent)
        }
        cancel(page.path)
        records[page.path] = try store.keep(pdf, for: PaperSource(page: page), origin: .addedByYou)
        transient[page.path] = nil
    }

    enum AdoptionError: LocalizedError {
        case unreadable(name: String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "“\(name)” does not open as a PDF."
            }
        }
    }

    /// Remove From Library: the file to the Trash, and the record gone. If
    /// the Trash refuses it, nothing changes, and the Mac says so with a beep.
    func remove(_ referencePath: String) {
        cancel(referencePath)
        do {
            try store.remove(referencePath)
        } catch {
            NSSound.beep()
            return
        }
        records[referencePath] = nil
        transient[referencePath] = nil
    }

    // MARK: Screenshots

    /// The `paper:<path>` step of `make shots`: the paper window for the
    /// reference at `referencePath`. Nothing to show until the window (C6).
    static func applyShot(
        _ referencePath: String, model: AppModel, openWindow: OpenWindowAction
    ) async {}
}
