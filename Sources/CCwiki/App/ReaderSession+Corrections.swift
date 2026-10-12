import AppKit
import Foundation

// Correcting the page this window shows (plans/corrections.md §7.1, §8, §9):
// Edit Page…, Describe a Correction… and Open an Issue About This Page…,
// from the Wiki menu, the toolbar and the reader's context menu. Per
// window, because the page, its selection and its sheets are (§17).
extension ReaderSession {

    /// Whether the correction commands apply: a wiki page is showing, not a
    /// folder, Welcome or What's New (§3.6, §9). Blockers are explained by
    /// the sheet or the alert, never by a disabled item.
    var canCorrectCurrentPage: Bool {
        guard case .page(let path, _) = location else { return false }
        return model.index?.pages[path] != nil
    }

    /// From the menu bar and the toolbar: reads the selection, builds the
    /// target, then opens the editor or a sheet. Their titles stay fixed;
    /// each carries whatever is selected.
    func beginCorrection(_ route: CorrectionRoute) async {
        guard canCorrectCurrentPage else { return }
        let selection = await webController.selectionSource()
        await correct(route, selection: selection)
    }

    /// From the context menu, where the selection is already in hand: the
    /// passage the right-click was on, the block under the pointer, or
    /// nothing.
    func beginCorrection(_ route: CorrectionRoute, selection: ReaderSelection?) {
        guard canCorrectCurrentPage else { return }
        Task { await self.correct(route, selection: selection) }
    }

    // MARK: Routes

    private func correct(_ route: CorrectionRoute, selection: ReaderSelection?) async {
        guard canCorrectCurrentPage, let page = currentPage else { return }
        // A selection made on another page, as one the shell kept across a
        // render could be, is not about this one.
        let onPage = selection?.path == page.path ? selection : nil
        let shown = await shownTarget(of: page, selection: onPage)
        // The page moved on while its file was read.
        guard currentPage?.path == page.path else { return }

        // Whether this can become a pull request, or an issue, is asked in
        // the background: editing needs no network (§7.1).
        let jobCenter = model.jobCenter
        Task { await jobCenter.refreshGitHubAccess() }

        switch route {
        case .edit:
            await beginEdit(shown.target, at: shown.editorLines)
        case .describe:
            correctionSheet = CorrectionSheetRequest(
                .describe, target: shown.target, notice: shown.notice)
        case .issue:
            correctionSheet = CorrectionSheetRequest(
                .issue, target: shown.target, notice: shown.notice)
        }
    }

