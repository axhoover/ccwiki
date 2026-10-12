import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A paper's window: the PDF behind a reference page, keyed by the page's
/// path (plans/reader-comforts.md §2.2, §2.6).
///
/// A PDF is a document, and on the Mac a document gets a window, as in
/// Preview: it stays put while the reader moves through the wiki, and it
/// tiles beside the reader. Titled by its file, as Preview titles a PDF,
/// with the paper's title beneath; the citation key until the PDF is there.
///
/// A PDF already in the library shows at once, without waiting for the
/// wiki. Every other state needs the reference page, so it waits for the
/// wiki to load, and a window whose reference has gone (and whose PDF was
/// never kept) closes itself (SWIFTUI-RULES §6.5).
///
/// Track A seam (§1.7, §2.6): a paper window restored on its own must load
/// the wiki itself. On rebasing onto Track A, `body` gains
/// `.task { await model.launchIfNeeded() }`; until then it waits for a
/// reader window's launch, and shows Loading the Wiki if none comes.
struct PaperWindowView: View {
    let referencePath: String?

    /// Papers tab with each other when the reader prefers tabs, and never
    /// with a reader (§1.8, §7).
    static let tabbingIdentifier = "ccwiki.paper"

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var pageIndicator: PageIndicator?
    @State private var zoom: PaperZoomAction?
    @State private var opener: PDFOpener?
    @State private var isDropTargeted = false
    @State private var confirmsRemoval = false
    @State private var problem: String?

