import Foundation

/// A reader window's identity, and what it was opened to show.
///
/// The value of `WindowGroup(for: ReaderWindow.self)`. Every value is new,
/// with an id of its own, so `openWindow(id:value:)` always opens a window:
/// SwiftUI brings an existing window forward only for a value it already
/// shows (plans/reader-comforts.md §1.3).
struct ReaderWindow: Codable, Hashable, Sendable {
    var id = UUID()
    /// Where an Open in New Tab or New Window starts. Ignored when the
    /// window has restored state (§1.7).
    var opening: AppModel.Location? = nil
    /// Found on the page once `opening` renders: a search hit opened in a new
    /// tab still lands on its match.
    var find: [String]? = nil
    /// The 0-based line of the page's body revealed once `opening` renders:
    /// a backlink's mention opened in a new tab still lands on its line.
    var revealing: Int? = nil
}

/// A window the app is opening itself, and how it joins the others.
struct ReaderWindowRequest: Equatable, Sendable {
    var window: ReaderWindow
    /// `NSWindow.windowNumber` of the reader to join as a tab; nil, a window.
    var tabbingInto: Int?
    var inBackground: Bool
}

extension ReaderWindowRequest {
    /// How `window` joins the others when it opens as `disposition` says,
    /// from the reader window numbered `source`: as a tab of that window,
    /// behind it or in front, or as a window of its own (§1.4).
    ///
    /// Nil for a disposition that opens no window: where you are, or the
    /// site. A tab with no window to join is a window of its own, as ⌘T is
    /// while the explorer or Jobs is key.
    init?(opening window: ReaderWindow, as disposition: LinkDisposition, beside source: Int?) {
        switch disposition {
        case .newTab(let inBackground):
            self.init(window: window, tabbingInto: source, inBackground: inBackground)
        case .newWindow:
            self.init(window: window, tabbingInto: nil, inBackground: false)
        case .here, .onSite:
            return nil
        }
    }
}

/// The tabbing of windows the caller is opening itself. Pure.
///
/// `openWindow` cannot say where a window goes, so the request waits here
/// until the new window's view first sees its `NSWindow` and takes it
/// (§1.4).
struct ReaderWindowRequests: Equatable, Sendable {
    private var pending: [UUID: ReaderWindowRequest] = [:]

    init() {}

    mutating func expect(_ request: ReaderWindowRequest) {
        pending[request.window.id] = request
    }

    /// Consumed once, by the window the request names.
    mutating func takeTabbing(for windowID: UUID) -> ReaderWindowRequest? {
        pending.removeValue(forKey: windowID)
    }
}

/// A reader tab or window as it was when it closed: what Edit ▸ Undo Close
/// Tab opens again (plans/reader-comforts.md §7).
struct ClosedTab: Equatable, Sendable {
    /// Its history, inspector and folders, as macOS restores a window.
    var state: ReaderSessionState
    /// The heading being read, kept apart from `state` as the window's
    /// scene storage keeps it.
    var readingAnchor: String?
}

/// The reader tabs and windows closed in this process, most recent first.
/// Pure.
///
/// In memory only: a relaunch has nothing to undo, and a window macOS
/// restores brings back its own state.
struct ClosedTabs: Equatable, Sendable {
    /// How far back Undo Close Tab goes.
    static let limit = 10

    private(set) var tabs: [ClosedTab] = []

    init() {}

    var isEmpty: Bool { tabs.isEmpty }

    /// Keeps `tab`, the most recent now; the oldest goes past `limit`. A tab
    /// that showed nothing, such as a window closed before the wiki first
    /// loaded, is not kept: opened again, it would be a new tab.
    mutating func remember(_ tab: ClosedTab) {
        guard tab.state.history.current != .empty else { return }
        tabs.insert(tab, at: 0)
        if tabs.count > Self.limit { tabs.removeLast(tabs.count - Self.limit) }
    }

    /// The tab closed last, taken: the next one is the one before it.
    mutating func takeLast() -> ClosedTab? {
        tabs.isEmpty ? nil : tabs.removeFirst()
    }
}

/// The reader windows, most recently key first. Pure.
///
/// What "the active reader" means to a window that is not one: the
/// explorer, Jobs and a paper window open pages in the reader used last
/// (§1.8).
struct SessionOrder<ID: Hashable & Sendable>: Equatable, Sendable {
    private var ids: [ID] = []

    init() {}

    /// Least recent until it becomes key: a window opened in the background
    /// is not where the explorer's next page should go.
    mutating func opened(_ id: ID) {
        guard !ids.contains(id) else { return }
        ids.append(id)
    }

    mutating func becameKey(_ id: ID) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
    }

    mutating func closed(_ id: ID) {
        ids.removeAll { $0 == id }
    }

    var mostRecent: ID? { ids.first }
    var count: Int { ids.count }
}

/// Which window shows the ingest sheet. Pure; a key change never moves it.
///
/// Fixed when the sheet is asked for, so its link, notes and dropped PDF
/// stay on one window while the reader clicks another (§1.3).
struct IngestSheetTarget: Equatable, Sendable {
    private(set) var window: UUID?
    /// Asked for with no reader open.
    private(set) var isWaiting: Bool

    init() {
        window = nil
        isWaiting = false
    }

    /// Pins to `window`, else `active`, else waits. No-op while one is shown.
    mutating func request(in window: UUID?, active: UUID?) {
        guard self.window == nil else { return }
        if let target = window ?? active {
            self.window = target
            isWaiting = false
        } else {
            isWaiting = true
        }
    }

    /// A new session claims a waiting request; true once.
    mutating func claim(by session: UUID) -> Bool {
        guard isWaiting, window == nil else { return false }
        window = session
        isWaiting = false
        return true
    }

    mutating func dismiss() {
        window = nil
        isWaiting = false
    }

    /// The sheet's window closed, and the sheet with it.
    mutating func windowClosed(_ id: UUID) {
        if window == id { window = nil }
    }
}
