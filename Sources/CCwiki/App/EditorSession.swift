import Foundation
import Observation

/// One editor window's file: its text, the version the job started from,
/// the preview, and saving into the job's worktree (plans/corrections.md
/// §7). The model keeps one per open editor, by its `EditorTarget`.
///
/// Saving is automatic. Half a second after typing stops, the text is
/// written into the worktree, atomically, and only while the job is
/// awaiting review; a second after a save, the job's review is taken again.
/// Before each write the file on disk is compared with what this editor
/// last read or wrote, so a change made elsewhere is never overwritten
/// without asking (§4.4). Writes run one at a time, in order.
@MainActor
@Observable
final class EditorSession {

    let target: EditorTarget
    /// What the source view shows. Set it, then call `textDidChange()`.
    var text = ""
    /// The file at the job's base commit, as bytes decoded once. Nil for a
    /// file the job adds, and until `load()`.
    private(set) var original: String?
    private(set) var saveState: SaveState = .saved
    /// 1-based.
    private(set) var cursorLine = 1
    /// Lines to select and scroll to, consumed by the source view with
    /// `takePendingReveal()`.
    private(set) var pendingReveal: LineRange?
    /// The file has been read; until then the source view has nothing to
    /// show and nothing is saved.
    private(set) var isLoaded = false
    /// Why the file could not be read: the job or its worktree is gone.
    private(set) var loadError: String?
    /// Why the last write failed, until one succeeds.
    private(set) var saveError: String?

    /// Text typed that is not yet on disk.
    var hasUnsavedText: Bool { isLoaded && text != (diskText ?? "") }

    /// The window is closing and nobody has asked for the file since. The
    /// window sets it before calling `close()`; `AppModel.editorSession(for:)`
    /// clears it when the file is asked for again meanwhile, and the session
    /// then stays, for the window that asked.
    @ObservationIgnored var isClosing = false

    /// The preview's own web view, made on first use with the readers'
    /// data store and text size (§7.4, §17). A WebContent restart checks
    /// the staged pipeline first, as a reader's does.
    @ObservationIgnored private(set) lazy var preview: WebController = {
        let preview = WebController(
            paths: self.model.paths, webRoot: self.model.webRoot, pageZoom: self.model.pageZoom)
        preview.onRendererRestart = { [weak self] in self?.model.checkWebRoot() }
        return preview
    }()

    /// The model owns the sessions and outlives every one of them.
    private unowned let model: AppModel

    /// The file as this editor last read or wrote it; nil when it does not
    /// exist. What the external-change check compares the disk with, and
    /// what `hasUnsavedText` reads, so it is observed.
    private var diskText: String?
    @ObservationIgnored private var isLoading = false
    /// This editor has written the file at least once, so the review may be
    /// out of date when it closes.
    @ObservationIgnored private var hasWritten = false

    // The debouncers, and the chain every write goes through.
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var revealTask: Task<Void, Never>?

    /// The map between the text the preview last rendered and its markdown,
    /// for the preview to follow the cursor (§7.4).
    @ObservationIgnored private var previewLineMap: SourceLineMap?
    @ObservationIgnored private var hasRenderedPreview = false

    static let saveDelay: Duration = .milliseconds(500)
    static let refreshDelay: Duration = .seconds(1)
    static let previewDelay: Duration = .milliseconds(300)
    static let followDelay: Duration = .milliseconds(150)

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

    // MARK: What the window reads

    /// The job this file belongs to; nil once it is gone.
    var job: Job? { model.jobCenter.job(id: target.jobID) }

    /// Only a Markdown page has a preview; any other file the job changed
    /// is edited as plain text.
    var hasPreview: Bool { target.path.hasSuffix(".md") }

