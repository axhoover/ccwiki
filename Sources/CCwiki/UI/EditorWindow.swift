import AppKit
import Combine
import SwiftUI

/// An editor window: one file of one job, its source beside a preview
/// rendered by the reader's own pipeline (plans/corrections.md §7.2).
///
/// A window per file, as a document has: titled by the file's name, with
/// the page and the passage as its subtitle. It writes into the job's
/// worktree, saving by itself, so there is no Save; Review Changes (⌘↩)
/// saves, takes the review again and brings Jobs forward on the job.
///
/// The window's lifetime is the window's, not the view's: editors tab with
/// editors, and SwiftUI may send `onDisappear` for a tab only deselected,
/// so the session closes on the window's `willCloseNotification`. A window
/// whose job is gone, opened or discarded closes itself (SWIFTUI-RULES
/// §6.5); the history loads before any window, so the answer is there when
/// a restored one asks.
struct EditorWindow: View {
    /// Nil for a window SwiftUI opens without a value, which has no file.
    let target: EditorTarget?

    /// Editors tab with editors, never with readers or papers (§17).
    static let tabbingIdentifier = "ccwiki.editor"

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var session: EditorSession?
    @State private var host = EditorHostWindow()

    var body: some View {
        Group {
            if let target, let session {
                EditorContent(target: target, session: session)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: Theme.editorPaneMinWidth * 2, minHeight: Theme.editorPaneMinWidth)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .background { WindowReader { host.window = $0 } }
        .onAppear { claimSession() }
        .onChange(of: closesItself, initial: true) { _, closes in
            if closes { dismiss() }
        }
        .onReceive(Self.windowWillClose) { notification in
            guard let window = notification.object as? NSWindow, window === host.window,
                  let session
            else { return }
            // Save, bring the review up to date, and let an untouched edit
            // go with its last editor (§7.5). Marked closing now, not when
            // the task starts, so a window that asks for the file meanwhile
            // keeps the session.
            session.isClosing = true
            Task { await session.close() }
        }
    }

    private static var windowWillClose: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
    }

    /// The session behind the window, made or found once. Not in `body`:
    /// a closing window's last update must not make it again.
    private func claimSession() {
        guard session == nil, let target, !closesItself else { return }
        session = model.editorSession(for: target)
    }

    private var job: Job? {
        target.flatMap { model.jobCenter.job(id: $0.jobID) }
    }

    /// No file, no job, or a job that is over: the window has nothing to
    /// edit. A job that needs its worktree restored keeps its editors, which
    /// say so and load again once it is back.
    private var closesItself: Bool {
        guard let job else { return true }
        return job.state.isTerminal
    }

    /// The file's name, as a document window's title is.
    private var title: String {
        target.map { ($0.path as NSString).lastPathComponent } ?? "Edit Page"
    }

    /// "Pseudorandom function · Lines 42–44, in “Security”" for the page a
    /// correction is about; the path for any other file the job changed.
    private var subtitle: String {
        guard let target else { return "" }
        if let page = job?.kind.target, page.repositoryPath == target.path {
            return "\(page.pageTitle) · \(page.summary)"
        }
        return target.path
    }
}

/// The window an editor view is in, once AppKit has said. A reference, so
/// reporting it changes no view state; weak, since the window owns the view.
private final class EditorHostWindow {
    weak var window: NSWindow?
}

// MARK: - The editor

/// An editor's panes and chrome, once it has its session: the context
/// strip, the source beside the preview, the status line, the toolbar, and
/// the Find and Review Changes commands.
private struct EditorContent: View {
    let target: EditorTarget
    let session: EditorSession

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @State private var source = SourceTextController()
    @State private var showsPreview = true
    @State private var reveal: SourceReveal?
    @State private var hidesQuote = false
    @State private var confirmsRevert = false
    /// Open an Issue… from the GitHub line, on this window (§8).
    @State private var issueRequest: CorrectionSheetRequest?

