import SwiftUI

// Editor windows and the review's content, app-wide (plans/corrections.md
// §6.3, §7): the sessions behind the windows, saving them all before a
// publish or a quit, and what the preview and the review render (§11.5).
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
    /// (repository-relative), against the pages added by the job whose
    /// editor shows that file.
    func previewRequest(path: String, text: String) -> RenderRequest {
        let owner = editorSessions.keys.first { $0.path == path }
            .flatMap { jobCenter.job(id: $0.jobID) }
        return previewRequest(path: path, text: text, in: owner)
    }

    /// The page as the reader would render it (§7.4): the reader's index
    /// overlaid with the pages `job`'s review adds, so a link to one of them
    /// resolves, as `new` (§6.3); the macros; the manifest and the labels,
    /// so the relation-meta line appears; no hover cards, which are noise
    /// while editing; and the broken-link count, which is not.
    func previewRequest(path: String, text: String, in job: Job?) -> RenderRequest {
        let page = WikiPage(path: ReviewPayload.contentPath(path) ?? path, text: text)
        var request: RenderRequest
        if let index {
            let added = job?.review.map(ReviewPayload.addedPages(in:)) ?? []
            var renderer = PageRenderer(index: index.overlaying(added), hiddenPaths: unlistedPaths)
            renderer.relations = relations
            renderer.relationLabels = relationLabels
            renderer.buildsPreviews = false
            let rendered = renderer.request(for: page)
            request = RenderRequest(
                path: rendered.path, title: rendered.title, markdown: rendered.markdown,
                html: nil,
                links: ReviewPayload.markingNew(
                    rendered.links, newPages: ReviewPayload.newPagePaths(added, in: index)),
                anchor: nil, notices: rendered.notices)
        } else {
            // No library yet: the text, unresolved, rather than nothing.
            request = RenderRequest(
                path: page.path, title: page.displayTitle, markdown: page.body, html: nil,
                links: [:], anchor: nil, notices: [])
        }
        request.macros = macros.macros
        return request
    }

    /// `CCwiki.renderReview`'s payload for the job's snapshot (§6.3); nil
    /// while it has none, or an empty one. Links resolve against the
    /// reader's index overlaid with the pages the snapshot adds.
    func reviewPayload(for job: Job) -> String? {
        guard let snapshot = job.review, !snapshot.isEmpty else { return nil }
        let added = ReviewPayload.addedPages(in: snapshot)
        let overlay = index?.overlaying(added)
        let newPages = ReviewPayload.newPagePaths(added, in: index)
        let labels = relationLabels
        return ReviewPayload.json(
            snapshot: snapshot, findings: job.findings,
            title: { path in
                snapshot.files.first { $0.path == path }.flatMap(ReviewPayload.pageTitle(for:))
            },
            header: { ReviewPayload.header(for: $0, labels: labels) },
            links: { file in
                guard let overlay else { return [:] }
                return ReviewPayload.links(
                    for: file, header: ReviewPayload.header(for: file, labels: labels),
                    index: overlay, newPages: newPages)
            },
            macros: macros.macros)
    }
}
