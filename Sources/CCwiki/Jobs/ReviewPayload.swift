import Foundation

/// What `CCwiki.renderReview` takes (plans/corrections.md §6.3): each changed
/// file's old and new body, its line hunks in body coordinates, its
/// frontmatter as source lines, DiffGuard's flags and the links on it,
/// resolved. Pure.
///
/// JavaScript owns the blocks, as it owns all parsing: `reviewEntries`
/// parses both bodies with the reader's markdown-it and turns the hunks
/// into removed, added, context and gap entries. Swift only says where the
/// changes are, so the two sides meet in this JSON and nowhere else.
///
/// Coordinates:
/// - `hunks` and a flag's `lines` are 0-based and half-open, in the body:
///   the text after each side's own frontmatter. The two sides' frontmatter
///   can differ in length, so each side is shifted by its own.
/// - `bodyLine` is the 1-based file line of body line 0, for labels.
/// - A flag on no body line (on the frontmatter, or on the file as a whole)
///   has `lines: []`: it belongs to the file, not to an entry.
///
/// A file that is not Markdown (`relations.json`) or is binary is one line
/// in the review, its path and summary, and "Shown in Source": its texts are
/// sent empty, so 11,432 lines of JSON never cross the bridge twice.
enum ReviewPayload {

    /// §6.3's JSON. `title` names the page at a repository-relative path,
    /// or nil for the file name; `header` is the endpoints line of a
    /// reduction or barrier page, or ""; `links` resolves the links in the
    /// file's old and new texts and in its header.
    static func json(
        snapshot: ReviewSnapshot, findings: [DiffFinding],
        title: (String) -> String?, header: (ChangedFile) -> String,
        links: (ChangedFile) -> [String: RenderRequest.ResolvedLink],
        macros: [String: String]
    ) -> String {
        var files: [[String: Any]] = []
        for (offset, file) in snapshot.files.enumerated() {
            files.append(object(
                for: file, id: "f\(offset)",
                findings: findings.filter { $0.path == file.path },
                title: title(file.path) ?? (file.path as NSString).lastPathComponent,
                header: header(file), links: links(file)))
        }
        let payload: [String: Any] = ["macros": macros, "files": files]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return #"{"macros":{},"files":[]}"# }
        return json
    }

    // MARK: One file

    private static func object(
        for file: ChangedFile, id: String, findings: [DiffFinding], title: String,
        header: String, links: [String: RenderRequest.ResolvedLink]
    ) -> [String: Any] {
        let isMarkdown = file.isMarkdown && !file.isBinary
        let layout = FileLayout(file)

        let frontmatter: [[String: String]] = layout.frontmatterEntries.map {
            ["kind": $0.kind, "text": $0.text]
        }
        let bodyLine: [String: Int] = [
            "old": layout.oldFrontmatter + 1, "new": layout.newFrontmatter + 1,
        ]
        let hunks: [[String: [Int]]] = layout.bodyHunks.map { hunk in
            ["old": [hunk.old.lowerBound, hunk.old.upperBound],
             "new": [hunk.new.lowerBound, hunk.new.upperBound]]
        }
        let deleted = file.status == .deleted
        let flags: [[String: Any]] = findings.map { finding in
            let range = layout.bodyLines(of: finding, deleted: deleted)
            let lines: [Int] = range.map { [$0.lowerBound, $0.upperBound] } ?? []
            let flag: [String: Any] = [
                "lines": lines,
                "severity": severity(finding.severity),
                "text": finding.message,
            ]
            return flag
        }
        let linkMap: [String: Any] = isMarkdown ? linkObject(links) : [:]

        return [
            "id": id,
            "path": file.path,
            "title": title,
            "status": file.status.rawValue,
            "summary": summary(for: file),
            "isMarkdown": isMarkdown,
            "header": isMarkdown ? header : "",
            "frontmatter": frontmatter,
            "old": isMarkdown ? layout.oldBody : "",
            "new": isMarkdown ? layout.newBody : "",
            "bodyLine": bodyLine,
            "hunks": hunks,
            "flags": flags,
            "links": linkMap,
        ]
    }

    private static func severity(_ severity: DiffFinding.Severity) -> String {
        switch severity {
        case .note: "note"
        case .warning: "warning"
        case .blocking: "blocking"
        }
    }

