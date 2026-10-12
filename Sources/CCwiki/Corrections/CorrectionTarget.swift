import Foundation

// What a correction is about: the page, the section, the source lines and
// the passage as the reader showed it (plans/corrections.md §3.5), and the
// small types the three routes share (§11.6).

/// Lines of a file: 1-based, inclusive.
struct LineRange: Codable, Sendable, Hashable {
    let first: Int
    let last: Int

    var count: Int { last - first + 1 }

    /// "line 42", "lines 42–44".
    var label: String {
        first == last ? "line \(first)" : "lines \(first)–\(last)"
    }

    func overlaps(_ other: LineRange) -> Bool {
        first <= other.last && other.first <= last
    }
}

/// The page and passage a correction starts from.
struct CorrectionTarget: Codable, Sendable, Hashable {

    struct Section: Codable, Sendable, Hashable {
        let id: String
        let title: String
        let level: Int
    }

    /// What the lines are: the page's own text, the relation-meta line the
    /// renderer builds from the frontmatter, or a region generated from the
    /// reduction pages (§3.5). Route b refuses the last two (§8.1).
    enum Region: String, Codable, Sendable {
        case body, frontmatter, generated
    }

    /// Relative to `content/`.
    let pagePath: String
    let pageTitle: String
    /// The commit the reader rendered: the selection's revision, else the
    /// web view's `lastRenderedRevision`. Never `origin/main` (§3.5).
    let baseCommit: String
    var section: Section?
    /// Nil: the whole page.
    var lines: LineRange?
    var region: Region
    /// As the reader showed it, formulas as `$…$`, at most `quoteLimit`.
    var quote: String?
    /// The file's `lines`, verbatim.
    var excerpt: String?

    var repositoryPath: String { "content/" + pagePath }

    /// "Lines 42–44, in “Security”", "The whole page".
    var summary: String {
        guard let lines else { return "The whole page" }
        let label = lines.label
        let range: String = label.prefix(1).uppercased() + label.dropFirst()
        guard let section else { return range }
        return "\(range), in “\(section.title)”"
    }

    static let quoteLimit = 2_000

    /// The target for what the reader showed: the selection's lines when
    /// it is a passage, the whole page otherwise. Pure. `readingHeading` is
    /// the heading at the top of the viewport, used when there is no
    /// selection and no pointer.
    ///
    /// `fileText` and `renderedMarkdown` must be the ones that were shown:
    /// the file at `baseCommit`, and the markdown the reader last rendered
    /// from it. The lines a selection reports are lines of that markdown.
    ///
    /// A pointer, a right-click with nothing selected, names a block, not a
    /// passage: the target is the whole page, in the pointer's section, so
    /// the editor opens there. A passage whose lines cannot be mapped keeps
    /// its quote, for the whole page. A passage's lines leave out the blank
    /// lines markdown-it counts into a list's last item.
    static func make(
        page: WikiPage, fileText: String, renderedMarkdown: String,
        baseCommit: String, selection: ReaderSelection?,
        readingHeading: Section?
    ) -> CorrectionTarget {
        var target = CorrectionTarget(
            pagePath: page.path, pageTitle: page.displayTitle, baseCommit: baseCommit,
            section: selection?.heading ?? readingHeading, lines: nil, region: .body,
            quote: nil, excerpt: nil)
        guard let selection, let text = selection.text else { return target }

        target.quote = Self.quoted(text)
        let map = SourceLineMap(fileText: fileText, renderedMarkdown: renderedMarkdown)
        switch map.location(ofRendered: selection.renderedLines) {
        case .body(let mapped):
            let lines = Self.trimmingBlankLines(mapped, in: fileText)
            target.lines = lines
            target.region = GeneratedRegions(fileText).overlap(lines) ? .generated : .body
            target.excerpt = Self.text(of: lines, in: fileText)
        case .frontmatter(let lines):
            target.lines = lines
            target.region = .frontmatter
            target.excerpt = Self.text(of: lines, in: fileText)
        case nil:
            break
        }
        return target
    }

