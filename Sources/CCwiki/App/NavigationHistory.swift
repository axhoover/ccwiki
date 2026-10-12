import Foundation

/// The reader's back and forward stacks.
///
/// Kept apart from `AppModel` so the rules can be tested without a web view.
/// The rule that earns the type its own file: asking for the page you are
/// already on, without an anchor, is not a move. The sidebar does exactly
/// that every time a link reveals the row it just selected, and treating it
/// as a visit pushed the anchored entry a second time and wiped Forward.
///
/// `Codable`, so a window's Back and Forward come back with it when macOS
/// restores the window (plans/reader-comforts.md §1.7). A decoded history
/// goes through `init(current:back:forward:)`, so it keeps the same bounds as
/// one built by visiting.
struct NavigationHistory: Equatable, Sendable, Codable {

    typealias Location = AppModel.Location

    /// How many entries Back keeps, and Forward. Beyond this the oldest is
    /// dropped.
    static let capacity = 100

    private(set) var current: Location = .empty
    private(set) var back: [Location] = []
    private(set) var forward: [Location] = []

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Nowhere yet: nothing on screen, nothing to go back or forward to.
    init() {}

    /// A saved history; `capacity` applies to Back and Forward, on decode too.
    ///
    /// `back` and `forward` are stacks, nearest entry last, as the history
    /// keeps them. Neither ever holds `.empty`, since a visit never records
    /// it, and a history with nothing on screen has nothing behind it or
    /// ahead of it. Saved state that says otherwise is made to agree.
    init(current: Location, back: [Location], forward: [Location]) {
        var back = Array(back.filter { $0 != .empty }.suffix(Self.capacity))
        var forward = Array(forward.filter { $0 != .empty }.suffix(Self.capacity))
        var current = current
        if current == .empty, let previous = back.popLast() { current = previous }
        if current == .empty { forward = [] }
        self.current = current
        self.back = back
        self.forward = forward
    }

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

    /// Without the entries `keep` rejects. A rejected current becomes the
    /// nearest kept Back entry, else `.empty`; adjacent duplicates collapse.
    ///
    /// How a restored window forgets the pages a pull deleted: Back and
    /// Forward then never land on a page the wiki no longer has, and
    /// removing one between two visits to the same page does not leave a
    /// step that goes nowhere.
    func pruned(keeping keep: (Location) -> Bool) -> NavigationHistory {
        var back = Self.collapsed(self.back.filter(keep))
        var forward = Self.collapsed(self.forward.filter(keep))
        var current = self.current
        if !keep(current) { current = back.popLast() ?? .empty }
        while back.last == current { back.removeLast() }
        while forward.last == current { forward.removeLast() }
        return NavigationHistory(current: current, back: back, forward: forward)
    }

    /// `entries` with each run of equal neighbours reduced to one.
    private static func collapsed(_ entries: [Location]) -> [Location] {
        var result: [Location] = []
        for entry in entries where entry != result.last { result.append(entry) }
        return result
    }

    /// `.page(path, nil)` where `path` is the page currently showing, whatever
    /// anchor it is showing.
    private func namesCurrentPage(_ location: Location) -> Bool {
        if case .page(let path, nil) = location { return path == current.path }
        return false
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case current, back, forward
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            current: try container.decode(Location.self, forKey: .current),
            back: try container.decode([Location].self, forKey: .back),
            forward: try container.decode([Location].self, forKey: .forward))
    }
}
