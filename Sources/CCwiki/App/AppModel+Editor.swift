import SwiftUI

// Editor windows and the review's content, app-wide (plans/corrections.md
// §6.3, §7): the sessions behind the windows, saving them all before a
// publish or a quit, and what the preview and the review render.
//
// Phase 0 declares these; Track D fills them (§11.5).
extension AppModel {

    /// The session for an editor window, made the first time it is asked
    /// for and kept until the window closes.
    func editorSession(for target: EditorTarget) -> EditorSession {
        if let existing = editorSessions[target] { return existing }
        let session = EditorSession(target: target, model: self)
        editorSessions[target] = session
        return session
    }

    func closeEditorSession(_ target: EditorTarget) {
        editorSessions[target] = nil
    }

    /// For views that have `openWindow`: reveal the lines, then open or
    /// bring forward the file's window.
    func showEditor(_ target: EditorTarget, at lines: LineRange?, using openWindow: OpenWindowAction) {
        editorSession(for: target).reveal(lines)
        openWindow(id: CCwikiApp.editorWindowID, value: target)
    }

    /// Any open editor holds text it has not saved.
    var hasUnsavedEdits: Bool {
        editorSessions.values.contains { $0.hasUnsavedText }
    }

    /// Saves every open editor of `job`: before Approve, Revert File, a
    /// refresh and a Restore (§4.4).
    func flushEdits(for job: Job) async {
        let sessions = editorSessions.filter { $0.key.jobID == job.id }.map { $0.value }
        for session in sessions { await session.saveNow() }
    }

    /// Saves every open editor: before the app quits.
    func flushAllEditors() async {
        let sessions = Array(editorSessions.values)
        for session in sessions { await session.saveNow() }
    }

    /// CCwiki changed these repository-relative paths in `job`'s worktree:
    /// its editors of those files reload (§4.4).
    func filesChanged(in job: Job, paths changed: [String]) {
        let sessions = editorSessions
            .filter { $0.key.jobID == job.id && changed.contains($0.key.path) }
            .map { $0.value }
        guard !sessions.isEmpty else { return }
        Task { @MainActor in
            for session in sessions { await session.reloadFromDisk() }
        }
    }

    /// What the editor's preview renders for `text` at `path`
    /// (repository-relative). Phase 0: the body, unresolved.
    func previewRequest(path: String, text: String) -> RenderRequest {
        let page = WikiPage(path: path, text: text)
        return RenderRequest(
            path: path, title: page.title, markdown: page.body, html: nil,
            links: [:], anchor: nil, notices: [])
    }

    /// `CCwiki.renderReview`'s payload for the job's snapshot (§6.3).
    /// Phase 0: nil.
    func reviewPayload(for job: Job) -> String? {
        nil
    }
}
