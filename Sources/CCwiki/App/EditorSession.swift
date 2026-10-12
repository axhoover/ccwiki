import Foundation
import Observation

/// One editor window's file: its text, the version the job started from,
/// the preview, and saving into the job's worktree (plans/corrections.md
/// §7). The model keeps one per open editor, by its `EditorTarget`.
///
/// Phase 0 declares it; Track D fills it (§11.5).
@MainActor
@Observable
final class EditorSession {

    let target: EditorTarget
    var text = ""
    /// The file at the job's base commit, as bytes decoded once.
    private(set) var original: String?
    private(set) var saveState: SaveState = .saved
    /// 1-based.
    private(set) var cursorLine = 1
    /// Lines to select and scroll to, consumed by the source view.
    private(set) var pendingReveal: LineRange?

    var hasUnsavedText: Bool { false }

    /// The preview's own web view, made on first use with the readers'
    /// data store and text size (§7.4, §17).
    @ObservationIgnored private(set) lazy var preview: WebController =
        WebController(paths: model.paths, webRoot: model.webRoot, pageZoom: model.pageZoom)

    /// The model owns the sessions and outlives every one of them.
    private unowned let model: AppModel

    init(target: EditorTarget, model: AppModel) {
        self.target = target
        self.model = model
    }

    enum SaveState: Sendable, Equatable {
        case saved, saving
        /// The file on disk changed under the editor: by hand, or by
        /// CCwiki's Revert File or Restore.
        case conflict(diskText: String, revertedByCCwiki: Bool)
    }

    func load() async {}

    func textDidChange() {}

    func cursorDidMove(toLine line: Int) {
        cursorLine = line
    }

    func reveal(_ lines: LineRange?) {
        pendingReveal = lines
    }

    /// Writes only while the job is awaiting review.
    func saveNow() async {}

    /// After CCwiki changed the file.
    func reloadFromDisk() async {}

    func revertFile() async {}

    func close() async {}
}
