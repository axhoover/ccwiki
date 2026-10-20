import SwiftUI

// Editor windows and the review's content, app-wide (plans/corrections.md
// §6.3, §7): the sessions behind the windows, saving them all before a
// publish or a quit, and what the preview and the review render (§11.5).
extension AppModel {

    /// The session for an editor window, made the first time it is asked
    /// for and kept until the window closes. Asked for again while its
    /// window is still closing, it stays, for the window that asked: its
    /// `close()` then neither discards the job nor lets the session go.
    func editorSession(for target: EditorTarget) -> EditorSession {
        if let existing = editorSessions[target] {
            existing.isClosing = false
            return existing
        }
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

    /// Saves every open editor: before the app quits. What an editor could
    /// not save, a conflict nobody settled above all, is kept in its job's
    /// worktree rather than lost with the app (§4.4).
    func flushAllEditors() async {
        let sessions = Array(editorSessions.values)
        for session in sessions {
            await session.saveNow()
            await session.keepUnsavedText()
        }
    }

    /// CCwiki changed these repository-relative paths in `job`'s worktree:
    /// its editors of those files reload (§4.4), and so does every editor
    /// of the job that could not read or save its file.
    func filesChanged(in job: Job, paths changed: [String]) {
        let sessions = editorSessions
            .filter {
                Self.reloadsEditor(
                    $0.key, of: job.id, changed: changed,
                    isLoaded: $0.value.isLoaded, saveFailed: $0.value.saveError != nil)
            }
            .map { $0.value }
        guard !sessions.isEmpty else { return }
        Task { @MainActor in
            for session in sessions { await session.reloadFromDisk() }
        }
    }

    /// Whether `filesChanged` reloads the editor of `target`: its file is
    /// one CCwiki changed in job `jobID`, or the editor is that job's and
    /// could not read or save its file, as while the worktree was gone. A
    /// Restore brings back every file, not only those its diff holds, and
    /// such an editor loads again, or saves what it was refused (§4.4, §7.5).
    nonisolated static func reloadsEditor(
        _ target: EditorTarget, of jobID: String, changed: [String],
        isLoaded: Bool, saveFailed: Bool
    ) -> Bool {
        target.jobID == jobID && (changed.contains(target.path) || !isLoaded || saveFailed)
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
        previewRequest(path: path, text: text, overlay: previewOverlay(for: job, reusing: nil))
    }

    /// The same, against an overlay `previewOverlay(for:reusing:)` gave:
    /// what an editor renders after each pause in typing, with the overlay
    /// it keeps. Nil before the library has loaded.
    func previewRequest(path: String, text: String, overlay: PreviewOverlay?) -> RenderRequest {
        let page = WikiPage(path: ReviewPayload.contentPath(path) ?? path, text: text)
        var request: RenderRequest
        if let overlay {
            request = overlay.request(
                for: page, hiddenPaths: unlistedPaths, relations: relations, labels: relationLabels)
        } else {
            // No library yet: the text, unresolved, rather than nothing.
            request = RenderRequest(
                path: page.path, title: page.displayTitle, markdown: page.body, html: nil,
                links: [:], anchor: nil, notices: [])
        }
        request.macros = macros.macros
        return request
    }

    /// The overlay the preview of `job`'s files resolves against: `cached`
    /// while the library and the pages the job's review adds are the ones
    /// it was built from, a new one otherwise. Nil before the library has
    /// loaded.
    func previewOverlay(for job: Job?, reusing cached: PreviewOverlay?) -> PreviewOverlay? {
        guard let index else { return nil }
        return PreviewOverlay.reusing(
            cached, index: index, generation: libraryGeneration, review: job?.review)
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

/// The reader's index overlaid with the pages a job's review adds, and
/// which of those the reader does not have yet: what the editor's preview
/// resolves links against (§6.3, §7.4).
///
/// Built whole from the library and the review, never patched
/// (SWIFTUI-RULES §3.2). An editor keeps the last one while both are the
/// ones it was built from, so a pause in typing neither assembles the
/// index again (about 900 files) nor parses the added pages again. The
/// library is known by its generation, which `AppModel` bumps with every
/// index it puts up. The review is known by the files it adds or renames,
/// the only ones the overlay reads: each save takes the review again, with
/// a new tree and the edited page's new text, and that alone changes
/// nothing here.
struct PreviewOverlay: Sendable {
    let generation: Int
    /// The review's added and renamed files, as they were.
    let addedFiles: [ChangedFile]
    /// The reader's index with the added pages in it.
    let index: WikiIndex
    /// The added pages the reader does not have: a link to one is `new`.
    let newPages: Set<String>

    init(index: WikiIndex, generation: Int, review: ReviewSnapshot?) {
        let added = review.map(ReviewPayload.addedPages(in:)) ?? []
        self.generation = generation
        self.addedFiles = Self.files(addedBy: review)
        self.index = index.overlaying(added)
        self.newPages = ReviewPayload.newPagePaths(added, in: index)
    }

    /// `cached` when it was built from this generation and the same added
    /// and renamed files; otherwise a new overlay of `index`.
    static func reusing(
        _ cached: PreviewOverlay?, index: WikiIndex, generation: Int, review: ReviewSnapshot?
    ) -> PreviewOverlay {
        if let cached, cached.generation == generation,
           cached.addedFiles == files(addedBy: review) {
            return cached
        }
        return PreviewOverlay(index: index, generation: generation, review: review)
    }

    /// The files `ReviewPayload.addedPages(in:)` reads, whole: two reviews
    /// with the same ones add the same pages.
    private static func files(addedBy review: ReviewSnapshot?) -> [ChangedFile] {
        review?.files.filter { $0.status == .added || $0.status == .renamed } ?? []
    }

    /// `page` rendered against the overlay, links to the added pages
    /// marked new, without hover cards.
    func request(
        for page: WikiPage, hiddenPaths: Set<String>, relations: RelationsManifest,
        labels: RelationLabels
    ) -> RenderRequest {
        var renderer = PageRenderer(index: index, hiddenPaths: hiddenPaths)
        renderer.relations = relations
        renderer.relationLabels = labels
        renderer.buildsPreviews = false
        let rendered = renderer.request(for: page)
        return RenderRequest(
            path: rendered.path, title: rendered.title, markdown: rendered.markdown,
            html: nil, links: ReviewPayload.markingNew(rendered.links, newPages: newPages),
            anchor: nil, notices: rendered.notices)
    }
}