    /// Where the editor opens for what was shown (§3.3, §3.5): a passage's
    /// lines, or the block a right-click pointed at, though a pointer's
    /// target is the whole page; else the heading of `section`, the one the
    /// reader is on. Nil when none of them is in the file.
    static func editorLines(
        fileText: String, renderedMarkdown: String, selection: ReaderSelection?,
        section: Section?
    ) -> LineRange? {
        if let selection {
            let map = SourceLineMap(fileText: fileText, renderedMarkdown: renderedMarkdown)
            switch map.location(ofRendered: selection.renderedLines) {
            case .body(let lines): return trimmingBlankLines(lines, in: fileText)
            case .frontmatter(let lines): return lines
            case nil: break
            }
        }
        return section.flatMap { headingLine(of: $0, in: fileText) }
    }

    /// The line of the heading whose id is `section.id`, as the outline
    /// gives ids: GithubSlugger over each ATX heading's plain text, counting
    /// repeats, outside fenced code (`WikiPage.headings()`). Nil when no
    /// heading has it.
    static func headingLine(of section: Section, in fileText: String) -> LineRange? {
        let bodyStart = Frontmatter.parse(fileText).bodyStart
        let body = String(fileText[bodyStart...])
        let bodyOffset = SourceLineMap.lines(of: fileText[..<bodyStart]).count - 1
        let inert = CodeMask.inertRanges(in: body)
        var slugger = GithubSlugger()
        for (index, line) in SourceLineMap.lines(of: Substring(body)).enumerated() {
            guard let heading = WikiPage.atxHeading(line),
                  !inert.contains(where: { $0.contains(line.startIndex) })
            else { continue }
            let text = WikiPage.Heading.plainText(heading.text)
            guard !text.isEmpty else { continue }
            if slugger.slug(text) == section.id {
                let number = bodyOffset + index + 1
                return LineRange(first: number, last: number)
            }
        }
        return nil
    }

    /// `lines` without the blank lines at either end, which markdown-it
    /// counts into a list and its last item; the first line alone when
    /// every one is blank.
    static func trimmingBlankLines(_ lines: LineRange, in fileText: String) -> LineRange {
        let all = SourceLineMap.lines(of: Substring(fileText))
        func isBlank(_ number: Int) -> Bool {
            guard number >= 1, number <= all.count else { return true }
            return all[number - 1].allSatisfy(\.isWhitespace)
        }
        var first = lines.first
        var last = lines.last
        while last > first, isBlank(last) { last -= 1 }
        while first < last, isBlank(first) { first += 1 }
        return LineRange(first: first, last: last)
    }

    /// The target when the file the reader showed cannot be read: a
    /// snapshot whose marker has moved since the render, or a revision git
    /// cannot show. The whole page at `head`, in the section the selection
    /// or the reader was in; nothing selected is carried over (§3.5).
    static func fallback(
        page: WikiPage, head: String, selection: ReaderSelection?, readingHeading: Section?
    ) -> CorrectionTarget {
        CorrectionTarget(
            pagePath: page.path, pageTitle: page.displayTitle, baseCommit: head,
            section: selection?.heading ?? readingHeading, lines: nil, region: .body,
            quote: nil, excerpt: nil)
    }

    /// What the sheet says when `fallback` stood in for a passage.
    static let fallbackNotice =
        "The page changed since it was shown; the selection was not carried over."

    /// Whether the file on disk is the one the reader showed at `revision`:
    /// the copy, a snapshot or a clone, is still at it. A render with no
    /// revision (a copy that has none) was of the disk.
    static func diskShows(revision: String?, current: String?) -> Bool {
        revision == nil || revision == current
    }

    /// Where the file the reader showed is read from (§3.5).
    enum ShownFile: Sendable, Equatable {
        /// `git show <revision>:content/<path>`, in the clone.
        case blob
        /// The file on disk: the copy is still at the revision shown.
        case disk
        /// Neither: the copy has moved on since the render. The target is
        /// `fallback`.
        case unavailable
    }

    /// Pure. A clone shows the file at the revision whenever git has it, at
    /// any age; else the disk, while HEAD is still that revision. A snapshot
    /// has no history: the disk, while its marker is still at the revision.
    /// `blobAvailable` says whether `git show` gave the file.
    static func shownFile(
        store: AppPaths.WikiStore, revision: String?, head: String?, marker: String?,
        blobAvailable: Bool
    ) -> ShownFile {
        switch store {
        case .git:
            if revision != nil, blobAvailable { return .blob }
            return diskShows(revision: revision, current: head) ? .disk : .unavailable
        case .snapshot:
            return diskShows(revision: revision, current: marker) ? .disk : .unavailable
        case .none:
            return .unavailable
        }
    }