    /// Why the text cannot be edited now, for the context strip; nil when
    /// it can (§7.3). The window closes itself for a job that is opened,
    /// discarded or gone.
    var readOnlyReason: String? {
        guard let job else { return "This job is no longer in Jobs." }
        if job.needsRestore {
            return "The worktree is gone. Restore it in Jobs to edit this file."
        }
        switch job.state {
        case .awaitingReview:
            return nil
        case .publishing:
            return "CCwiki is opening the pull request. Editing resumes if it stops."
        case .opened:
            return "The pull request is open. This file can no longer be edited here."
        case .discarded:
            return "This job was discarded."
        case .queued, .preparing, .running:
            return "The agent is still working on this job."
        case .failed, .cancelled, .aborted:
            return "This job ended. Choose Review Anyway in Jobs to edit its changes."
        }
    }

    var isEditable: Bool { isLoaded && readOnlyReason == nil }

    // MARK: Loading

    /// Reads the file from the worktree and the original from the base
    /// commit, then renders the preview. Once; `reloadFromDisk()` reads it
    /// again.
    func load() async {
        guard !isLoaded, !isLoading else { return }
        guard let job else {
            loadError = "This job is no longer in Jobs."
            return
        }
        isLoading = true
        defer { isLoading = false }

        guard Self.isWorktree(job.worktree) else {
            loadError = "The worktree is gone. Restore it in Jobs to edit this file."
            return
        }
        let disk = await Self.readFile(fileURL(of: job))
        if original == nil, let base = job.baseCommit, let git = model.gitService {
            let data = await git.blob("\(base):\(target.path)", in: job.worktree)
            original = data.map { String(decoding: $0, as: UTF8.self) }
        }
        diskText = disk
        text = disk ?? ""
        loadError = nil
        saveError = nil
        saveState = .saved
        isLoaded = true
        renderPreview()
    }

    // MARK: Editing

    /// The source view changed `text`: save half a second after typing
    /// stops, and render the preview after 300 ms.
    func textDidChange() {
        guard isLoaded else { return }
        if case .conflict = saveState {
            // Nothing is saved until the conflict is settled.
        } else {
            updateSaveState()
            scheduleSave()
        }
        schedulePreview()
    }

    /// Saving while text is unsaved, saved otherwise; assigned only when
    /// that changes. An assignment of an equal value can still notify the
    /// readers, the editor's chrome and Jobs' Open Draft PR gate, and
    /// typing would then redraw them on every key rather than twice per
    /// burst.
    private func updateSaveState() {
        let next: SaveState = hasUnsavedText ? .saving : .saved
        if saveState != next { saveState = next }
    }

