import Foundation

/// The pages a reader saved with Save Page (⌘D), in the order they put them
/// (plans/efficiency.md §3.3).
///
/// A value, so every operation is tested without a window or the user
/// defaults. `AppModel` holds the one list every window shows, and
/// `CCwikiSettings.savedPages` keeps it as JSON between launches.
///
/// An entry names its page by path, as `WikiIndex.pages` keys it, and keeps
/// the page's title: after a pull, the title is all a reader still knows of
/// a page whose file went, so `reconciled(with:)` looks the page up by it.
struct SavedPages: Equatable, Sendable {

    /// A saved page, or a section of one.
    struct Entry: Codable, Hashable, Identifiable, Sendable {
        /// Content-relative, as `WikiIndex.pages` keys it.
        var path: String
        /// A heading's id, for a saved section; nil for the page.
        var anchor: String?
        /// A saved section's heading as the outline showed it when it was
        /// saved; nil for the page. Shown, never looked up.
        var sectionTitle: String?
        /// The page's title, never a section's heading: reconciliation looks
        /// it up.
        var title: String
        var savedAt: Date

        /// A saved section's name: its heading, or its id where an entry
        /// has no heading. Nil for the page.
        var sectionName: String? {
            anchor.map { sectionTitle ?? $0 }
        }

        /// The entry on one line, as Wiki ▸ Saved Pages lists it: the
        /// page's title, then a section's name after a §, as a variant is
        /// named ("Host § Title").
        var menuTitle: String {
            sectionName.map { "\(title) § \($0)" } ?? title
        }

        /// A page and a section of it are two entries. Not a string, so the
        /// sidebar's scroll to a page's row in the tree, by path, never
        /// lands on its saved row instead.
        var id: Key { Key(path: path, anchor: anchor) }

        struct Key: Hashable, Sendable {
            let path: String
            let anchor: String?
        }
    }

    private(set) var entries: [Entry]

    /// The entries in order, the first of each page or section, and none
    /// without a path.
    init(_ entries: [Entry] = []) {
        var seen: Set<Entry.Key> = []
        self.entries = entries.filter { !$0.path.isEmpty && seen.insert($0.id).inserted }
    }

    var isEmpty: Bool { entries.isEmpty }

    func contains(path: String, anchor: String? = nil) -> Bool {
        entries.contains { $0.id == Entry.Key(path: path, anchor: anchor) }
    }

    /// Saves a page, or a section of one, at the end of the list, where a new
    /// bookmark goes. Saving one already saved changes nothing. A section
    /// keeps its heading, `sectionTitle`; the page keeps none.
    mutating func add(
        path: String, anchor: String? = nil, sectionTitle: String? = nil, title: String,
        at date: Date = Date()
    ) {
        guard !path.isEmpty, !contains(path: path, anchor: anchor) else { return }
        entries.append(Entry(
            path: path, anchor: anchor, sectionTitle: anchor == nil ? nil : sectionTitle,
            title: title, savedAt: date))
    }

    mutating func remove(path: String, anchor: String? = nil) {
        entries.removeAll { $0.id == Entry.Key(path: path, anchor: anchor) }
    }

    /// A drag in the list, as `ForEach.onMove` reports it: `destination` is
    /// an offset in the list as it was before the move. The same result as
    /// SwiftUI's `move(fromOffsets:toOffset:)`, which this layer does not
    /// import. Offsets outside the list are ignored.
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let offsets = source.filter { entries.indices.contains($0) }
        guard !offsets.isEmpty else { return }
        let moving = offsets.map { entries[$0] }
        var rest = entries
        for offset in offsets.reversed() { rest.remove(at: offset) }
        let above = offsets.count { $0 < destination }
        rest.insert(contentsOf: moving, at: min(max(destination - above, 0), rest.count))
        entries = rest
    }

    /// Move Up and Move Down: `step` places toward the bottom, or toward the
    /// top when negative. Past either end, nothing.
    mutating func move(_ id: Entry.Key, by step: Int) {
        guard let from = entries.firstIndex(where: { $0.id == id }),
              entries.indices.contains(from + step) else { return }
        let entry = entries.remove(at: from)
        entries.insert(entry, at: from + step)
    }

    // MARK: After a load

    /// The list as a new wiki has it. A page still at its path keeps its
    /// place and takes its title as the wiki has it now. A page whose file
    /// went is looked up by its title: among the new index's aliases and file
    /// names, as a wikilink with that text resolves it (`WikiIndex.resolve`),
    /// and then as the one page with exactly that title. Found, the entry
    /// points there. Not found, it stays as it was, and the sidebar says it
    /// is no longer in the wiki. An entry that comes to name a page already
    /// saved is that page twice, and the first is kept.
    func reconciled(with index: WikiIndex) -> SavedPages {
        SavedPages(entries.map { entry in
            var entry = entry
            if let page = index.pages[entry.path] {
                entry.title = page.title
            } else if let page = Self.page(titled: entry.title, in: index, from: entry.path)
                        ?? Self.onlyPage(titled: entry.title, in: index) {
                entry.path = page.path
                entry.title = page.title
            }
            return entry
        })
    }

    /// The page a `[[title]]` written on the page at `sourcePath` would
    /// open, if any. A whole page only: a `#` in a title splits it, and the
    /// text before the `#` names some other page.
    private static func page(
        titled title: String, in index: WikiIndex, from sourcePath: String
    ) -> WikiPage? {
        let link = Wikilink(
            target: title, rawAnchor: nil, alias: nil, isEmbed: false,
            range: title.startIndex..<title.startIndex)
        guard case .page(let path, nil) = index.resolve(link, from: sourcePath) else { return nil }
        return index.pages[path]
    }

    /// The one page whose title is `title`, when exactly one has it: a file
    /// renamed without its old name kept as an alias, as the wiki renamed
    /// `Oblivious RAM.md` to `oblivious-ram.md`. A slug keeps its case, so
    /// no link with the old title finds the new file.
    private static func onlyPage(titled title: String, in index: WikiIndex) -> WikiPage? {
        let titled = index.pages.values.filter { $0.title == title }
        return titled.count == 1 ? titled[0] : nil
    }

    // MARK: JSON

    /// The list as JSON, for the user defaults. Nil only if a date cannot be
    /// written, and then nothing is.
    var json: Data? {
        try? JSONEncoder().encode(entries)
    }

    /// The list `json` wrote. Tolerant, since the defaults outlive builds:
    /// data that is not a list reads as nothing saved, and an entry that
    /// cannot be read is left out, as is a second entry for one page.
    init(json data: Data) {
        let read = (try? JSONDecoder().decode([Readable].self, from: data)) ?? []
        self.init(read.compactMap(\.entry))
    }

    /// An entry, or nil where the list holds something else.
    private struct Readable: Decodable {
        let entry: Entry?

        init(from decoder: any Decoder) throws {
            entry = try? decoder.singleValueContainer().decode(Entry.self)
        }
    }
}
