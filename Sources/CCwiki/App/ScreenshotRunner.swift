import AppKit
import SwiftUI
import WebKit

/// A scripted visual gate, enabled only by environment variable.
///
/// SwiftUI's compile guarantees are weak — a passing build is not a passing app
/// (`SWIFTUI-RULES.md` §9.3) — so the real check on a UI change is looking at
/// it. This drives the *real* app through a plan of views and pauses at each
/// one so `scripts/shots.sh` can take a true window capture.
///
/// ```sh
/// make shots
/// make shots PLAN='page:Primitives/pseudorandom-function.md'
/// ```
///
/// Two capture paths:
///
/// - **External** (`CCWIKI_SHOT_EXTERNAL=1`, what `make shots` uses): the app
///   writes a `.ready-N` marker, waits for `.go-N`, and the script runs
///   `screencapture -l`. Pixel-accurate, vibrancy and all — but it needs the
///   Screen Recording permission.
/// - **In-app fallback**: `cacheDisplay` plus `WKWebView.takeSnapshot`, which
///   needs no permission but cannot draw `NSVisualEffectView` backdrops, so
///   sidebars and toolbars come out flat.
///
/// Absent `CCWIKI_SHOTS` this type does nothing at all.
@MainActor
enum ScreenshotRunner {

    static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["CCWIKI_SHOTS"], !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static var usesExternalCapture: Bool {
        ProcessInfo.processInfo.environment["CCWIKI_SHOT_EXTERNAL"] == "1"
    }

    /// One step of the plan: what to show before capturing.
    private enum Step {
        case home
        case page(String)
        case folder(String)
        case switcher(String)
        case search(String)
        case inspector(AppModel.InspectorTab)
        case appearance(NSAppearance.Name, label: String)
        /// Submit a real ingestion job and wait for it to finish. The whole
        /// point of M2 is that this works end to end, so the harness that
        /// proves the reader works should be able to prove this too.
        case ingest(String)
        case settings
        /// Just show the jobs window — useful for checking the orphaned-worktree
        /// recovery path without running a job.
        case jobs
        /// The app's own pages.
        case welcome
        case whatsNew
        /// The paper window for the reference page at this path.
        case paper(String)
        /// A second reader window, opened on this page.
        case window(String)
        /// A new tab of the key reader window on this page: `tab:` in
        /// front, `bgtab:` behind, once background tabs are on
        /// (`WindowTabbing.joinsInBackground`); in front until then.
        case tab(String, inBackground: Bool)
        /// An edit of this page, begun past the blockers, in its editor at
        /// the section in view (plans/corrections.md §12.3).
        case edit(String)
        /// A scripted one-word edit of this page, reviewed in Jobs.
        case review(String)
        /// The review's Changes in Source. A step of its own, like `dark`,
        /// because the plan separates steps with commas.
        case source
        /// The Describe a Correction sheet over this page.
        case describe(String)
        /// The Open an Issue sheet over this page.
        case issue(String)

        static func parse(_ raw: String) -> Step? {
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            switch parts.first {
            case "home": return .home
            case "page": return parts.count > 1 ? .page(parts[1]) : nil
            case "folder": return parts.count > 1 ? .folder(parts[1]) : nil
            case "switcher": return .switcher(parts.count > 1 ? parts[1] : "")
            case "search": return parts.count > 1 ? .search(parts[1]) : nil
            case "backlinks": return .inspector(.backlinks)
            case "outline": return .inspector(.outline)
            case "relations": return .inspector(.relations)
            case "light": return .appearance(.aqua, label: "light")
            case "dark": return .appearance(.darkAqua, label: "dark")
            case "ingest": return parts.count > 1 ? .ingest(parts[1]) : nil
            case "welcome": return .welcome
            case "whatsnew": return .whatsNew
            case "settings": return .settings
            case "jobs": return .jobs
            case "paper": return parts.count > 1 ? .paper(parts[1]) : nil
            case "window": return parts.count > 1 ? .window(parts[1]) : nil
            case "tab": return parts.count > 1 ? .tab(parts[1], inBackground: false) : nil
            case "bgtab": return parts.count > 1 ? .tab(parts[1], inBackground: true) : nil
            case "edit": return parts.count > 1 ? .edit(parts[1]) : nil
            case "review": return parts.count > 1 ? .review(parts[1]) : nil
            case "source": return .source
            case "describe": return parts.count > 1 ? .describe(parts[1]) : nil
            case "issue": return parts.count > 1 ? .issue(parts[1]) : nil
            default: return nil
            }
        }