    private var job: Job? { session.job }

    /// The correction or edit this file is the page of, if it is: the
    /// quote, the passage and a generated region are about that page only.
    private var pageTarget: CorrectionTarget? {
        guard let page = job?.kind.target, page.repositoryPath == target.path else { return nil }
        return page
    }

    var body: some View {
        VStack(spacing: 0) {
            contextStrip
            panes
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            EditorStatusLine(
                session: session, source: source, isDevBuild: model.publishTarget.isDevBuild)
        }
        .toolbar { toolbar }
        // ⌘↩ in the Jobs menu: only an editor window offers it (§9).
        .focusedSceneValue(\.reviewChangesAction, JobCommandAction(isEnabled: job != nil) {
            reviewChanges()
        })
        // The reader's Find items reach the source's find bar.
        .focusedSceneValue(\.findAction, FindAction(
            perform: { source.performFind(.showFindInterface) },
            next: { source.performFind(.nextMatch) },
            previous: { source.performFind(.previousMatch) }))
        .task { await session.load() }
        .task(id: model.isDiscoveringTools) {
            // Restored, or opened before anyone asked: whether this can
            // become a pull request is asked in the background (§7.1). Once
            // the tools are found: asked before gh is, the answer would say
            // it is missing, and be kept.
            if model.jobCenter.gitHubAccess == nil, !model.isDiscoveringTools {
                await model.jobCenter.refreshGitHubAccess()
            }
        }
        .onAppear { wire() }
        .onChange(of: session.pendingReveal, initial: true) { _, _ in takeReveal() }
        .onChange(of: session.isLoaded) { _, _ in takeReveal() }
        // The readers' text size, which every web view follows (§17).
        .onChange(of: model.pageZoom) { _, zoom in
            if session.hasPreview { session.preview.setPageZoom(zoom) }
        }
        // The wiki the preview resolves links, macros and relation labels
        // against: a restored editor usually loads before it does.
        .onChange(of: model.libraryGeneration) { _, _ in
            if session.hasPreview { session.renderPreview() }
        }
        .alert(conflictTitle, isPresented: conflictPresented) {
            if conflictIsCCwikis {
                Button("Use Reverted File") { session.useFileOnDisk() }
                Button("Keep My Version") { keepMyVersion() }
            } else {
                Button("Keep My Version") { keepMyVersion() }
                Button("Use the File on Disk") { session.useFileOnDisk() }
            }
        } message: {
            Text(conflictMessage)
        }
        .alert(revertQuestion.title, isPresented: $confirmsRevert) {
            Button("Revert File", role: .destructive) {
                Task { await session.revertFile() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(revertQuestion.message ?? "")
        }
        .sheet(item: $issueRequest) { request in
            IssueSheet(request: request)
        }
    }

    // MARK: Panes

    /// The source, and beside it the preview, which hides by width rather
    /// than leaving the split view (§13).
    @ViewBuilder
    private var panes: some View {
        if session.hasPreview {
            HSplitView {
                SourcePane(session: session, source: source, reveal: reveal)
                    .frame(minWidth: Theme.editorPaneMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                WebPane(controller: session.preview)
                    .frame(
                        minWidth: showsPreview ? Theme.editorPaneMinWidth : 0,
                        maxWidth: showsPreview ? .infinity : 0,
                        maxHeight: .infinity)
                    .opacity(showsPreview ? 1 : 0)
                    .accessibilityHidden(!showsPreview)
            }
        } else {
            SourcePane(session: session, source: source, reveal: reveal)
        }
    }

    /// The preview renders again after a WebContent restart, its links open
    /// in the reader by the explorer's rule (§6.3, §17), and the caret's
    /// line moves it.
    private func wire() {
        let session = self.session
        let model = self.model
        let openWindow = self.openWindow
        source.onLineChange = { [weak session] line in session?.cursorDidMove(toLine: line) }
        guard session.hasPreview else { return }
        session.preview.onReady = { [weak session] in session?.renderPreview() }
        session.preview.onNavigate = { [weak model] destination, disposition in
            guard let model else { return }
            ReviewLinks.follow(destination, disposition, model: model, openWindow: openWindow)
        }
    }

    /// The lines asked for, once the text they are in is loaded.
    private func takeReveal() {
        guard session.isLoaded, let lines = session.takePendingReveal() else { return }
        reveal = SourceReveal(lines: lines)
    }

    // MARK: The context strip

    /// Under the toolbar, on the bar: the quote carried from the reader, why
    /// the text cannot be edited, what a generated passage or a line built
    /// from the frontmatter is, GitHub, a failed save.
    @ViewBuilder
    private var contextStrip: some View {
        let quote = hidesQuote ? nil : pageTarget?.quote
        let readOnly = session.isLoaded ? session.readOnlyReason : nil
        let generated = pageTarget?.region == .generated
        let fromFrontmatter = pageTarget?.region == .frontmatter
        let access = model.jobCenter.gitHubAccess.flatMap { $0 == .ready ? nil : $0 }
        let saveError = session.saveError
        let explains = generated || fromFrontmatter
        if quote != nil || readOnly != nil || explains || access != nil || saveError != nil {
            VStack(alignment: .leading, spacing: Theme.tight) {
                if let quote { quoteRow(quote) }
                if let readOnly {
                    stripRow("lock", .secondary, readOnly)
                }
                if generated {
                    stripRow("arrow.triangle.branch", .orange,
                             "This passage is generated from the reduction pages. Correct the "
                             + "reduction page it links to; edits here are refused at review.")
                }
                // The relation line under a reduction or barrier page's title
                // (§3.1, §3.5): the quoted line is not in the file; the
                // fields it is built from are, and they are what is selected.
                if fromFrontmatter {
                    stripRow("list.bullet.rectangle", .orange, frontmatterNote)
                }
                if let access {
                    GitHubAccessLine(
                        access: access, issueTarget: pageTarget ?? job?.kind.target,
                        openIssue: { issueRequest = CorrectionSheetRequest(.issue, target: $0) },
                        checkAgain: { Task { await model.jobCenter.refreshGitHubAccess() } })
                }
                if let saveError {
                    stripRow("xmark.octagon.fill", .red, "Could not save: \(saveError)")
                }
            }
            .padding(.horizontal, Theme.large)
            .padding(.vertical, Theme.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            Divider()
        }
    }

    /// Two lines of the quote at most, truncated, never reflowing the
    /// strip; its help holds all of it.
    private func quoteRow(_ quote: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
            Image(systemName: "text.quote")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(quote)
                .font(Theme.Fonts.log)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .help(quote)
                .accessibilityLabel("Quoted: \(quote)")
            Spacer(minLength: Theme.small)
            if let lines = pageTarget?.lines {
                Button("Show") { reveal = SourceReveal(lines: lines) }
                    .buttonStyle(.link)
                    .font(Theme.Fonts.meta)
                    .help("Select \(lines.label) again")
            }
            Button {
                hidesQuote = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Hide the quote")
            .accessibilityLabel("Hide the Quote")
        }
    }

    /// What a passage from the relation line is: the frontmatter fields on
    /// the lines the editor opened at.
    private var frontmatterNote: String {
        let fields = pageTarget?.lines.map { "the frontmatter fields on \($0.label)" }
            ?? "this page's frontmatter fields"
        return "The quoted line is built from \(fields). Edit those fields to change it."
    }

    private func stripRow(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.Fonts.meta)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if session.hasPreview {
                let title: String = showsPreview ? "Hide Preview" : "Show Preview"
                Button {
                    showsPreview.toggle()
                } label: {
                    Label(title, systemImage: "sidebar.right")
                }
                .help(title)
            }

            Menu {
                Button("Revert File…") { confirmsRevert = true }
                    .disabled(!session.isEditable)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .help("More")

            Button {
                reviewChanges()
            } label: {
                Label("Review Changes", systemImage: JobState.awaitingReview.symbolName)
            }
            .disabled(job == nil)
            .help("Save, then review the changes in Jobs (⌘↩)")
        }
    }

    // MARK: Actions

    /// Saves, takes the review again, and opens Jobs on the job (§7.2).
    private func reviewChanges() {
        let jobID = target.jobID
        Task {
            await session.saveNow()
            if let job = model.jobCenter.job(id: jobID), job.state == .awaitingReview {
                await model.jobCenter.refreshReview(job)
            }
            model.requestJobsWindow(selecting: jobID)
            openWindow(id: CCwikiApp.jobsWindowID)
        }
    }

    private func keepMyVersion() {
        Task { await session.keepMyVersion() }
    }

    /// Whether the job added the file is the review's to say, as in the
    /// review's own Revert File…; the original, read once when the window
    /// loads, can be missing for other reasons (no git yet, a failed read).
    private var revertQuestion: JobReview.Question {
        let status = job?.review?.files.first(where: { $0.path == target.path })?.status
        return JobReview.revertQuestion(path: target.path, isNew: status == .added)
    }

    // MARK: A changed file under the editor

    private var conflictPresented: Binding<Bool> {
        Binding(
            get: {
                if case .conflict = session.saveState { return true }
                return false
            },
            // Settled only by one of its buttons.
            set: { _ in })
    }

    private var conflictIsCCwikis: Bool {
        if case .conflict(_, let revertedByCCwiki) = session.saveState { return revertedByCCwiki }
        return false
    }

    private var conflictTitle: String {
        conflictIsCCwikis
            ? "CCwiki reverted this file in Jobs."
            : "This file changed on disk."
    }

    private var conflictMessage: String {
        conflictIsCCwikis
            ? "Your unsaved changes to this file are still in the editor."
            : "It was changed outside CCwiki after this editor last saved it."
    }
}

// MARK: - The source pane

/// The source, or why it cannot be shown. A view of its own, so typing
/// redraws it alone and not the window's chrome (SWIFTUI-RULES §6.3).
private struct SourcePane: View {
    let session: EditorSession
    let source: SourceTextController
    let reveal: SourceReveal?

    var body: some View {
        let session = self.session
        if let error = session.loadError {
            ContentUnavailableView(
                "Can't Open This File", systemImage: "exclamationmark.triangle",
                description: Text(error))
        } else {
            SourceTextView(
                text: session.text, isEditable: session.isEditable, reveal: reveal,
                controller: source,
                onTextChange: { [weak session] text in
                    guard let session else { return }
                    session.text = text
                    session.textDidChange()
                })
        }
    }
}

// MARK: - The status line

/// Under the panes, as under a reader: whether the text is saved, where the
/// caret is, and which CCwiki this is (§7.2). Its own view, since the caret
/// moves with every key.
private struct EditorStatusLine: View {
    let session: EditorSession
    let source: SourceTextController
    let isDevBuild: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.small) {
                Text(saveText)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(saveStyle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Theme.small)
                Text(verbatim: "Line \(source.line), Column \(source.column)")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if isDevBuild {
                    Text("CCwiki Dev")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Theme.medium)
            .frame(height: ReviewMetrics.statusBarHeight)
            .background(.bar)
        }
    }

    private var saveText: String {
        if let error = session.loadError { return error }
        guard session.isLoaded else { return "Opening…" }
        if session.saveError != nil { return "Not saved" }
        switch session.saveState {
        case .conflict: return "Not saved: the file changed on disk"
        case .saving: return "Saving…"
        case .saved: return session.isEditable ? "Saved to the job's worktree" : "Read only"
        }
    }

    private var saveStyle: AnyShapeStyle {
        if session.saveError != nil { return AnyShapeStyle(Color.red) }
        if case .conflict = session.saveState { return AnyShapeStyle(Color.orange) }
        return AnyShapeStyle(.secondary)
    }
}
