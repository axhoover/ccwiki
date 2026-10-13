import Foundation
import Testing
@testable import CCwiki

/// Regressions in the reader's windows and sheets: a PDF from Finder given
/// to a window whose ingest sheet is pinned but not up yet, and the Sync
/// Log's heading once a successful sync has settled.
@Suite @MainActor
struct FixesUiTests {

    private let window = UUID()
    private let other = UUID()

    // MARK: A PDF from Finder and the ingest sheet

    @Test("with no sheet asked for, a PDF from Finder is staged for one")
    func stagedWithNoSheet() {
        #expect(ReaderSession.stagesOpenedPDF(
            sheet: nil, window: window, isStarted: true, hasPendingPDF: false))
        #expect(ReaderSession.stagesOpenedPDF(
            sheet: nil, window: window, isStarted: false, hasPendingPDF: false))
    }

    @Test("a sheet asked for with no reader open takes the PDF that opens its window")
    func stagedForClaimedSheet() {
        // Jobs asked for the sheet with no reader open; the window a PDF
        // from Finder opened claimed it, then was handed the PDF before it
        // started, so before the sheet could appear.
        var target = IngestSheetTarget()
        target.request(in: nil, active: nil)
        #expect(target.claim(by: window))
        #expect(ReaderSession.stagesOpenedPDF(
            sheet: target.window, window: window, isStarted: false, hasPendingPDF: false))
    }

    @Test("a sheet that is up, here or elsewhere, is handed no PDF")
    func refusedWhileUp() {
        // Up in this window: the session has started, and so its views.
        #expect(!ReaderSession.stagesOpenedPDF(
            sheet: window, window: window, isStarted: true, hasPendingPDF: false))
        // Up in another window, started or not.
        #expect(!ReaderSession.stagesOpenedPDF(
            sheet: other, window: window, isStarted: true, hasPendingPDF: false))
        #expect(!ReaderSession.stagesOpenedPDF(
            sheet: other, window: window, isStarted: false, hasPendingPDF: false))
    }

    @Test("a second PDF does not replace the one already waiting for the sheet")
    func firstPDFKept() {
        #expect(!ReaderSession.stagesOpenedPDF(
            sheet: window, window: window, isStarted: false, hasPendingPDF: true))
    }

    // MARK: The Sync Log's heading

    @Test("an idle state with a transcript is a sync that finished, not none")
    func idleWithLog() {
        #expect(SyncLogView.subtitle(for: .idle, hasLog: true) == "The last sync finished.")
        #expect(SyncLogView.subtitle(for: .idle, hasLog: false)
            == "No sync has run since launch.")
    }

    @Test("a sync running, done or failed reads as before")
    func otherStates() {
        #expect(SyncLogView.subtitle(for: .running("Fetching…"), hasLog: true)
            == "Running: Fetching…")
        #expect(SyncLogView.subtitle(for: .succeeded("Already up to date."), hasLog: true)
            == "Already up to date.")
        #expect(SyncLogView.subtitle(for: .failed("git fetch failed (exit 128)."), hasLog: true)
            == "git fetch failed (exit 128).")
    }
}