    private struct PageIndicator: Equatable {
        let index: Int
        let count: Int
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(windowTitle)
            .navigationSubtitle(paperTitle)
            .toolbar { toolbar }
            .background { WindowReader { Self.prepare($0) } }
            // Only while the pages are on screen: otherwise View ▸ Zoom In
            // would be an item that does nothing.
            .background {
                if let zoom, readyFile != nil {
                    Color.clear.focusedSceneValue(\.paperZoom, zoom)
                }
            }
            .onDrop(of: [.pdf, .fileURL], isTargeted: $isDropTargeted) { acceptDrop($0) }
            // Mounted permanently and faded, not inserted (SWIFTUI-RULES §1.1).
            .overlay {
                dropOverlay
                    .opacity(isDropTargeted ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: isDropTargeted)
            }
            .onChange(of: closesItself, initial: true) { _, closes in
                if closes { dismiss() }
            }
            .task(id: readyFile) { opener = PDFOpener() }
            .alert("Remove the PDF you added?", isPresented: $confirmsRemoval) {
                Button("Remove", role: .destructive) {
                    if let referencePath { model.papers.remove(referencePath) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(removalMessage)
            }
            .alert("Couldn't Keep the PDF", isPresented: Binding(
                get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK") {}
            } message: {
                Text(problem ?? "")
            }
    }

    // MARK: What to show

    private enum Presentation {
        case paper(PaperRecord, URL)
        case loadingWiki
        case closing
        case reference(WikiPage, PaperLibrary.State)
    }

    private var presentation: Presentation {
        guard let referencePath else { return .closing }
        let state = model.papers.state(for: referencePath)
        if case .ready(let record, let file) = state { return .paper(record, file) }
        guard let index = model.index else { return .loadingWiki }
        guard let page = index.pages[referencePath] else { return .closing }
        return .reference(page, state)
    }

    private var closesItself: Bool {
        if case .closing = presentation { return true }
        return false
    }

    private var reference: WikiPage? {
        referencePath.flatMap { model.index?.pages[$0] }
    }

    private var readyRecord: PaperRecord? {
        if case .paper(let record, _) = presentation { return record }
        return nil
    }

    private var readyFile: URL? {
        if case .paper(_, let file) = presentation { return file }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        switch presentation {
        case .paper(let record, let file):
            paperView(record, file)
        case .loadingWiki:
            ContentUnavailableView {
                Label {
                    Text("Loading the Wiki")
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        case .closing:
            Color.clear
        case .reference(let page, let state):
            unavailableView(page, state)
        }
    }

    // MARK: The paper

    private func paperView(_ record: PaperRecord, _ file: URL) -> some View {
        VStack(spacing: 0) {
            PDFKitView(
                url: file,
                onPageChange: { index, count in
                    pageIndicator = PageIndicator(index: index, count: count)
                },
                onZoom: { zoom = $0 })
            // A replaced paper can keep its file name; the record tells them apart.
            .id("\(record.fileName) \(record.addedAt.timeIntervalSince1970) \(record.bytes)")
            // The title bar's proxy icon: drag the PDF to Mail, ⌘-click for its path.
            .navigationDocument(file)

            statusStrip(record)
        }
    }

    /// Where the paper came from, so a wrong one is noticed, and the page.
    private func statusStrip(_ record: PaperRecord) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.small) {
                Text(Self.provenance(of: record))
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(Self.provenanceHelp(of: record))

                Spacer(minLength: Theme.small)

                if let pageIndicator, pageIndicator.count > 0 {
                    Text("Page \(pageIndicator.index + 1) of \(pageIndicator.count)")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Theme.medium)
            .padding(.vertical, 5)
            .frame(height: Theme.paperStatusBarHeight)
            .background(.bar)
        }
    }

    static func provenance(of record: PaperRecord) -> String {
        let date = record.addedAt.formatted(date: .abbreviated, time: .omitted)
        switch record.origin {
        case .downloaded(let from):
            return "Downloaded from \(from.host() ?? from.absoluteString) · \(date)"
        case .addedByYou:
            return "Added by you · \(date)"
        }
    }

    private static func provenanceHelp(of record: PaperRecord) -> String {
        switch record.origin {
        case .downloaded(let from): from.absoluteString
        case .addedByYou: "A PDF you added. CCwiki keeps the only copy it has."
        }
    }

    // MARK: Every other state (§2.7)

    @ViewBuilder
    private func unavailableView(_ page: WikiPage, _ state: PaperLibrary.State) -> some View {
        switch state {
        case .notDownloaded:
            let source = PaperSource(page: page)
            if let first = source.candidates.first {
                notDownloadedView(page, from: first)
            } else {
                failureView(.noLink(source: source.sourceURL), page: page)
            }
        case .downloading(let host, let received, let expected):
            downloadingView(page, host: host, received: received, expected: expected)
        case .failed(let failure):
            failureView(failure, page: page)
        case .ready:
            EmptyView()
        }
    }

    private func notDownloadedView(
        _ page: WikiPage, from candidate: PaperSource.Candidate
    ) -> some View {
        let host = candidate.url.host() ?? candidate.url.absoluteString
        // A landing page may name its PDF, often one behind a subscription:
        // CCwiki can promise to look for it, not to download it. The Show
        // Paper button's tooltip makes the same distinction.
        let promise = candidate.kind == .landingPage
            ? "CCwiki looks for the PDF at \(host) and keeps it in its library."
            : "CCwiki downloads it from \(host) once and keeps it in its library."
        return ContentUnavailableView {
            Label("Paper Not Downloaded", systemImage: "doc.richtext")
        } description: {
            Text(promise)
        } actions: {
            Button("Download") { model.papers.show(page) }
                .keyboardShortcut(.defaultAction)
            Button("Choose PDF…") { choosePDF(for: page) }
        }
    }

    private func downloadingView(
        _ page: WikiPage, host: String, received: Int64, expected: Int64?
    ) -> some View {
        // Indeterminate until the size is known.
        let fraction = expected.map { $0 > 0 ? min(1, Double(received) / Double($0)) : 0 }
        return ContentUnavailableView {
            Label {
                Text("Downloading the Paper")
            } icon: {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
            }
        } description: {
            VStack(spacing: Theme.tight) {
                Text("From \(host).")
                Text(Self.progressText(received: received, expected: expected))
                    .font(Theme.Fonts.meta)
                    .monospacedDigit()
            }
        } actions: {
            Button("Cancel") { model.papers.cancel(page.path) }
                .keyboardShortcut(.cancelAction)
        }
    }

    /// "4.2 MB of 11 MB", or "4.2 MB" while the size is unknown.
    static func progressText(received: Int64, expected: Int64?) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        let got = formatter.string(fromByteCount: received)
        guard let expected, expected > 0 else { return got }
        return "\(got) of \(formatter.string(fromByteCount: expected))"
    }

    private func failureView(_ failure: PaperFailure, page: WikiPage) -> some View {
        ContentUnavailableView {
            Label {
                Text(failure.title)
            } icon: {
                // Offline is not a fault (design-system §4b): tertiary, like
                // the status bar's.
                Image(systemName: failure.systemImage)
                    .foregroundStyle(failure == .offline
                        ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            }
        } description: {
            Text(failure.message)
        } actions: {
            if failure.offersRetry {
                Button("Try Again") { model.papers.retry(page) }
                    .keyboardShortcut(.defaultAction)
            }
            if let url = failure.openURL, let host = url.host() {
                Button("Open on \(host)") { NSWorkspace.shared.open(url) }
            }
            if failure.offersChoosePDF {
                Button("Choose PDF…") { choosePDF(for: page) }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(opener?.title ?? PDFOpener.fallbackTitle) {
                if let readyFile { opener?.open(readyFile) }
            }
            .disabled(readyFile == nil || opener == nil)
            .help("Open the PDF in the app your Mac opens PDFs with")

            Menu {
                Button("Show Reference Page") { showReferencePage() }
                    .disabled(reference == nil)
                Button("Reveal in Finder") {
                    if let readyFile { NSWorkspace.shared.activateFileViewerSelecting([readyFile]) }
                }
                .disabled(readyFile == nil)
                Button("Copy Source Link") {
                    if let sourceURL { model.copyToPasteboard(sourceURL.absoluteString) }
                }
                .disabled(sourceURL == nil)

                Divider()

                Button(chooseTitle) {
                    if let reference { choosePDF(for: reference) }
                }
                .disabled(reference == nil)
                Button("Remove From Library") { requestRemoval() }
                    .disabled(readyRecord == nil)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More")
        }
    }

    private var sourceURL: URL? {
        reference?.source.flatMap { URL(string: $0) }
    }

    private var chooseTitle: String {
        readyFile == nil ? "Choose PDF…" : "Choose Another PDF…"
    }

    // MARK: Actions

    /// An explicit Show, so the page must be seen: in the reader, opening
    /// one if none is on screen.
    ///
    /// Track A seam (§1.8): on rebasing onto Track A, the body becomes
    /// `model.revealInReader(.page(path: reference.path, anchor: nil))`,
    /// which brings the reader showing the page forward, and, when that
    /// returns false, `openWindow(id: CCwikiApp.mainWindowID,
    /// value: ReaderWindow(opening: location))`. Until then an open reader
    /// changes page without coming forward, and `model.openPage` here fails
    /// A3's grep gate.
    private func showReferencePage() {
        guard let reference else { return }
        if model.mainWindowCount == 0 {
            openWindow(id: CCwikiApp.mainWindowID)
        }
        model.openPage(reference.path)
    }

    private func choosePDF(for page: WikiPage) {
        let panel = NSOpenPanel()
        panel.title = "Choose the PDF for \(page.title)"
        panel.message = "CCwiki keeps a copy in its library."
        panel.prompt = "Keep"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adopt(url, for: page)
    }

    private func adopt(_ url: URL, for page: WikiPage) {
        do {
            try model.papers.adopt(url, for: page)
        } catch {
            problem = error.localizedDescription
        }
    }

    /// A downloaded paper goes to the Trash at once. One you added is the
    /// only copy CCwiki has, so it asks first.
    private func requestRemoval() {
        guard let referencePath, let readyRecord else { return }
        if readyRecord.origin == .addedByYou {
            confirmsRemoval = true
        } else {
            model.papers.remove(referencePath)
        }
    }

    private var removalMessage: String {
        let hasLink = reference.map { !PaperSource(page: $0).candidates.isEmpty } ?? false
        let lastFetchFailed = referencePath.flatMap { model.papers.lastFailure(for: $0) } != nil
        let canDownload = hasLink && !lastFetchFailed
        return "CCwiki keeps no other copy." + (canDownload ? "" : " It can't download this paper.")
    }

    // MARK: Drop

    private var dropHeadline: String {
        let key = reference?.title ?? Self.names(fromPath: referencePath ?? "").key
        return readyFile == nil ? "Keep This PDF for \(key)" : "Replace the PDF for \(key)"
    }

    /// The reader's drop overlay, in words of its own: the reader's promises
    /// an ingestion job.
    private var dropOverlay: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: Theme.small) {
                Image(systemName: "doc.badge.plus")
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                Text(dropHeadline)
                    .font(Theme.Fonts.emptyTitle)
                Text("CCwiki keeps a copy in its library.")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
            }
        }
        .allowsHitTesting(false)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let reference, let provider = providers.first else { return false }
        // The title bar's proxy icon is this paper's own file. Dragged over
        // the window and let go there, it is a drag given up, not a PDF to
        // keep in place of itself as one you added.
        let current = readyFile?.resolvingSymlinksInPath()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            guard url.pathExtension.lowercased() == "pdf" else {
                Task { @MainActor in problem = "“\(url.lastPathComponent)” is not a PDF." }
                return
            }
            guard url.resolvingSymlinksInPath() != current else { return }
            Task { @MainActor in adopt(url, for: reference) }
        }
        return true
    }

