import Foundation

// The Relations Explorer's and the derived sections' preferences
// (relations-explorer.md §2.12, §3.4). Ids are persisted, never labels, so a
// title renamed upstream still matches.

extension CCwikiSettings {

    private static let explorerQueryKey = "ccwiki.explorer.query"
    private static let explorerRecentsKey = "ccwiki.explorer.recents"
    private static let derivedSectionsExpandedKey = "ccwiki.derivedSectionsExpanded"

    /// The explorer's question, as JSON. Restored at launch through
    /// `ExplorerQuery.launching()`, which turns the models toggle off.
    static var explorerQuery: ExplorerQuery? {
        get {
            guard let data = UserDefaults.standard.data(forKey: explorerQueryKey) else { return nil }
            return try? JSONDecoder().decode(ExplorerQuery.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                UserDefaults.standard.removeObject(forKey: explorerQueryKey)
                return
            }
            UserDefaults.standard.set(data, forKey: explorerQueryKey)
        }
    }

    /// Earlier questions, newest first, each with its toggle.
    static var explorerRecents: [ExplorerQuery] {
        get {
            guard let data = UserDefaults.standard.data(forKey: explorerRecentsKey) else { return [] }
            return (try? JSONDecoder().decode([ExplorerQuery].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: explorerRecentsKey)
        }
    }

    /// Which of the inspector's derived sections are open, by role. Per
    /// role, not per page, as an Xcode inspector section behaves: open it
    /// once and it stays open as you move around.
    static var derivedSectionsExpanded: [String] {
        get { UserDefaults.standard.stringArray(forKey: derivedSectionsExpandedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: derivedSectionsExpandedKey) }
    }
}