    /// Whether `selection` was made on a render the web view has since
    /// replaced, at another revision: its lines are lines of a markdown it
    /// no longer keeps, and cannot be mapped (§3.5).
    static func outlived(_ selection: ReaderSelection?, renderedRevision: String?) -> Bool {
        guard let revision = selection?.revision else { return false }
        return revision != renderedRevision
    }

    /// The passage as the reader showed it, trimmed, and at most
    /// `quoteLimit` characters.
    static func quoted(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(quoteLimit))
    }

    /// The file's `lines`, verbatim, without their final line break. Nil
    /// when the file has none of them.
    static func text(of lines: LineRange, in fileText: String) -> String? {
        let all = SourceLineMap.lines(of: Substring(fileText))
        let first = max(lines.first, 1) - 1
        let last = min(lines.last, all.count) - 1
        guard first <= last else { return nil }
        return all[first...last].joined(separator: "\n")
    }
}

extension CorrectionTarget {

    /// The regions a page's "Participates in" section is generated into, from
    /// the reduction pages, by the wiki's own script: 1-based file lines, the
    /// markers included. A correction must not edit one by hand (§3.5).
    ///
    /// Nested, so that its name stays out of the module's scope: DiffGuard has
    /// a file-private type of the same name.
    struct GeneratedRegions: Sendable, Equatable {
        static let begin = "<!-- BEGIN GENERATED participates-in"
        static let end = "<!-- END GENERATED participates-in"

        let regions: [LineRange]

        init(_ fileText: String) {
            var regions: [LineRange] = []
            var open: Int?
            for (index, line) in SourceLineMap.lines(of: Substring(fileText)).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(Self.begin) {
                    open = index + 1
                } else if trimmed.hasPrefix(Self.end), let first = open {
                    regions.append(LineRange(first: first, last: index + 1))
                    open = nil
                }
            }
            self.regions = regions
        }

        /// Whether any of `lines` is inside a region.
        func overlap(_ lines: LineRange) -> Bool {
            regions.contains { $0.overlaps(lines) }
        }
    }
}

/// What `ccwiki.js` reports about the selection, or about the block under
/// the pointer at a right-click (§3.3). Decoding is pure and tested.
struct ReaderSelection: Sendable, Equatable {
    /// 0-based, half-open, in the `RenderRequest`'s markdown.
    let renderedLines: Range<Int>
    /// Nil: a right-click with nothing selected, which names a block, not a
    /// passage.
    let text: String?
    let heading: CorrectionTarget.Section?
    let path: String
    /// The `RenderRequest.revision` the selection was made on.
    let revision: String?

    var isPassage: Bool { text != nil }

    init(
        renderedLines: Range<Int>, text: String?, heading: CorrectionTarget.Section?,
        path: String, revision: String?
    ) {
        self.renderedLines = renderedLines
        self.text = text
        self.heading = heading
        self.path = path
        self.revision = revision
    }