    // MARK: Titles

    private var windowTitle: String {
        if let readyRecord { return readyRecord.fileName }
        return reference?.title ?? Self.names(fromPath: referencePath ?? "").key
    }

    private var paperTitle: String {
        reference?.displayTitle ?? Self.names(fromPath: referencePath ?? "").title
    }

    /// The key and the title a reference's file name carries,
    /// `KEY - Title.md`: what the window can say before the wiki loads.
    static func names(fromPath path: String) -> (key: String, title: String) {
        let stem = WikiPage.stem(of: path)
        guard let separator = stem.range(of: " - ") else { return (stem, "") }
        return (String(stem[..<separator.lowerBound]), String(stem[separator.upperBound...]))
    }

    // MARK: Window

    /// Never a reader's tab, and no taller than the screen: a 13-inch laptop
    /// has about 870 pt, and on macOS 14 `.defaultSize` cannot read the
    /// screen (§2.2).
    static func prepare(_ window: NSWindow) {
        window.tabbingIdentifier = tabbingIdentifier
        fitToScreen(window)
        // SwiftUI may still size the window after this first report.
        Task { @MainActor in fitToScreen(window) }
    }

    private static func fitToScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        guard frame.height > visible.height || frame.minY < visible.minY
                || frame.maxY > visible.maxY
        else { return }
        frame.size.height = min(frame.height, visible.height)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true)
    }
}