    /// Route a (§7.1): the local blockers, then a job already on the page,
    /// then a new edit job and its editor, open at `lines`: the passage, or
    /// the block a right-click pointed at.
    private func beginEdit(_ target: CorrectionTarget, at lines: LineRange?) async {
        let blockers = model.correctionBlockers(.edit, target: target)
        guard blockers.isEmpty else {
            explainBlockers(blockers)
            return
        }

        let existing = model.jobCenter.jobs(touching: target.pagePath)
        // An edit of this page that can still be edited: its editor, at the
        // lines asked for now, and no question.
        if let editing = existing.first(where: { $0.kind.tag == .edit && $0.canEdit }) {
            model.requestEditor(EditorTarget(jobID: editing.id, path: target.repositoryPath), at: lines)
            return
        }
        if let other = existing.first {
            switch Self.askAboutJob(other) {
            case .showJob:
                model.requestJobsWindow(selecting: other.id)
                return
            case .startAnother:
                break
            case .cancel:
                return
            }
        }

        switch await model.jobCenter.beginEdit(target) {
        case .success(let job):
            model.requestEditor(EditorTarget(jobID: job.id, path: target.repositoryPath), at: lines)
        case .failure(let error):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The page could not be opened for editing."
            alert.informativeText = error.message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// What is missing, with Open Settings…: editing needs nothing from
    /// GitHub, only git and a clone.
    private func explainBlockers(_ blockers: [String]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This page cannot be edited yet."
        alert.informativeText = blockers.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Settings…")
        if alert.runModal() == .alertSecondButtonReturn {
            model.requestSettings()
        }
    }

    fileprivate enum JobChoice {
        case showJob, startAnother, cancel
    }

    /// "This page already has a job in Jobs.": Show Job, Start Another or
    /// Cancel.
    fileprivate static func askAboutJob(_ job: Job) -> JobChoice {
        let alert = NSAlert()
        alert.messageText = "This page already has a job in Jobs."
        alert.informativeText = job.correctionNote
        alert.addButton(withTitle: "Show Job")
        alert.addButton(withTitle: "Start Another")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .showJob
        case .alertSecondButtonReturn: return .startAnother
        default: return .cancel
        }
    }

    // MARK: The target

    /// The target for what this window showed (§3.5): built from the file
    /// at the revision the page was rendered from, and the markdown that
    /// was rendered, never from whatever is on disk by now. When that
    /// revision's file cannot be read, the whole page at HEAD, in the
    /// section, with a notice saying the selection was not carried over.
    private func shownTarget(of page: WikiPage, selection: ReaderSelection?) async -> Shown {
        let reading = readingSection
        let revision = selection?.revision ?? webController.lastRenderedRevision
        let head = model.headRevision
        if let text = await shownFileText(of: page, revision: revision, head: head) {
            let rendered = webController.lastRenderedMarkdown ?? page.body
            let target = CorrectionTarget.make(
                page: page, fileText: text, renderedMarkdown: rendered,
                baseCommit: revision ?? head ?? "", selection: selection, readingHeading: reading)
            let lines = CorrectionTarget.editorLines(
                fileText: text, renderedMarkdown: rendered, selection: selection)
            return Shown(target: target, notice: nil, editorLines: lines)
        }
        let target = CorrectionTarget.fallback(
            page: page, head: head ?? "", selection: selection, readingHeading: reading)
        let notice = selection?.isPassage == true ? CorrectionTarget.fallbackNotice : nil
        return Shown(target: target, notice: notice, editorLines: nil)
    }

    /// The target, why it is not what was selected, if it is not, and where
    /// the editor opens.
    fileprivate struct Shown {
        let target: CorrectionTarget
        let notice: String?
        let editorLines: LineRange?
    }

    /// The page's file at `revision`: `git show` for a clone, and for a
    /// snapshot, or a clone git cannot show it from, the file on disk while
    /// the copy is still at that revision. Nil when it has moved since.
    private func shownFileText(of page: WikiPage, revision: String?, head: String?) async -> String? {
        let paths = model.paths
        let disk: () -> String? = {
            try? String(contentsOf: paths.content.appending(path: page.path), encoding: .utf8)
        }
        switch paths.wikiStore {
        case .git:
            if let revision, let git = model.gitService,
               let data = await git.blob("\(revision):content/\(page.path)", in: paths.clone),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            guard CorrectionTarget.diskShows(revision: revision, current: head) else { return nil }
            return disk()
        case .snapshot:
            let marker = SnapshotService.marker(in: paths.clone)?.sha
            guard CorrectionTarget.diskShows(revision: revision, current: marker) else { return nil }
            return disk()
        case .none:
            return nil
        }
    }

    /// The heading at the top of the window: where a correction with no
    /// selection, and no pointer, opens.
    private var readingSection: CorrectionTarget.Section? {
        guard let id = webController.activeHeadingID,
              let heading = webController.outline.first(where: { $0.id == id })
        else { return nil }
        return CorrectionTarget.Section(id: heading.id, title: heading.text, level: heading.level)
    }
}

extension Job {
    /// "A correction, running: Lines 42–44, in “Security”.": a job already
    /// on the page, as the alert and the sheets name it (§7.1).
    var correctionNote: String {
        let noun = kind.noun
        let article = noun.first.map { "aeiou".contains($0) } == true ? "An" : "A"
        let status = statusLabel.lowercased()
        let detail = self.detail.trimmingCharacters(in: .whitespaces)
        return detail.isEmpty
            ? "\(article) \(noun), \(status)."
            : "\(article) \(noun), \(status): \(detail)."
    }
}