    /// The links as `RenderRequest.jsonPayload()` writes them, so
    /// `ccwiki.js` reads both maps the same way.
    private static func linkObject(_ links: [String: RenderRequest.ResolvedLink]) -> [String: Any] {
        var object: [String: Any] = [:]
        for (raw, link) in links {
            object[raw] = [
                "href": link.href,
                "kind": link.kind,
                "external": link.external,
                "isImage": link.isImage,
            ]
        }
        return object
    }

    // MARK: Summary

    /// The line under a file's title: "1 line changed", "New page, 24
    /// lines", "Renamed from X.md"; "+12 −3" for a file the review shows
    /// only in Source, beside its path.
    static func summary(for file: ChangedFile) -> String {
        let added = file.addedLines
        let removed = file.removedLines
        if file.isBinary {
            switch file.status {
            case .added: return "Binary file, new"
            case .deleted: return "Binary file, deleted"
            case .modified, .renamed: return "Binary file, changed"
            }
        }
        guard file.isMarkdown else {
            return "+\(added) \u{2212}\(removed)"
        }
        let noun = contentPath(file.path) == nil ? "file" : "page"
        switch file.status {
        case .added:
            return "New \(noun), \(lineCount(added))"
        case .deleted:
            return "Deleted, \(lineCount(removed))"
        case .renamed:
            var from = "Renamed"
            if let oldPath = file.oldPath {
                from += " from \((oldPath as NSString).lastPathComponent)"
            }
            guard let changes = changeCounts(added: added, removed: removed) else { return from }
            return "\(from), \(changes)"
        case .modified:
            return changeCounts(added: added, removed: removed) ?? "No lines changed"
        }
    }