/// Which actions a failure offers (§2.7): Try Again where waiting or another
/// attempt might help, Choose PDF… wherever a copy of your own would.
private extension PaperFailure {
    var offersRetry: Bool {
        switch self {
        case .busy, .unreachable, .offline, .unreadable, .unexpected: true
        case .noLink, .notAPDF, .refused, .notFound, .tooLarge: false
        }
    }

    var offersChoosePDF: Bool {
        if case .busy = self { return false }
        return true
    }
}

/// The app Open in … hands a paper to (§2.6): the Mac's default for PDFs,
/// named after it, so a Skim user reads "Open in Skim". When that default is
/// CCwiki itself, Preview.
@MainActor
struct PDFOpener {
    static let fallbackTitle = "Open in Preview"

    let applicationURL: URL?
    let name: String

    init() {
        let workspace = NSWorkspace.shared
        var application = workspace.urlForApplication(toOpen: .pdf)
        if let current = application, Self.isCCwiki(current) {
            application = workspace.urlForApplication(withBundleIdentifier: "com.apple.Preview")
        }
        applicationURL = application
        name = application.map(Self.displayName(of:)) ?? "Preview"
    }

    var title: String { "Open in \(name)" }

    func open(_ file: URL) {
        guard let applicationURL else {
            NSWorkspace.shared.open(file)
            return
        }
        NSWorkspace.shared.open(
            [file], withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    /// The release and CCwiki Dev both declare PDFs; neither is a PDF reader.
    private static func isCCwiki(_ application: URL) -> Bool {
        guard let identifier = Bundle(url: application)?.bundleIdentifier else { return false }
        return [BuildIdentity.releaseBundleIdentifier, BuildIdentity.devBundleIdentifier,
                Bundle.main.bundleIdentifier].contains(identifier)
    }

    private static func displayName(of application: URL) -> String {
        let name = FileManager.default.displayName(atPath: application.path(percentEncoded: false))
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

extension Theme {

    // MARK: Paper window

    /// A US Letter page and its margins (§2.2). The height is clamped to the
    /// screen's visible frame on first show; a 13-inch laptop has about 870 pt.
    static let paperDefaultWidth: CGFloat = 780
    static let paperDefaultHeight: CGFloat = 980
    static let paperMinWidth: CGFloat = 480
    static let paperMinHeight: CGFloat = 560
    /// The strip under the pages, matching the reader's status bar.
    static let paperStatusBarHeight: CGFloat = 26
}

/// Wiki ▸ Show Paper (⌥⌘P), and the reference bar's button: the paper behind
/// the reference page being read, in its own window.
enum ShowPaperCommand {

    /// Gates the menu item and the button, so neither ships before papers
    /// can be fetched (SWIFTUI-RULES §7.4).
    static let isAvailable = true

    /// Only a reference page has a paper behind it.
    @MainActor static func isEnabled(for page: WikiPage?) -> Bool {
        page?.kind == .reference
    }

    /// Start the fetch, unless the paper is already kept, and bring its
    /// window forward. One window per paper: `WindowGroup` brings an open
    /// one forward rather than opening it twice.
    @MainActor static func perform(
        _ page: WikiPage, model: AppModel, openWindow: OpenWindowAction
    ) {
        model.papers.show(page)
        openWindow(id: CCwikiApp.paperWindowID, value: page.path)
    }
}

/// View ▸ Zoom In, Zoom Out and Actual Size, while a paper window is key.
/// The paper's `PDFView` hands these up, and the View menu's text-size items
/// act on them in its place, retitled as Preview titles them.
struct PaperZoomAction: Sendable {
    let zoomIn: @MainActor @Sendable () -> Void
    let zoomOut: @MainActor @Sendable () -> Void
    /// Fit to the window again: `autoScales` back on.
    let actualSize: @MainActor @Sendable () -> Void
}

// `@Entry` on a FocusedValues property is macOS 15; this is the macOS 14 form.
private struct PaperZoomKey: FocusedValueKey {
    typealias Value = PaperZoomAction
}

extension FocusedValues {
    var paperZoom: PaperZoomAction? {
        get { self[PaperZoomKey.self] }
        set { self[PaperZoomKey.self] = newValue }
    }
}
