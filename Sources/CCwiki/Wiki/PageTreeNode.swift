import Foundation

/// The sidebar's directory tree, mirroring `content/` in the repo.
///
/// Two ordering rules, both taken from how the wiki is actually read:
/// folders sort before pages, and pages sort by title rather than filename —
/// which matters most in `References/`, where the filename starts with a
/// citation key but the site sorts by that key's `title`.
struct PageTreeNode: Identifiable, Sendable {
    let id: String
    let name: String
    let page: WikiPage?
    var children: [PageTreeNode]

    var isFolder: Bool { page == nil }

    /// `nil` for a leaf, so `OutlineGroup` renders it without a disclosure
    /// triangle.
    var outlineChildren: [PageTreeNode]? { isFolder ? children : nil }

    /// Every page at or under this node — the count shown next to a folder.
    var pageCount: Int {
        isFolder ? children.reduce(0) { $0 + $1.pageCount } : 1
    }

    /// Build the tree, optionally leaving some kinds out.
    ///
    /// The sidebar leaves `.reference` out: 200 of the wiki's 293 pages are
    /// references, so including them makes the tree two-thirds citation store
    /// and pushes the concept structure off screen the moment you follow a
    /// citation. They get a single row that opens the folder page instead —
    /// a 200-item list belongs in the content pane, not a 268 pt sidebar.
    static func build(pages: [WikiPage], excluding kinds: Set<PageKind> = []) -> [PageTreeNode] {
        var folders: [String: [WikiPage]] = [:]
        var roots: [WikiPage] = []

        for page in pages where !kinds.contains(page.kind) {
            if page.directory.isEmpty {
                roots.append(page)
            } else {
                folders[page.directory, default: []].append(page)
            }
        }

        var nodes = folders.keys.sorted().map { directory in
            PageTreeNode(
                id: directory,
                name: directory,
                page: nil,
                children: folders[directory]!.sorted(by: titleOrder).map(leaf))
        }
        nodes.append(contentsOf: roots.sorted(by: titleOrder).map(leaf))
        return nodes
    }

    private static func leaf(_ page: WikiPage) -> PageTreeNode {
        PageTreeNode(id: page.path, name: page.title, page: page, children: [])
    }

    private static func titleOrder(_ a: WikiPage, _ b: WikiPage) -> Bool {
        a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }

    /// The chain of node ids from a root down to `path`, so the sidebar can
    /// expand to reveal a page opened from a link or the quick switcher.
    ///
    /// Empty for a page the tree does not contain — a reference has no row to
    /// reveal, and its context comes from the "Cited by" section instead.
    static func ancestors(of path: String, excluding kinds: Set<PageKind> = []) -> [String] {
        let directory = (path as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { return [] }
        guard !kinds.contains(PageKind.forDirectory(directory)) else { return [] }
        return [directory]
    }
}