    /// `CCwiki.selectionSource()`: nil for "null" or anything malformed.
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
              let message = object as? [String: Any]
        else { return nil }
        self.init(message: message)
    }

    /// The `contextTarget` message's `selection`, which `ccwiki.js` writes
    /// as `{start, end, text, heading: {id, text, level}, path, revision}`.
    /// `NSNull`, as a JavaScript `null` arrives, reads as absent: a null
    /// `text` is a pointer, a null `heading` no section. Nil without a page
    /// or a range of at least one line.
    init?(message: [String: Any]) {
        guard let start = Self.integer(message["start"]),
              let end = Self.integer(message["end"]),
              start >= 0, end > start,
              let path = message["path"] as? String, !path.isEmpty
        else { return nil }
        let text = (message["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let heading = (message["heading"] as? [String: Any]).flatMap(Self.section(from:))
        let revision = (message["revision"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.init(
            renderedLines: start..<end, text: text, heading: heading, path: path,
            revision: revision)
    }

    /// A whole number from a bridge message or parsed JSON, where every
    /// number is an `NSNumber`: the cast to `Int` is exact, so a fraction,
    /// a string or `NSNull` is nil.
    private static func integer(_ value: Any?) -> Int? {
        value as? Int
    }

    /// `{id, text, level}`, as the outline reports a heading.
    private static func section(from heading: [String: Any]) -> CorrectionTarget.Section? {
        guard let id = heading["id"] as? String, !id.isEmpty,
              let level = integer(heading["level"]), (1...6).contains(level)
        else { return nil }
        let title = (heading["text"] as? String) ?? ""
        return CorrectionTarget.Section(id: id, title: title, level: level)
    }
}

/// Route b: what a reader asks the agent to correct (§4.1).
struct CorrectionRequest: Codable, Sendable, Equatable {
    let target: CorrectionTarget
    /// What the reader says is wrong.
    let description: String
    /// The `--model` alias used; "" for the claude CLI's default.
    let model: String
}

/// The three ways to correct a page (§0).
enum CorrectionRoute: String, Sendable, CaseIterable {
    /// a. Edit it yourself.
    case edit
    /// b. Describe it, and an agent edits.
    case describe
    /// c. Open an issue.
    case issue
}

/// An issue as the sheet holds it (§8.2).
struct IssueDraft: Sendable, Equatable {
    let target: CorrectionTarget
    /// A UUID, one per sheet: "ccwiki-issue: <marker>" in the body's
    /// hidden footer, which a retry searches for.
    let marker: String
    var title: String
    /// Exactly as typed; the footer is added when sending.
    var body: String
}

/// A sheet on the reader window: Describe a Correction or Open an Issue
/// (§8). `ReaderSession.correctionSheet` holds it.
struct CorrectionSheetRequest: Identifiable, Sendable {
    enum Kind: Sendable {
        case describe, issue
    }

    let id: UUID
    let kind: Kind
    let target: CorrectionTarget
    /// A line the sheet shows above its fields: why the target is not what
    /// was selected (§3.5).
    var notice: String? = nil
}

extension CorrectionSheetRequest {
    /// A new request, with an identity of its own.
    init(_ kind: Kind, target: CorrectionTarget, notice: String? = nil) {
        self.init(id: UUID(), kind: kind, target: target, notice: notice)
    }
}

/// An editor window's identity: one file of one job, as a document is
/// (§7.2). Its scene restores it.
struct EditorTarget: Codable, Hashable, Sendable {
    let jobID: String
    /// Repository-relative: "content/Primitives/pseudorandom-function.md".
    let path: String
}

/// Why a route cannot start here, in the order the sheet lists them.
enum CorrectionBlockers {

    /// A copy fetched as a tarball, because git was missing (§3.6). Editing
    /// and an agent both need a worktree, which needs a clone.
    static let snapshot = "This copy of the wiki is a snapshot. Sync (⌘R) to replace it "
        + "with a git clone."
    static let notDownloaded = "The wiki has not been downloaded yet. Sync (⌘R) first."
    static let gitMissing = "git was not found. Editing needs Apple's Command Line Tools; "
        + "Settings > Jobs has the installer."
    static let claudeMissing = "claude was not found. It drafts the edit; install the claude CLI, "
        + "or edit the page yourself."
    static let ghMissing = "gh was not found. It opens the issue; install it with Homebrew "
        + "(brew install gh)."
    /// Route b on a generated passage (§8.1): the agent cannot run the
    /// script that writes it.
    static let generated = "This passage is generated from the reduction pages. Open an issue, "
        + "or edit the reduction page it links to."
    /// Route b on the relation line under a reduction or barrier page's
    /// title (§8.1): it is built from the page's own frontmatter, and its
    /// links go to classes, models and references, never to a reduction.
    static let frontmatterLine = "This line is built from this page's own frontmatter, which an "
        + "agent cannot change here. Open an issue, or edit those fields yourself with Edit Page."

    /// Pure. Local conditions only; GitHub is `GitHubAccess`'s, and is never
    /// listed here: editing needs no network, and the reader is built to
    /// work offline.
    static func list(
        route: CorrectionRoute, region: CorrectionTarget.Region,
        gitPresent: Bool, claudePresent: Bool, ghPresent: Bool,
        store: AppPaths.WikiStore
    ) -> [String] {
        var blockers: [String] = []
        switch route {
        case .edit, .describe:
            if !gitPresent { blockers.append(gitMissing) }
            switch store {
            case .git: break
            case .snapshot: blockers.append(snapshot)
            case .none: blockers.append(notDownloaded)
            }
            if route == .describe {
                if !claudePresent { blockers.append(claudeMissing) }
                switch region {
                case .body: break
                case .generated: blockers.append(generated)
                case .frontmatter: blockers.append(frontmatterLine)
                }
            }
        case .issue:
            // A snapshot's marker names its commit, which the permalink
            // uses: an issue needs only gh.
            if !ghPresent { blockers.append(ghMissing) }
        }
        return blockers
    }
}
