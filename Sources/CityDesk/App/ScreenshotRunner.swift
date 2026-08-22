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
/// - **External** (`CITYDESK_SHOT_EXTERNAL=1`, what `make shots` uses): the app
///   writes a `.ready-N` marker, waits for `.go-N`, and the script runs
///   `screencapture -l`. Pixel-accurate, vibrancy and all — but it needs the
///   Screen Recording permission.
/// - **In-app fallback**: `cacheDisplay` plus `WKWebView.takeSnapshot`, which
///   needs no permission but cannot draw `NSVisualEffectView` backdrops, so
///   sidebars and toolbars come out flat.
///
/// Absent `CITYDESK_SHOTS` this type does nothing at all.
@MainActor
enum ScreenshotRunner {

    static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["CITYDESK_SHOTS"], !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static var usesExternalCapture: Bool {
        ProcessInfo.processInfo.environment["CITYDESK_SHOT_EXTERNAL"] == "1"
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
            case "light": return .appearance(.aqua, label: "light")
            case "dark": return .appearance(.darkAqua, label: "dark")
            case "ingest": return parts.count > 1 ? .ingest(parts[1]) : nil
            case "settings": return .settings
            case "jobs": return .jobs
            default: return nil
            }
        }

        var slug: String {
            switch self {
            case .home: "home"
            case .page(let path):
                (path as NSString).lastPathComponent
                    .replacingOccurrences(of: ".md", with: "")
                    .replacingOccurrences(of: " ", with: "-")
            case .folder(let slug): "folder-\(slug)"
            case .switcher(let query): "switcher-\(query.isEmpty ? "empty" : query)"
            case .search(let query): "search-\(query.replacingOccurrences(of: " ", with: "-"))"
            case .inspector(let tab): "inspector-\(tab.rawValue.lowercased())"
            case .appearance(_, let label): label
            case .ingest: "ingest"
            case .settings: "settings"
            case .jobs: "jobs"
            }
        }

        /// Rendering a page needs longer to settle than flipping a picker.
        var settleMilliseconds: Int {
            switch self {
            case .page, .folder, .home: 1500
            case .search: 900
            // An ingestion job is minutes, not milliseconds; `apply` waits for
            // a terminal state rather than guessing a duration.
            case .ingest: 1500
            case .settings, .jobs: 1200
            default: 700
            }
        }
    }

    static func run(model: AppModel) {
        guard let directory else { return }
        let plan = (ProcessInfo.processInfo.environment["CITYDESK_SHOT_PLAN"] ?? "home")
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
                await apply(step, model: model)
                try? await Task.sleep(for: .milliseconds(step.settleMilliseconds))

                let name = String(format: "%02d-%@", offset + 1, step.slug)
                if usesExternalCapture {
                    await handOffToScript(directory: directory, index: offset + 1, name: name)
                } else {
                    await capture(to: directory.appending(path: name + ".png"))
                }
                await teardown(step, model: model)
                try? await Task.sleep(for: .milliseconds(250))
            }

            if ProcessInfo.processInfo.environment["CITYDESK_SHOT_QUIT"] != "0" {
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

    private static func apply(_ step: Step, model: AppModel) async {
        switch step {
        case .home:
            model.openHome()
        case .page(let path):
            model.openPage(path)
        case .folder(let slug):
            model.open(.folder(slug: slug))
        case .switcher(let query):
            model.presentQuickSwitcher()
            try? await Task.sleep(for: .milliseconds(250))
            model.quickSwitcherQuery = query
            model.refreshQuickSwitcher()
        case .search(let query):
            model.searchPresented = true
            try? await Task.sleep(for: .milliseconds(250))
            model.searchQuery = query
        case .inspector(let tab):
            model.inspectorTab = tab
            model.showInspector = true
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
        }
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
            if job.state.isTerminal { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private static func teardown(_ step: Step, model: AppModel) async {
        switch step {
        case .switcher:
            model.quickSwitcherPresented = false
        case .search:
            model.searchPresented = false
            model.searchQuery = ""
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