        var slug: String {
            switch self {
            case .home: "home"
            case .page(let path): Self.slug(ofPage: path)
            case .folder(let slug): "folder-\(slug)"
            case .switcher(let query): "switcher-\(query.isEmpty ? "empty" : query)"
            case .search(let query): "search-\(query.replacingOccurrences(of: " ", with: "-"))"
            case .inspector(let tab): "inspector-\(tab.rawValue.lowercased())"
            case .appearance(_, let label): label
            case .ingest: "ingest"
            case .settings: "settings"
            case .jobs: "jobs"
            case .welcome: "welcome"
            case .whatsNew: "whats-new"
            case .paper(let path): "paper-" + Self.slug(ofPage: path)
            case .window(let path): "window-" + Self.slug(ofPage: path)
            case .tab(let path, let inBackground):
                (inBackground ? "bgtab-" : "tab-") + Self.slug(ofPage: path)
            case .edit(let path): "edit-" + Self.slug(ofPage: path)
            case .review(let path): "review-" + Self.slug(ofPage: path)
            case .source: "source"
            case .describe(let path): "describe-" + Self.slug(ofPage: path)
            case .issue(let path): "issue-" + Self.slug(ofPage: path)
            }
        }

        /// A page's file name, as a capture's file name can carry it.
        private static func slug(ofPage path: String) -> String {
            (path as NSString).lastPathComponent
                .replacingOccurrences(of: ".md", with: "")
                .replacingOccurrences(of: " ", with: "-")
        }

        /// Rendering a page needs longer to settle than flipping a picker.
        var settleMilliseconds: Int {
            switch self {
            case .page, .folder, .home, .welcome, .whatsNew, .paper: 1500
            // A new window or tab loads its web view's shell before it can
            // render; so do an editor's preview and the review.
            case .window, .tab, .edit, .review: 2500
            case .describe, .issue, .source: 900
            case .search: 900
            // An ingestion job is minutes, not milliseconds; `apply` waits for
            // a terminal state rather than guessing a duration.
            case .ingest: 1500
            case .settings, .jobs: 1200
            default: 700
            }
        }
    }

    /// Whether a reader window has started the plan. Every reader window
    /// asks once its session has started; the plan runs once per process.
    private static var hasStarted = false
    /// The jobs `edit:` and `review:` began, discarded when the plan ends,
    /// so no shots run leaves a worktree behind (corrections §12.3).
    private static var scriptedJobs: [Job] = []

