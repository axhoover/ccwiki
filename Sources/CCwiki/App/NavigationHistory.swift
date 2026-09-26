import Foundation

/// The reader's back and forward stacks.
///
/// Kept apart from `AppModel` so the rules can be tested without a web view.
/// The rule that earns the type its own file: asking for the page you are
/// already on, without an anchor, is not a move. The sidebar does exactly
/// that every time a link reveals the row it just selected, and treating it
/// as a visit pushed the anchored entry a second time and wiped Forward.
struct NavigationHistory: Equatable, Sendable {

    typealias Location = AppModel.Location

    /// How many entries Back keeps. Beyond this the oldest is dropped.
    static let capacity = 100

    private(set) var current: Location = .empty
    private(set) var back: [Location] = []
    private(set) var forward: [Location] = []

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Go to `location`.
    ///
    /// Returns `false` when there is nothing to do: the location is the current
    /// one, or it names the current page with no anchor. The caller decides
    /// whether an anchor on an unchanged location is worth a scroll.
    @discardableResult
    mutating func visit(_ location: Location, recording: Bool = true) -> Bool {
        guard location != current, !namesCurrentPage(location) else { return false }
        if recording, current != .empty {
            back.append(current)
            forward.removeAll()
            if back.count > Self.capacity { back.removeFirst() }
        }
        current = location
        return true
    }

    mutating func goBack() -> Location? {
        guard let previous = back.popLast() else { return nil }
        forward.append(current)
        current = previous
        return previous
    }

    mutating func goForward() -> Location? {
        guard let next = forward.popLast() else { return nil }
        back.append(current)
        current = next
        return next
    }

    /// `.page(path, nil)` where `path` is the page currently showing, whatever
    /// anchor it is showing.
    private func namesCurrentPage(_ location: Location) -> Bool {
        if case .page(let path, nil) = location { return path == current.path }
        return false
    }
}
