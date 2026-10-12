import Observation
import SwiftUI

/// The papers behind reference pages: fetched only when asked, kept in
/// `AppPaths.papers`, shown in a window of their own
/// (plans/reader-comforts.md §2).
///
/// Phase 0 declares what the rest of the app calls. Track C fills it: the
/// fetch, the store, and the state each paper window shows (C5).
@MainActor
@Observable
final class PaperLibrary {

    /// Under the screenshot harness, a temporary store and the fixture
    /// transport, never the real library or the network (§4.4).
    init(paths: AppPaths) {}

    /// Show Paper: fetch the paper unless it is there or on its way.
    /// Nothing to fetch yet.
    func show(_ page: WikiPage) {}

    /// The `paper:<path>` step of `make shots`: the paper window for the
    /// reference at `referencePath`. Nothing to show yet.
    static func applyShot(
        _ referencePath: String, model: AppModel, openWindow: OpenWindowAction
    ) async {}
}