    /// The cursor is on `line` (1-based): the preview follows it, at most
    /// once every 150 ms.
    func cursorDidMove(toLine line: Int) {
        guard line != cursorLine else { return }
        cursorLine = line
        guard hasPreview, revealTask == nil else { return }
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: Self.followDelay)
            guard let self, !Task.isCancelled else { return }
            self.revealTask = nil
            self.followCursor()
        }
    }

    /// Asks the source view to select `lines` and scroll them to the
    /// centre: on open, and when the file is asked for again. Nil keeps the
    /// cursor where it is.
    func reveal(_ lines: LineRange?) {
        guard let lines else { return }
        pendingReveal = lines
    }

    /// The lines to reveal, once: taking them clears them, so asking again
    /// for the same lines reveals them again.
    func takePendingReveal() -> LineRange? {
        defer { pendingReveal = nil }
        return pendingReveal
    }

    // MARK: Saving

    /// Writes the text now, after any write in flight. Writes only while
    /// the job is awaiting review, and never over a file that changed on
    /// disk since this editor last read or wrote it: that is a conflict,
    /// for the window to settle.
    func saveNow() async {
        saveTask?.cancel()
        saveTask = nil
        let previous = writeTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.write()
        }
        writeTask = task
        await task.value
    }

    /// Keep My Version: the editor's text replaces the file on disk.
    func keepMyVersion() async {
        guard case .conflict(let disk, _) = saveState else { return }
        // The disk as it is now is what this write replaces.
        diskText = disk
        updateSaveState()
        await saveNow()
    }

    /// Use the File on Disk, or Use Reverted File: the editor takes the
    /// file as it is now, and its unsaved text is dropped.
    func useFileOnDisk() {
        guard case .conflict(let disk, _) = saveState else { return }
        diskText = disk
        text = disk
        saveState = .saved
        renderPreview()
    }

    private func write() async {
        guard isLoaded, let job else { return }
        if case .conflict = saveState { return }
        guard hasUnsavedText else {
            saveState = .saved
            return
        }
        // Read fresh: an editor writes only while its job is awaiting review
        // (§4.4), and the job may have moved on since the keystroke.
        guard job.canEdit else { return }
        // A worktree deleted under the editor (Caches cleared by hand, or a
        // Discard under way) is never made again as a plain folder holding
        // this one file: git would not know it, every snapshot would fail,
        // and Restore would refuse the folder. Asked before the disk is read,
        // so a missing file is not mistaken for a change made elsewhere.
        guard Self.isWorktree(job.worktree) else {
            saveError = Self.worktreeGone
            return
        }

        let file = fileURL(of: job)
        let disk = await Self.readFile(file)
        guard (disk ?? "") == (diskText ?? "") else {
            saveState = .conflict(diskText: disk ?? "", revertedByCCwiki: false)
            return
        }
        let written = text
        if let failure = await Self.writeFile(written, to: file, in: job.worktree) {
            saveError = failure
            return
        }
        saveError = nil
        diskText = written
        hasWritten = true
        if case .conflict = saveState {
            // Settled while the write was in flight; leave it to the window.
        } else {
            saveState = text == written ? .saved : .saving
        }
        scheduleRefresh()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard let self, !Task.isCancelled else { return }
            await self.saveNow()
        }
    }

    /// The review again, a second after the last save, saves coalesced.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: Self.refreshDelay)
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            guard let job = self.job, job.state == .awaitingReview else { return }
            await self.model.jobCenter.refreshReview(job)
        }
    }

    // MARK: When CCwiki changes the file

    /// After CCwiki changed the file (Revert File, Restore): reloads it
    /// silently when nothing is unsaved; otherwise the window asks whether
    /// to use the reverted file or keep this version (§7.5).
    func reloadFromDisk() async {
        guard isLoaded else {
            await load()
            return
        }
        // A write in flight lands first, so it is not mistaken for CCwiki's.
        await writeTask?.value
        guard let job else { return }
        let disk = await Self.readFile(fileURL(of: job))
        guard (disk ?? "") != (diskText ?? "") else {
            // The file is as this editor left it. Text a save refused while
            // the worktree was gone is saved now that Restore has brought it back.
            if hasUnsavedText, saveError != nil { scheduleSave() }
            return
        }

        saveTask?.cancel()
        saveTask = nil
        if hasUnsavedText {
            saveState = .conflict(diskText: disk ?? "", revertedByCCwiki: true)
        } else {
            diskText = disk
            text = disk ?? ""
            saveState = .saved
            saveError = nil
            renderPreview()
        }
    }

    /// Revert File…, after the window's confirmation: the file goes back
    /// to the version the job started from, through the job's own queue,
    /// which saves this editor first.
    func revertFile() async {
        guard let job else { return }
        await model.jobCenter.revert(target.path, in: job)
        // The job center reloads its editors itself (`onFilesChanged`);
        // reading again here is a no-op when it already has.
        await reloadFromDisk()
    }

    // MARK: Closing

    /// The window is closing: save, keep what could not be saved, bring the
    /// review up to date, and, for the last editor of an edit nobody
    /// changed, discard the job (§7.5). Then the model lets the session go.
    ///
    /// The window sets `isClosing` first. When the file is asked for again
    /// before this has finished, the session belongs to the new window: from
    /// the next step on, nothing is discarded and the session is kept.
    func close() async {
        await saveNow()
        guard isClosing else { return }
        previewTask?.cancel()
        previewTask = nil
        revealTask?.cancel()
        revealTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        await keepUnsavedText()
        guard isClosing else { return }

        if let job, job.state == .awaitingReview {
            let isLastEditor = !model.editorSessions.contains {
                $0.key != target && $0.key.jobID == job.id
            }
            let isEdit = job.kind.tag == .edit
            // An untouched edit is judged by its review, so the review must
            // include whatever this editor wrote.
            if hasWritten || (isLastEditor && isEdit) {
                await model.jobCenter.refreshReview(job)
            }
            // Only an edit that never reached GitHub leaves nothing behind;
            // one with a branch there waits in Jobs for its Discard, which
            // says what stays on GitHub.
            if isClosing, isLastEditor, isEdit, !hasUnsavedText, !job.hasTriedToPush {
                await model.jobCenter.discardIfUntouched(job)
            }
        }
        if isClosing, model.editorSessions[target] === self {
            model.closeEditorSession(target)
        }
    }

    /// What could not be saved as the editor or the app closes (a conflict
    /// nobody settled, a failed write, a save refused while a publish ran)
    /// is kept in the worktree's `.ccwiki/`, which no snapshot stages (§6.1),
    /// and the job's log says where. Text is never dropped without a word
    /// (§4.4): without a worktree there is nowhere to keep it, and the log
    /// says that instead.
    func keepUnsavedText() async {
        guard hasUnsavedText, let job else { return }
        let jobCenter = model.jobCenter
        guard Self.isWorktree(job.worktree) else {
            jobCenter.log(JobLogEntry(.error,
                "The editor's unsaved version of \(target.path) was lost: the worktree is gone."),
                in: job)
            return
        }
        let kept = ".ccwiki/" + (target.path as NSString).lastPathComponent + ".unsaved"
        let file = job.worktree.appending(path: kept)
        if let failure = await Self.writeFile(text, to: file, in: job.worktree) {
            jobCenter.log(JobLogEntry(.error,
                "The editor's unsaved version of \(target.path) could not be kept: \(failure)"),
                in: job)
            return
        }
        jobCenter.log(JobLogEntry(.system,
            "The editor's unsaved version of \(target.path) was kept in \(kept), in the job's worktree."),
            in: job)
    }

    // MARK: The preview

    /// Renders the text now: what the debouncer runs, and what the window
    /// calls when the preview's shell is ready again.
    func renderPreview() {
        previewTask?.cancel()
        previewTask = nil
        guard isLoaded, hasPreview else { return }
        var request = model.previewRequest(path: target.path, text: text, in: job)
        request.preservesScroll = hasRenderedPreview
        // `render` skips the path it already shows.
        preview.invalidate()
        preview.render(request)
        hasRenderedPreview = true
        previewLineMap = SourceLineMap(fileText: text, renderedMarkdown: request.markdown)
    }

    private func schedulePreview() {
        guard hasPreview else { return }
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: Self.previewDelay)
            guard let self, !Task.isCancelled else { return }
            self.renderPreview()
        }
    }

    /// Scrolls the preview to the block holding the cursor's line.
    private func followCursor() {
        guard let map = previewLineMap,
              let rendered = map.renderedLine(forFileLine: cursorLine)
        else { return }
        preview.revealSourceLines(rendered..<(rendered + 1), mark: false)
    }

    // MARK: Files

    private func fileURL(of job: Job) -> URL {
        job.worktree.appending(path: target.path)
    }

    /// The file's text, decoded leniently; nil when it does not exist.
    private nonisolated static func readFile(_ file: URL) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// A git worktree is there: its root holds `.git`, a file pointing into
    /// the clone. A folder without one is not the job's worktree.
    nonisolated static func isWorktree(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: ".git").path(percentEncoded: false))
    }

    /// Why a save was refused when the worktree had gone. Jobs offers
    /// Restore for it (`JobReview.isWorktreeGone`).
    nonisolated static let worktreeGone = "The worktree is gone. Your text stays in this editor; "
        + "restore the worktree in Jobs."

    /// Writes `text` atomically into `worktree`, making the folders it needs
    /// below its root and never the root itself. The error's description on
    /// failure, nil on success.
    nonisolated static func writeFile(
        _ text: String, to file: URL, in worktree: URL
    ) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            // Asked again just before the write: the worktree may have gone
            // since the editor looked.
            guard EditorSession.isWorktree(worktree) else { return EditorSession.worktreeGone }
            do {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file, options: .atomic)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
    }
}