    /// "1 line changed", "2 lines changed, 1 added", "3 lines removed";
    /// nil when no line changed. A removed and an added line count as one
    /// changed line, as a reader sees an edit.
    private static func changeCounts(added: Int, removed: Int) -> String? {
        let changed = min(added, removed)
        let more = added - changed
        let fewer = removed - changed
        var parts: [String] = []
        if changed > 0 { parts.append("\(lineCount(changed)) changed") }
        if more > 0 { parts.append(parts.isEmpty ? "\(lineCount(more)) added" : "\(more) added") }
        if fewer > 0 { parts.append(parts.isEmpty ? "\(lineCount(fewer)) removed" : "\(fewer) removed") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func lineCount(_ count: Int) -> String {
        count == 1 ? "1 line" : "\(count) lines"
    }

    // MARK: The endpoints line

    /// The header of a reduction or barrier page (§6.3): its hypotheses and
    /// its conclusion, each a link to its page through
    /// `RelationLabels.destination`, read from the new text (the old one
    /// for a deletion). "" for every other file.
    static func header(for file: ChangedFile, labels: RelationLabels) -> String {
        guard file.isMarkdown, !file.isBinary,
              let text = file.status == .deleted ? file.oldText : file.newText
        else { return "" }
        let frontmatter = Frontmatter.parse(text)
        guard let type = frontmatter.string("type"), type == "reduction" || type == "barrier"
        else { return "" }

        var parts: [String] = []
        let hypotheses = frontmatter.list("hypotheses")
        if !hypotheses.isEmpty {
            let label = hypotheses.count == 1 ? "Hypothesis: " : "Hypotheses: "
            parts.append(label + hypotheses.map { endpoint($0, labels: labels) }
                .joined(separator: ", "))
        }
        if let conclusion = frontmatter.string("conclusion") {
            parts.append("Conclusion: " + endpoint(conclusion, labels: labels))
        }
        return parts.joined(separator: RelationMeta.separator)
    }

    /// An object id as a link to its page, titled by its label; its label
    /// alone when the manifest has no page for it.
    private static func endpoint(_ id: String, labels: RelationLabels) -> String {
        let label = labels.label(id)
        guard let destination = labels.destination(id) else {
            return RelationMeta.escapeOutsideMath(label)
        }
        // The page's path less `.md` resolves as the slug does.
        let target = destination.path.hasSuffix(".md")
            ? String(destination.path.dropLast(3)) : destination.path
        let anchored = target + (destination.anchor.map { "#" + $0 } ?? "")
        // As RelationMeta links: a label with math is a markdown link, whose
        // text is inline content, so the math renders; a wikilink's alias
        // cannot hold `|`, `[` or `]`.
        if label.contains("$") {
            return "[\(RelationMeta.escapeOutsideMath(label))](<\(anchored)>)"
        }
        let text = String(label.map { "|[]".contains($0) ? " " : $0 })
            .trimmingCharacters(in: .whitespaces)
        return "[[\(anchored)|\(text)]]"
    }

    // MARK: Links

    /// The links on `file`, resolved over its old and new texts and its
    /// `header` together, against `index`: the reader's index overlaid with
    /// the pages the change adds (`WikiIndex.overlaying`). A link to one of
    /// `newPages` (content-relative) gets the kind `new` (§6.3).
    ///
    /// Resolution is `PageRenderer`'s own, so a link in the review reads
    /// exactly as it does on the page.
    static func links(
        for file: ChangedFile, header: String, index: WikiIndex, newPages: Set<String>
    ) -> [String: RenderRequest.ResolvedLink] {
        guard file.isMarkdown, !file.isBinary else { return [:] }
        let path = contentPath(file.path) ?? file.path
        var renderer = PageRenderer(index: index)
        renderer.reportsBrokenLinks = false
        renderer.buildsPreviews = false
        var links: [String: RenderRequest.ResolvedLink] = [:]
        let texts = [file.oldText, file.newText, header].compactMap { $0 }
        for text in texts where !text.isEmpty {
            let request = renderer.request(for: WikiPage(path: path, text: text))
            links.merge(request.links) { current, _ in current }
        }
        return markingNew(links, newPages: newPages)
    }

    /// `links`, with every link to one of `newPages` (content-relative) of
    /// the kind `new`: styled as a link, "Added by this change", and not
    /// clickable, since the page is not in the reader yet. Shared with the
    /// editor's preview.
    static func markingNew(
        _ links: [String: RenderRequest.ResolvedLink], newPages: Set<String>
    ) -> [String: RenderRequest.ResolvedLink] {
        guard !newPages.isEmpty else { return links }
        let hrefs = Set(newPages.map { CCwikiURL.page(path: $0) })
        return links.mapValues { link in
            // A page's path is percent-encoded whole, `#` included, so the
            // first `#` starts the anchor.
            guard link.kind == "page", hrefs.contains(String(link.href.prefix { $0 != "#" }))
            else { return link }
            return RenderRequest.ResolvedLink(
                href: link.href, kind: "new", external: false, isImage: false)
        }
    }

    // MARK: Pages the change adds

    /// The pages `snapshot` adds to the site, as the index would load them
    /// (content-relative paths): new Markdown files under `content/`, and a
    /// renamed file's new path, outside the folders the site ignores.
    static func addedPages(in snapshot: ReviewSnapshot) -> [WikiPage] {
        snapshot.files.compactMap { file -> WikiPage? in
            guard file.status == .added || file.status == .renamed,
                  file.isMarkdown, !file.isBinary, let text = file.newText,
                  let path = contentPath(file.path), isSitePath(path)
            else { return nil }
            return WikiPage(path: path, text: text)
        }
    }

    /// Which of `added` the reader does not have yet: a link to one of
    /// these is of the kind `new`.
    static func newPagePaths(_ added: [WikiPage], in index: WikiIndex?) -> Set<String> {
        Set(added.map(\.path).filter { index?.pages[$0] == nil })
    }

    /// The page title for a changed Markdown file, from its new text (its
    /// old one for a deletion): the title a reader would see.
    static func pageTitle(for file: ChangedFile) -> String? {
        guard file.isMarkdown, !file.isBinary,
              let text = file.status == .deleted ? file.oldText : file.newText
        else { return nil }
        return WikiPage(path: contentPath(file.path) ?? file.path, text: text).displayTitle
    }

    /// `content/Primitives/x.md` → `Primitives/x.md`; nil outside `content/`.
    static func contentPath(_ repositoryPath: String) -> String? {
        let prefix = "content/"
        guard repositoryPath.hasPrefix(prefix), repositoryPath.count > prefix.count else { return nil }
        return String(repositoryPath.dropFirst(prefix.count))
    }

    /// A path `WikiIndex.contentFiles` would list: not under a folder the
    /// site ignores, and with no hidden component.
    private static func isSitePath(_ path: String) -> Bool {
        let components = path.components(separatedBy: "/")
        guard let first = components.first, !WikiIndex.ignoredTopLevel.contains(first) else {
            return false
        }
        return !components.contains { $0.hasPrefix(".") || $0.isEmpty }
    }

    // MARK: Lines

    /// The lines of `text` as git counts them: up to and including each
    /// `"\n"`, and a final run without one. The empty text has none.
    static func lines(of text: String) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        var index = text.utf8.startIndex
        while index < text.utf8.endIndex {
            let next = text.utf8.index(after: index)
            if text.utf8[index] == UInt8(ascii: "\n") {
                // The index after a line feed is always a character boundary.
                result.append(text[start..<next])
                start = next
            }
            index = next
        }
        if start < text.endIndex { result.append(text[start...]) }
        return result
    }

    /// How many of `text`'s lines are frontmatter: every line that starts
    /// before `Frontmatter.parse(text).bodyStart`, both fences included.
    /// 0 for a page without frontmatter.
    static func frontmatterLineCount(_ text: String) -> Int {
        let bodyStart = Frontmatter.parse(text).bodyStart
        guard bodyStart > text.startIndex else { return 0 }
        let newlines = text[..<bodyStart].utf8.count { $0 == UInt8(ascii: "\n") }
        // A closing fence on the last line, with no newline after it, is
        // still a line of the frontmatter.
        let endsWithNewline = text.utf8.last == UInt8(ascii: "\n")
        return bodyStart == text.endIndex && !endsWithNewline ? newlines + 1 : newlines
    }

    /// `hunks`, 0-based in each whole file, split at each side's
    /// frontmatter: the part before it, in file lines, and the part after
    /// it, in body lines.
    ///
    /// The split is exact when the end of the frontmatter falls at the same
    /// place on both sides of the diff, which is every change that leaves
    /// the fences alone. When it does not (a fence added or removed), the
    /// lines on either side of it no longer pair up, and the whole of each
    /// part is shown as changed rather than mispaired.
    static func split(
        _ hunks: [LineHunk], oldFrontmatter: Int, newFrontmatter: Int,
        oldLineCount: Int, newLineCount: Int
    ) -> (frontmatter: [LineHunk], body: [LineHunk]) {
        let fo = oldFrontmatter
        let fn = newFrontmatter
        guard boundaryAligns(
            hunks, old: fo, new: fn, oldLineCount: oldLineCount, newLineCount: newLineCount)
        else {
            let frontmatter = fo > 0 || fn > 0 ? [LineHunk(old: 0..<fo, new: 0..<fn)] : []
            let oldBody = max(oldLineCount - fo, 0)
            let newBody = max(newLineCount - fn, 0)
            let body = oldBody > 0 || newBody > 0
                ? [LineHunk(old: 0..<oldBody, new: 0..<newBody)] : []
            return (frontmatter, body)
        }

        var frontmatter: [LineHunk] = []
        var body: [LineHunk] = []
        for hunk in hunks {
            let head = LineHunk(
                old: min(hunk.old.lowerBound, fo)..<min(hunk.old.upperBound, fo),
                new: min(hunk.new.lowerBound, fn)..<min(hunk.new.upperBound, fn))
            if !head.old.isEmpty || !head.new.isEmpty { frontmatter.append(head) }
            let tail = LineHunk(
                old: (max(hunk.old.lowerBound, fo) - fo)..<(max(hunk.old.upperBound, fo) - fo),
                new: (max(hunk.new.lowerBound, fn) - fn)..<(max(hunk.new.upperBound, fn) - fn))
            if !tail.old.isEmpty || !tail.new.isEmpty { body.append(tail) }
        }
        return (frontmatter, body)
    }

    /// Whether old line `old` and new line `new` are one place in the
    /// diff's alignment: in a run of unchanged lines, at the same distance
    /// from its start on both sides; or inside one hunk on both sides,
    /// where every line is changed anyway.
    private static func boundaryAligns(
        _ hunks: [LineHunk], old: Int, new: Int, oldLineCount: Int, newLineCount: Int
    ) -> Bool {
        var oldStart = 0
        var newStart = 0
        for hunk in hunks {
            if oldStart <= old, old <= hunk.old.lowerBound, new - newStart == old - oldStart {
                return true
            }
            if hunk.old.lowerBound <= old, old <= hunk.old.upperBound,
               hunk.new.lowerBound <= new, new <= hunk.new.upperBound {
                return true
            }
            oldStart = hunk.old.upperBound
            newStart = hunk.new.upperBound
        }
        return oldStart <= old && old <= oldLineCount && new - newStart == old - oldStart
    }

    /// One file, cut into frontmatter and body on each side.
    private struct FileLayout {
        let oldFrontmatter: Int
        let newFrontmatter: Int
        let oldBody: String
        let newBody: String
        let bodyHunks: [LineHunk]
        let frontmatterEntries: [(kind: String, text: String)]

        init(_ file: ChangedFile) {
            let oldText = file.oldText ?? ""
            let newText = file.newText ?? ""
            guard file.isMarkdown, !file.isBinary else {
                oldFrontmatter = 0
                newFrontmatter = 0
                oldBody = oldText
                newBody = newText
                bodyHunks = file.hunks
                frontmatterEntries = []
                return
            }
            let oldLines = ReviewPayload.lines(of: oldText)
            let newLines = ReviewPayload.lines(of: newText)
            let fo = ReviewPayload.frontmatterLineCount(oldText)
            let fn = ReviewPayload.frontmatterLineCount(newText)
            oldFrontmatter = fo
            newFrontmatter = fn
            oldBody = oldLines.dropFirst(fo).joined()
            newBody = newLines.dropFirst(fn).joined()
            let parts = ReviewPayload.split(
                file.hunks, oldFrontmatter: fo, newFrontmatter: fn,
                oldLineCount: oldLines.count, newLineCount: newLines.count)
            bodyHunks = parts.body
            frontmatterEntries = ReviewPayload.frontmatterEntries(
                parts.frontmatter, old: Array(oldLines.prefix(fo)), new: Array(newLines.prefix(fn)))
        }

        /// A finding's lines in this file's body: 0-based, half-open. Nil
        /// when it names no body line.
        func bodyLines(of finding: DiffFinding, deleted: Bool) -> Range<Int>? {
            guard let lines = finding.lines else { return nil }
            let offset = deleted ? oldFrontmatter : newFrontmatter
            let start = max(lines.first - 1, offset) - offset
            let end = max(lines.last, offset) - offset
            return start < end ? start..<end : nil
        }
    }

    /// The frontmatter as source lines (§6.3): each change's removed and
    /// added lines, one unchanged line of context either side, and a `gap`
    /// for each run of unchanged lines left out. A run of one is shown
    /// rather than left out, since its gap would take the same room.
    static func frontmatterEntries(
        _ hunks: [LineHunk], old: [Substring], new: [Substring]
    ) -> [(kind: String, text: String)] {
        guard !hunks.isEmpty else { return [] }
        let context = 1
        var entries: [(kind: String, text: String)] = []
        // A line without its break. By scalar: `"\r\n"` is one Character.
        func line(_ text: Substring) -> String {
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: text.unicodeScalars)
            if scalars.last == "\n" { scalars.removeLast() }
            if scalars.last == "\r" { scalars.removeLast() }
            return String(scalars)
        }
        // The unchanged lines `range` of the new side, left out.
        func skip(_ range: Range<Int>) {
            if range.count == 1, range.lowerBound < new.count {
                entries.append(("context", line(new[range.lowerBound])))
            } else if range.count > 1 {
                entries.append(("gap", "\(range.count) unchanged lines"))
            }
        }

        // Unchanged lines are the same on both sides; they are read from
        // the new one, whose positions the hunks' `new` ranges give.
        var shown = 0
        for (offset, hunk) in hunks.enumerated() {
            // Hunks are in order and apart; `min` keeps a range valid if not.
            let leading = min(max(hunk.new.lowerBound - context, shown), hunk.new.lowerBound)
            skip(shown..<max(leading, shown))
            for index in leading..<hunk.new.lowerBound where index < new.count {
                entries.append(("context", line(new[index])))
            }
            for index in hunk.old where index < old.count {
                entries.append(("removed", line(old[index])))
            }
            for index in hunk.new where index < new.count {
                entries.append(("added", line(new[index])))
            }
            let next = offset + 1 < hunks.count ? hunks[offset + 1].new.lowerBound : new.count
            let trailing = min(hunk.new.upperBound + context, next, new.count)
            for index in hunk.new.upperBound..<max(trailing, hunk.new.upperBound) {
                entries.append(("context", line(new[index])))
            }
            shown = max(trailing, hunk.new.upperBound)
        }
        skip(shown..<max(new.count, shown))
        return entries
    }
}