    /// `session` is the reader window that started the plan; `openWindow` is
    /// that window's, for the steps that open a window of their own. Each
    /// step drives the reader window that is key when it runs, which is
    /// `session` until a `window:` or `tab:` step opens another. A `bgtab:`
    /// tab is behind, so the steps after it drive the tab it joined, once
    /// background tabs are on.
    static func run(model: AppModel, session: ReaderSession, openWindow: OpenWindowAction) {
        guard let directory, !hasStarted else { return }
        hasStarted = true
        let plan = (ProcessInfo.processInfo.environment["CCWIKI_SHOT_PLAN"] ?? "home")
            .components(separatedBy: ",")
            .compactMap { Step.parse($0.trimmingCharacters(in: .whitespaces)) }

        Task { @MainActor in
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            NSApp.activate(ignoringOtherApps: true)

            // Nothing in the plan means anything until the library exists.
            for _ in 0..<160 where model.index == nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .milliseconds(900))

            for (offset, step) in plan.enumerated() {
                let reader = model.activeSession ?? session
                await apply(step, model: model, session: reader, openWindow: openWindow)
                try? await Task.sleep(for: .milliseconds(step.settleMilliseconds))

                let name = String(format: "%02d-%@", offset + 1, step.slug)
                if usesExternalCapture {
                    await handOffToScript(directory: directory, index: offset + 1, name: name)
                } else {
                    await capture(to: directory.appending(path: name + ".png"))
                }
                await teardown(step, model: model, session: reader)
                try? await Task.sleep(for: .milliseconds(250))
            }

            for job in scriptedJobs { await model.jobCenter.discard(job) }
            scriptedJobs = []

            if ProcessInfo.processInfo.environment["CCWIKI_SHOT_QUIT"] != "0" {
                NSApp.terminate(nil)
            }
        }
    }

    /// Write `.ready-N` (containing the file name to write), then wait for the
    /// script to answer with `.go-N`.
    private static func handOffToScript(directory: URL, index: Int, name: String) async {
        let ready = directory.appending(path: ".ready-\(index)")
        let go = directory.appending(path: ".go-\(index)")
        try? name.write(to: ready, atomically: true, encoding: .utf8)

        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: go.path(percentEncoded: false)) {
                try? FileManager.default.removeItem(at: go)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func apply(
        _ step: Step, model: AppModel, session: ReaderSession, openWindow: OpenWindowAction
    ) async {
        switch step {
        case .home:
            session.openHome()
        case .welcome:
            session.showWelcome()
        case .whatsNew:
            session.showWhatsNew()
        case .page(let path):
            session.openPage(path)
        case .folder(let slug):
            session.open(.folder(slug: slug))
        case .switcher(let query):
            session.presentQuickSwitcher()
            try? await Task.sleep(for: .milliseconds(250))
            model.quickSwitcherQuery = query
            model.refreshQuickSwitcher()
        case .search(let query):
            session.searchPresented = true
            try? await Task.sleep(for: .milliseconds(250))
            model.searchQuery = query
        case .inspector(let tab):
            session.inspectorTab = tab
            session.showInspector = true
        case .appearance(let name, _):
            // The web view follows `NSAppearance`, so this exercises the
            // reader's dark palette as well as the chrome's.
            NSApp.appearance = NSAppearance(named: name)

        case .jobs:
            model.requestJobsWindow()
            try? await Task.sleep(for: .milliseconds(600))
            NSApp.orderedWindows.first { $0.isVisible && $0.title == "Jobs" }?
                .makeKeyAndOrderFront(nil)
            FileHandle.standardError.write(Data(
                "orphaned worktrees: \(model.orphanedWorktrees.count)\n".utf8))

        case .settings:
            model.requestSettings()
            try? await Task.sleep(for: .milliseconds(600))
            // Report what actually came up: a step that silently captures the
            // wrong window is worse than one that says it could not find it.
            NSApp.orderedWindows.first { $0.isVisible && $0 !== NSApp.mainWindow }?
                .makeKeyAndOrderFront(nil)
            let titles = NSApp.windows
                .filter(\.isVisible)
                .map { "\($0.title.isEmpty ? "(untitled)" : $0.title)\($0.isKeyWindow ? " [key]" : "")" }
            FileHandle.standardError.write(Data("windows: \(titles)\n".utf8))

        case .ingest(let url):
            guard let source = IngestSubmission.Source.parse(url) else {
                FileHandle.standardError.write(Data("unparseable ingest URL: \(url)\n".utf8))
                return
            }
            model.submitIngestion(source: source, pdf: nil, notes: "")
            await waitForJob(model: model)

        case .paper(let path):
            await PaperLibrary.applyShot(path, model: model, openWindow: openWindow)

        case .window(let path):
            openWindow(
                id: CCwikiApp.mainWindowID,
                value: ReaderWindow(opening: .page(path: path, anchor: nil)))

        case .tab(let path, let inBackground):
            // As a ⌘-click or ⇧⌘-click would: through the session, which
            // asks its window's view to open the tab.
            session.open(.page(path: path, anchor: nil), .newTab(inBackground: inBackground))

        case .edit(let path):
            guard let scripted = await beginScriptedEdit(path, model: model, session: session)
            else { return }
            let (job, target) = scripted
            model.requestEditor(
                EditorTarget(jobID: job.id, path: target.repositoryPath), at: target.lines)

        case .review(let path):
            guard let scripted = await beginScriptedEdit(path, model: model, session: session)
            else { return }
            let (job, target) = scripted
            let file = job.worktree.appending(path: target.repositoryPath)
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let edited = shotsEdit(of: text),
                  (try? edited.write(to: file, atomically: true, encoding: .utf8)) != nil
            else {
                note("review: could not make the scripted edit in \(file.path(percentEncoded: false))")
                return
            }
            model.reviewShowsSource = false
            await model.jobCenter.refreshReview(job)
            model.requestJobsWindow(selecting: job.id)
            try? await Task.sleep(for: .milliseconds(600))
            NSApp.orderedWindows.first { $0.isVisible && $0.title == "Jobs" }?
                .makeKeyAndOrderFront(nil)

        case .source:
            model.reviewShowsSource = true

        case .describe(let path), .issue(let path):
            session.openPage(path)
            try? await Task.sleep(for: .milliseconds(1500))
            guard let target = shownTarget(path, model: model, session: session) else { return }
            if case .describe = step {
                session.correctionSheet = CorrectionSheetRequest(.describe, target: target)
            } else {
                session.correctionSheet = CorrectionSheetRequest(.issue, target: target)
            }
        }
    }

    /// Opens `path`, and begins an edit of it through the job center
    /// directly, past the blockers a person would be shown.
    private static func beginScriptedEdit(
        _ path: String, model: AppModel, session: ReaderSession
    ) async -> (Job, CorrectionTarget)? {
        session.openPage(path)
        try? await Task.sleep(for: .milliseconds(1500))
        guard let target = shownTarget(path, model: model, session: session) else { return nil }
        switch await model.jobCenter.beginEdit(target) {
        case .success(let job):
            scriptedJobs.append(job)
            return (job, target)
        case .failure(let error):
            note("edit: \(error.message)")
            return nil
        }
    }

    /// The whole page at `path` as the reader shows it, at the section in
    /// view, as Edit Page… would build it with nothing selected.
    private static func shownTarget(
        _ path: String, model: AppModel, session: ReaderSession
    ) -> CorrectionTarget? {
        guard let page = model.index?.pages[path],
              let fileText = try? String(
                  contentsOf: model.paths.content.appending(path: path), encoding: .utf8)
        else {
            note("no page at \(path)")
            return nil
        }
        let web = session.webController
        let heading = web.activeHeadingID.flatMap { id in web.outline.first { $0.id == id } }
        return CorrectionTarget.make(
            page: page, fileText: fileText,
            renderedMarkdown: web.lastRenderedMarkdown ?? page.body,
            baseCommit: web.lastRenderedRevision ?? model.headRevision ?? "",
            selection: nil,
            readingHeading: heading.map {
                CorrectionTarget.Section(id: $0.id, title: $0.text, level: $0.level)
            })
    }

    /// `review:`'s edit: " (shots)" at the end of the body's first line of
    /// prose. Nil when the page has none.
    nonisolated static func shotsEdit(of text: String) -> String? {
        let frontmatter = Frontmatter.parse(text)
        let bodyLine = text[..<frontmatter.bodyStart].filter { $0 == "\n" }.count
        var lines = text.components(separatedBy: "\n")
        guard bodyLine < lines.count,
              let index = lines[bodyLine...].firstIndex(where: { $0.first?.isLetter == true })
        else { return nil }
        lines[index] += " (shots)"
        return lines.joined(separator: "\n")
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Block until the newest job reaches a terminal state, reporting progress
    /// to stderr so a terminal running `make ingest` can see it happening.
    private static func waitForJob(model: AppModel) async {
        var lastReport = ""
        // A real ingestion is minutes; 40 of them would be pathological.
        for _ in 0..<2_400 {
            guard let job = model.jobs.first else { break }
            let report = "\(job.state.label) · \(job.log.count) events"
            if report != lastReport {
                FileHandle.standardError.write(Data((report + "\n").utf8))
                lastReport = report
            }
            // A job that reached review waits for a person, not for time.
            if job.state.isTerminal || job.state == .awaitingReview { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private static func teardown(_ step: Step, model: AppModel, session: ReaderSession) async {
        switch step {
        case .switcher:
            session.quickSwitcherPresented = false
        case .search:
            session.searchPresented = false
            model.searchQuery = ""
        case .describe, .issue:
            session.correctionSheet = nil
        case .settings:
            NSApp.windows.first { $0.title == "Settings" || $0.title == "Preferences" }?.close()
        default:
            break
        }
    }

    // MARK: In-app fallback capture

    /// The window's layer tree plus the live web content.
    ///
    /// `cacheDisplay` draws the AppKit/SwiftUI hierarchy but leaves a
    /// `WKWebView` blank, because web content renders in another process;
    /// `takeSnapshot` fills that hole. `NSVisualEffectView` backdrops are lost
    /// either way — their blur happens in the window server, which is exactly
    /// what the Screen Recording permission gates access to.
    static func capture(to url: URL) async {
        // Front-to-back order, not `NSApp.windows` order — otherwise a step
        // that opens Settings or the jobs window captures the reader behind it.
        // `keyWindow` is not enough: a freshly opened Settings scene is
        // frontmost without being key.
        let window = NSApp.keyWindow
            ?? NSApp.orderedWindows.first { $0.isVisible && $0.contentView != nil }
        guard let window, window.contentView != nil, let base = snapshot(of: window)
        else { return }

        let size = base.size
        let composed = NSImage(size: size)
        composed.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))

        if let webView = findWebView(in: window.contentView!),
           let webImage = await webSnapshot(webView) {
            webImage.draw(in: webView.convert(webView.bounds, to: window.contentView!))
        }
        composed.unlockFocus()

        write(composed, to: url)
    }

    private static func snapshot(of window: NSWindow) -> NSImage? {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func webSnapshot(_ webView: WKWebView) async -> NSImage? {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.afterScreenUpdates = true
        return try? await webView.takeSnapshot(configuration: configuration)
    }

    private static func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let found = findWebView(in: subview) { return found }
        }
        return nil
    }

    private static func write(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
    }
}
