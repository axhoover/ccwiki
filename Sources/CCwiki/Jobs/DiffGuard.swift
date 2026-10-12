import CryptoKit
import Foundation

/// One thing DiffGuard noticed in a snapshot (plans/corrections.md §6.2).
struct DiffFinding: Sendable, Equatable, Identifiable {

    enum Severity: Int, Sendable, Comparable {
        /// Informs.
        case note
        /// Needs a confirmation before Open Draft PR.
        case warning
        /// Open Draft PR stays disabled.
        case blocking

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    enum Rule: String, Sendable, CaseIterable {
        case outsideContent, renamedOrDeleted, binaryFile, generatedRegionEdited,
             relationFieldOnObjectPage, wikilinkMath, privateText,
             newObjectPage, otherPages, largeEdit, ingestionScope, proseRelationBullet,
             derivedFilesStale, relationsJSONByHand, humanVerified, statusComplete,
             changedUpstream, rawHTML, regionRegenerated
    }

    let rule: Rule
    let severity: Severity
    let path: String
    /// In the new text; in the old text for a deletion.
    let lines: LineRange?
    /// Shown as is.
    let message: String

    var id: String { "\(rule.rawValue):\(path):\(lines?.first ?? 0)" }
}

/// What may leave the machine, checked against the wiki's own rules
/// (plans/corrections.md §6.2). Pure.
///
/// Nineteen rules in three severities. **Blocking** is what the wiki forbids
/// outright: Open Draft PR stays disabled. **Warnings** need a person's
/// judgement and a confirmation. **Notes** inform.
///
/// Three rules copy the wiki's `scripts/lint.mjs`, because routes a and b
/// never run it (there is no `node` in their worktrees). Their messages end
/// with the lint's rule id, and each cites the lines it follows, at the
/// wiki's `ab81f02`:
///
/// - `generatedRegionEdited`, the lint's `generated-region` and
///   `generated-region-edited`: lint.mjs 1075–1109;
/// - `relationFieldOnObjectPage`, its `object-relation-field`: lint.mjs
///   95–104 (`TYPES`), 159–171 (`FORBIDDEN_ON_OBJECTS`) and 500–511;
/// - `wikilinkMath`, its `wikilink-math`: lint.mjs 1238–1272, scanning with
///   `dollarWikilinks`, markdown-text.mjs 183–196.
///
/// Rules about lines look only at the lines the change added, so a page
/// that already broke a rule at the base does not block a fix elsewhere on
/// it.
enum DiffGuard {

    struct Context: Sendable {
        var kind: JobKind.Tag
        /// The thresholds that apply: an edit is checked as a correction is.
        var family: JobKind.Family { kind.family }
        /// Pages `human_verified` in `.fact-check/queue.json` at the base.
        var humanVerifiedPaths: Set<String>
        /// Paths changed on `origin/<default>` since the base.
        var changedUpstream: Set<String>
        var target: CorrectionTarget?
        /// Local paths that must never appear in text (`PrivateText`).
        var privatePaths: [String]
    }

    /// The findings, blocking first, then by path and line. Each `id` is
    /// unique.
    static func check(_ snapshot: ReviewSnapshot, context: Context) -> [DiffFinding] {
        let files = snapshot.files.map { InspectedFile($0) }
        var findings: [DiffFinding] = []
        for file in files {
            findings += pathFindings(file.file, context: context)
            findings += privateTextFindings(file, privatePaths: context.privatePaths)
            if file.isPage {
                findings += regionFindings(file)
                findings += relationFieldFindings(file)
                findings += wikilinkMathFindings(file)
                findings += proseBulletFindings(file)
                findings += statusFindings(file)
                findings += rawHTMLFindings(file)
            }
        }
        findings += scopeFindings(files, context: context)
        findings += derivedFilesFindings(files)
        return ordered(findings)
    }

    /// `sha256(trimmed contents)[0..<12]`, as `lint.mjs` computes it:
    /// trimmed as JavaScript's `String.prototype.trim` trims, hashed as UTF-8.
    static func regionChecksum(_ inner: String) -> String {
        let scalars = inner.unicodeScalars
        var trimmed = String.UnicodeScalarView()
        if let first = scalars.firstIndex(where: { !isECMAScriptSpace($0) }),
           let last = scalars.lastIndex(where: { !isECMAScriptSpace($0) }) {
            trimmed.append(contentsOf: scalars[first...last])
        }
        let digest = SHA256.hash(data: Data(String(trimmed).utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// The allow-list: a `.md` file under `content/` but not
    /// `content/Templates/`, and `.reductions/relations.json`. Everything
    /// else, `scripts/`, `CLAUDE.md`, `.claude/` and a stray `lint.log`
    /// included, stays out of a CCwiki pull request.
    static func isPublishable(_ path: String) -> Bool {
        if path == relationsJSON { return true }
        return path.hasPrefix("content/") && path.hasSuffix(".md")
            && !path.lowercased().hasPrefix("content/templates/")
    }

    // MARK: - Paths and the context

    private static let relationsJSON = ".reductions/relations.json"

    private static func pathFindings(_ file: ChangedFile, context: Context) -> [DiffFinding] {
        var found: [DiffFinding] = []
        let paths = [file.path] + (file.oldPath.map { [$0] } ?? [])
        let name = (file.path as NSString).lastPathComponent

        if let outside = paths.first(where: { !isPublishable($0) }) {
            found.append(finding(.outsideContent, file.path,
                "CCwiki opens pull requests that change `content/` only. Revert `\(outside)`, "
                    + "or make this change outside CCwiki."))
        }
        if file.status == .renamed, paths.contains(where: { $0.hasPrefix("content/") }) {
            found.append(finding(.renamedOrDeleted, file.path,
                "Filenames under `content/` are live URLs. Revert the rename."))
        }
        if file.status == .deleted, file.path.hasPrefix("content/") {
            found.append(finding(.renamedOrDeleted, file.path,
                "Filenames under `content/` are live URLs. Restore the file."))
        }
        if file.status != .deleted, file.isBinary || file.path.lowercased().hasSuffix(".pdf") {
            found.append(finding(.binaryFile, file.path,
                "PDFs and other binary files never enter the wiki."))
        }

        if file.status == .added, file.isMarkdown,
           objectDirectories.contains(topDirectory(of: file.path)) {
            found.append(finding(.newObjectPage, file.path,
                "This creates an object page. The wiki asks for a human decision on new objects."))
        }
        if context.family == .correction, file.isMarkdown, file.path.hasPrefix("content/"),
           let target = context.target, !paths.contains(target.repositoryPath) {
            found.append(finding(.otherPages, file.path,
                "This also changes `\(name)`, which is not the page you started from."))
        }
        // A correction's agent cannot run the generator. An edit's or an
        // ingestion's worktree can, so for them a regenerated file is fine,
        // and its regions are notes.
        if context.kind == .correction, paths.contains(relationsJSON) {
            found.append(finding(.relationsJSONByHand, file.path,
                "`relations.json` changed. The correction agent cannot run the generator, so "
                    + "unless you ran it in this worktree, revert this file."))
        }
        if paths.contains(where: { isHumanVerified($0, context: context) }) {
            found.append(finding(.humanVerified, file.path,
                "A human verified this page. The wiki asks that a change to a claim here also "
                    + "marks its queue entry stale; CCwiki does not edit that file."))
        }
        if paths.contains(where: { context.changedUpstream.contains($0) }) {
            let noun = file.isMarkdown ? "page" : "file"
            found.append(finding(.changedUpstream, file.path,
                "This \(noun) changed on main after the job started. The pull request may conflict."))
        }
        return found
    }

    private static func isHumanVerified(_ path: String, context: Context) -> Bool {
        if context.humanVerifiedPaths.contains(path) { return true }
        guard path.hasPrefix(contentPrefix) else { return false }
        return context.humanVerifiedPaths.contains(String(path.dropFirst(contentPrefix.count)))
    }

    // MARK: - Private text

    /// Every added line of any text file: a local path or a token must never
    /// reach GitHub.
    private static func privateTextFindings(_ file: InspectedFile, privatePaths: [String]) -> [DiffFinding] {
        guard let new = file.new, !file.added.isEmpty else { return [] }
        // One pass over everything added first: almost always nothing.
        let addedText = file.added.map { new.lines[$0] }.joined(separator: "\n")
        guard !PrivateText.findings(in: addedText, privatePaths: privatePaths).isEmpty else { return [] }

        return file.added.compactMap { index -> DiffFinding? in
            let line = String(new.lines[index])
            guard let first = PrivateText.findings(in: line, privatePaths: privatePaths).first
            else { return nil }
            // A path is shown whole; a token only by its start.
            let shown = first.hasPrefix("/") ? first : String(first.prefix(8)) + "…"
            return finding(.privateText, file.file.path, line: index,
                "This line contains a local path or a token: `\(shown)`.")
        }
    }

    // MARK: - Generated regions (lint.mjs 1075–1109)

    /// Unbalanced markers and hand-edited regions block; a region the script
    /// rewrote is a note. A region already broken at the base, character for
    /// character, is not this change's doing.
    private static func regionFindings(_ file: InspectedFile) -> [DiffFinding] {
        guard let new = file.new else { return [] }
        let regions = new.regions
        let before = file.old?.regions
        let path = file.file.path

        guard regions.isBalanced else {
            if let before, before.begins == regions.begins, before.ends == regions.ends { return [] }
            let line = regions.firstMarkerLine ?? new.bodyStartLine
            let message = """
                The “Participates in” markers are unbalanced (\(regions.begins) BEGIN, \
                \(regions.ends) END). They are written by the script; restore them, and correct \
                the reduction pages instead. (lint: `generated-region`)
                """
            return [finding(.generatedRegionEdited, path, line: line, message)]
        }

        var found: [DiffFinding] = []
        for region in regions.regions {
            let existed = before?.regions.contains(where: { $0.text == region.text }) ?? false
            guard !existed else { continue }
            let lines = LineRange(first: region.lines.lowerBound + 1, last: region.lines.upperBound + 1)
            if region.isIntact {
                found.append(finding(.regionRegenerated, path, lines: lines,
                    "Regenerated by the script, not edited by hand."))
            } else {
                let message = """
                    The “Participates in” section on \(lines.label) was edited by hand. It is \
                    rebuilt from the reduction pages; correct those instead. \
                    (lint: `generated-region-edited`)
                    """
                found.append(finding(.generatedRegionEdited, path, lines: lines, message))
            }
        }
        return found
    }

    /// JavaScript's `trim()`: WhiteSpace (tab, VT, FF, ZWNBSP and every
    /// space separator) and LineTerminator (LF, CR, LS, PS).
    private static func isECMAScriptSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F,
             0x3000, 0xFEFF:
            true
        default:
            false
        }
    }

    // MARK: - Relation fields (lint.mjs 95–104, 159–171, 500–511)

    /// lint.mjs's `TYPES` with `object: true`. Root notes host object ids too.
    private static let objectTypes: Set<String> = [
        "primitive", "assumption", "complexity-class", "glossary", "folklore", "note",
    ]

    /// lint.mjs's `FORBIDDEN_ON_OBJECTS`.
    private static let forbiddenOnObjects = [
        "implies", "implied-by", "implied_by", "reductions", "barriers", "separations",
        "from", "to", "between", "hypotheses", "conclusion",
    ]

    /// A key the change adds to an object page's frontmatter. The lint
    /// decides by `type:`; a page without one is judged by its directory.
    private static func relationFieldFindings(_ file: InspectedFile) -> [DiffFinding] {
        guard let new = file.new, isObjectPage(file.file.path, frontmatter: new.frontmatter)
        else { return [] }
        return forbiddenOnObjects.compactMap { key -> DiffFinding? in
            guard new.frontmatter.fields[key] != nil,
                  file.old?.frontmatter.fields[key] == nil
            else { return nil }
            return finding(.relationFieldOnObjectPage, file.file.path, line: new.keyLine(key),
                "Relation fields such as `\(key)` are not allowed on object pages. A relation is "
                    + "a page in `content/Reductions/`. (lint: `object-relation-field`)")
        }
    }

    private static func isObjectPage(_ path: String, frontmatter: Frontmatter) -> Bool {
        if let type = frontmatter.string("type")?.lowercased() { return objectTypes.contains(type) }
        let directory = (String(path.dropFirst(contentPrefix.count)) as NSString)
            .deletingLastPathComponent
        return objectTypes.contains(PageKind.forDirectory(directory).rawValue)
    }

    // MARK: - Math in wikilinks (lint.mjs 1238–1272; markdown-text.mjs 183–196)

    private static let fencedSpan = try! NSRegularExpression(pattern: #"```[\s\S]*?```"#)
    private static let inlineCodeSpan = try! NSRegularExpression(pattern: #"`[^`\n]*`"#)
    private static let wikilinkSpan = try! NSRegularExpression(pattern: #"!?\[\[([^\[\]\n]*)\]\]"#)
    /// A `$` not escaped by a backslash.
    private static let unescapedDollar = try! NSRegularExpression(pattern: #"(^|[^\\])(\\\\)*\$"#)

    /// `dollarWikilinks`, line for line: code fences and inline code are
    /// blanked to spaces first, keeping every offset, then each `[[…]]`
    /// holding an unescaped `$` is a hit. Only added lines outside the
    /// generated regions count; inside one the lint blames the generator.
    private static func wikilinkMathFindings(_ file: InspectedFile) -> [DiffFinding] {
        guard let new = file.new, !file.added.isEmpty else { return [] }
        let added = Set(file.added)

        var units = Array(new.body.utf16)
        blank(fencedSpan, in: &units)
        blank(inlineCodeSpan, in: &units)
        let scan = String(decoding: units, as: UTF16.self)
        let lineStarts = Self.lineStarts(units)

        var hits: Set<Int> = []
        for match in wikilinkSpan.matches(in: scan, range: NSRange(location: 0, length: units.count)) {
            let inner = (scan as NSString).substring(with: match.range(at: 1))
            let innerRange = NSRange(location: 0, length: (inner as NSString).length)
            guard unescapedDollar.firstMatch(in: inner, range: innerRange) != nil else { continue }
            let line = new.bodyStartLine + Self.line(of: match.range.location, lineStarts: lineStarts)
            guard added.contains(line), !new.regions.contains(line: line) else { continue }
            hits.insert(line)
        }
        return hits.sorted().map { line in
            finding(.wikilinkMath, file.file.path, line: line,
                "Math in a wikilink breaks the link on the site. Write `[text $x$](slug)` instead. "
                    + "(lint: `wikilink-math`)")
        }
    }

    /// UTF-16 code units the scans compare with.
    private static let lineFeed: UInt16 = 0x0A
    private static let space: UInt16 = 0x20

    /// Each match's characters, but not its line feeds, become spaces: the
    /// JavaScript `replace` that keeps every offset.
    private static func blank(_ pattern: NSRegularExpression, in units: inout [UInt16]) {
        let text = String(decoding: units, as: UTF16.self)
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: units.count)) {
            for offset in match.range.location..<NSMaxRange(match.range) where units[offset] != lineFeed {
                units[offset] = space
            }
        }
    }

    private static func lineStarts(_ units: [UInt16]) -> [Int] {
        var starts = [0]
        for (offset, unit) in units.enumerated() where unit == lineFeed {
            starts.append(offset + 1)
        }
        return starts
    }

    /// The 0-based line holding UTF-16 `offset`.
    private static func line(of offset: Int, lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    // MARK: - Prose relation bullets

    private static let relationSections: Set<String> = [
        "other results", "known relationships", "known results",
    ]
    private static let listItem = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d{1,9}[.)])\s+"#)

    /// An added list item with two or more wikilinks, under `# Other
    /// results`, `# Known relationships` or `## Known Results`, at any depth.
    /// Relationships are reduction pages now.
    private static func proseBulletFindings(_ file: InspectedFile) -> [DiffFinding] {
        guard let new = file.new, !file.added.isEmpty else { return [] }
        let added = Set(file.added)
        var sections: [(level: Int, name: String)] = []
        var fence = FenceTracker()
        var hits: [Int] = []

        for index in new.bodyStartLine..<new.lines.count {
            let line = new.lines[index]
            if fence.consume(line) { continue }
            if let heading = WikiPage.atxHeading(line) {
                sections.removeAll { $0.level >= heading.level }
                sections.append((level: heading.level, name: heading.text.lowercased()))
                continue
            }
            // A generated region sits under `# Other results`, and its
            // "(via …)" lines carry two wikilinks: they are the script's.
            guard added.contains(index), !new.regions.contains(line: index),
                  sections.contains(where: { relationSections.contains($0.name) })
            else { continue }
            let text = String(line)
            let range = NSRange(location: 0, length: (text as NSString).length)
            guard listItem.firstMatch(in: text, range: range) != nil,
                  wikilinkSpan.numberOfMatches(in: text, range: range) >= 2
            else { continue }
            hits.append(index)
        }
        return hits.map { line in
            finding(.proseRelationBullet, file.file.path, line: line,
                "This adds a relationship as a prose bullet. Relationships are reduction pages.")
        }
    }

    // MARK: - Status

    private static func statusFindings(_ file: InspectedFile) -> [DiffFinding] {
        guard let new = file.new,
              new.frontmatter.string("status")?.lowercased() == "complete",
              file.old?.frontmatter.string("status")?.lowercased() != "complete"
        else { return [] }
        return [finding(.statusComplete, file.file.path, line: new.keyLine("status"),
            "`status: complete` is a human judgement, and the lint then requires the full "
                + "section contract.")]
    }

    // MARK: - Raw HTML

    /// An HTML open or close tag, as markdown-it's `HTML_TAG_RE` reads one,
    /// or the start of a comment. An autolink (`<https://…>`) is neither.
    private static let htmlTag = try! NSRegularExpression(pattern:
        #"<[A-Za-z][A-Za-z0-9-]*(?:\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\s*=\s*(?:[^\s"'=<>`]+|'[^']*'|"[^"]*"))?)*\s*/?>"#
            + #"|</[A-Za-z][A-Za-z0-9-]*\s*>|<!--"#)
    private static let generatedMarker = try! NSRegularExpression(pattern:
        #"<!-- (?:BEGIN GENERATED participates-in(?: [0-9a-f]+)?|END GENERATED participates-in) -->"#)

    /// An added body line with HTML outside code, math and the generated
    /// markers. The wiki's 222 `<!--` are all generated markers.
    private static func rawHTMLFindings(_ file: InspectedFile) -> [DiffFinding] {
        guard let new = file.new, !file.added.isEmpty else { return [] }
        let added = Set(file.added)
        var fence = FenceTracker()
        var displayMath: Int?
        var hits: [Int] = []

        for index in new.bodyStartLine..<new.lines.count {
            let line = new.lines[index]
            if let size = displayMath {
                if closesDisplayMath(line, size: size) { displayMath = nil }
                continue
            }
            if fence.consume(line) { continue }
            if let size = opensDisplayMath(line) {
                displayMath = size
                continue
            }
            guard added.contains(index) else { continue }
            let visible = visibleInline(String(line))
            let range = NSRange(location: 0, length: (visible as NSString).length)
            if htmlTag.firstMatch(in: visible, range: range) != nil { hits.append(index) }
        }
        return hits.map { line in
            finding(.rawHTML, file.file.path, line: line,
                "This adds raw HTML, which the Rendered view may hide. Check it in Source.")
        }
    }

    /// The line as markdown-it would hand it to its HTML rule: generated
    /// markers, escaped characters, code spans and `$…$` spans blanked.
    /// Math pairs a run of `$` with the next run of the same length, as the
    /// reader's `mathInline` does.
    private static func visibleInline(_ line: String) -> String {
        var units = Array(line.utf16)
        blank(generatedMarker, in: &units)

        let backslash: UInt16 = 0x5C
        let backtick: UInt16 = 0x60
        let dollar: UInt16 = 0x24

        func run(of unit: UInt16, at start: Int) -> Int {
            var end = start
            while end < units.count, units[end] == unit { end += 1 }
            return end - start
        }
        /// The next run of exactly `length` `unit`s at or after `start`.
        func closingRun(of unit: UInt16, length: Int, from start: Int) -> Int? {
            var index = start
            while index < units.count {
                guard units[index] == unit else { index += 1; continue }
                let found = run(of: unit, at: index)
                if found == length { return index }
                index += found
            }
            return nil
        }

        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == backslash, index + 1 < units.count, isASCIIPunctuation(units[index + 1]) {
                units[index] = space
                units[index + 1] = space
                index += 2
            } else if unit == backtick || unit == dollar {
                let length = run(of: unit, at: index)
                if let close = closingRun(of: unit, length: length, from: index + length) {
                    for offset in index..<(close + length) { units[offset] = space }
                    index = close + length
                } else {
                    index += length
                }
            } else {
                index += 1
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func isASCIIPunctuation(_ unit: UInt16) -> Bool {
        (0x21...0x2F).contains(unit) || (0x3A...0x40).contains(unit)
            || (0x5B...0x60).contains(unit) || (0x7B...0x7E).contains(unit)
    }

    /// `$$` (or longer) at the start of a line with no other `$` on it opens
    /// a display block, as the reader's `mathBlock` reads it: the size of
    /// the run.
    private static func opensDisplayMath(_ line: Substring) -> Int? {
        let indent = line.prefix { $0 == " " }.count
        guard indent < 4 else { return nil }
        let rest = line.dropFirst(indent)
        let size = rest.prefix { $0 == "$" }.count
        guard size >= 2, !rest.dropFirst(size).contains("$") else { return nil }
        return size
    }

    /// A run of at least `size` `$` at the start of a line, and nothing after
    /// it but spaces.
    private static func closesDisplayMath(_ line: Substring, size: Int) -> Bool {
        let rest = line.drop { $0 == " " }
        let run = rest.prefix { $0 == "$" }.count
        return run >= size && rest.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }

    // MARK: - Scope

    private static let objectDirectories: Set<String> = [
        "Primitives", "Assumptions", "Complexity", "Glossary", "Folklore",
    ]
    /// Where an ingestion adds pages without anyone's leave.
    private static let ingestionDirectories: Set<String> = ["References", "Reductions", "Barriers"]

    /// A correction is a line or two; an ingestion adds pages and touches at
    /// most one existing page, by at most five lines (ingestion.md §4).
    /// Lines inside generated regions are the script's, and do not count.
    private static func scopeFindings(_ files: [InspectedFile], context: Context) -> [DiffFinding] {
        switch context.family {
        case .correction:
            let counted = files.filter { $0.file.isMarkdown }.map { ($0, handChangedLines($0)) }
            let total = counted.reduce(0) { $0 + $1.1 }
            guard total > 20, let largest = counted.max(by: { $0.1 < $1.1 }) else { return [] }
            return [finding(.largeEdit, largest.0.file.path,
                "This changes \(total) lines. A correction is usually a line or two.")]

        case .ingestion:
            var found: [DiffFinding] = []
            let newPages = files.filter {
                $0.file.status == .added && $0.isPage
                    && !ingestionDirectories.contains(topDirectory(of: $0.file.path))
            }
            if newPages.count > 1 {
                found.append(finding(.ingestionScope, newPages[0].file.path,
                    "This adds \(spelled(newPages.count)) pages outside `References/`, `Reductions/` "
                        + "and `Barriers/`. An ingestion normally adds a reference and its reductions."))
            }
            let touched = files
                .filter { ($0.file.status == .modified || $0.file.status == .renamed) && $0.isPage }
                .map { ($0, handChangedLines($0)) }
                .filter { $0.1 > 0 }
            if touched.count > 1 {
                found.append(finding(.ingestionScope, touched[0].0.file.path,
                    "This changes \(spelled(touched.count)) existing pages. An ingestion normally adds "
                        + "pages and touches at most one."))
            }
            for (file, count) in touched where count > 5 {
                let name = (file.file.path as NSString).lastPathComponent
                found.append(finding(.ingestionScope, file.file.path, line: firstHandChangedLine(file),
                    "This changes \(count) lines of `\(name)` by hand. An ingestion normally changes "
                        + "at most five lines of an existing page."))
            }
            return found
        }
    }

    /// Per hunk, the larger side, less the lines inside generated regions.
    private static func handChangedLines(_ file: InspectedFile) -> Int {
        file.file.hunks.reduce(0) { (total: Int, hunk: LineHunk) -> Int in
            let removed = hunk.old.filter { !(file.old?.regions.contains(line: $0) ?? false) }.count
            let added = hunk.new.filter { !(file.new?.regions.contains(line: $0) ?? false) }.count
            return total + max(removed, added)
        }
    }

    /// The new text's line where the first hand change is, for a finding
    /// that would otherwise share its id with the file's other one.
    private static func firstHandChangedLine(_ file: InspectedFile) -> Int {
        let lineCount = file.new?.lines.count ?? 0
        for hunk in file.file.hunks {
            if let line = hunk.new.first(where: { !(file.new?.regions.contains(line: $0) ?? false) }) {
                return line
            }
            if hunk.new.isEmpty { return max(0, min(hunk.new.lowerBound, lineCount - 1)) }
        }
        return 0
    }

    // MARK: - Derived files

    private static let identityFields = ["id", "title", "aliases", "variants", "unlisted", "type"]

    private static let derivedFilesMessage = """
        The “Participates in” sections and `relations.json` are now out of date, and the wiki's \
        checks fail until they are regenerated. In this job's worktree (Open in Terminal), run \
        `npm ci` and `node scripts/generate-relations.mjs`, then review again. Or run them on the \
        branch after the pull request is open.
        """

    /// Without a regenerated `relations.json`, the change touches what the
    /// generator reads: a reduction or barrier page's frontmatter, an object
    /// page's identity, or a heading a `variants` anchor names.
    private static func derivedFilesFindings(_ files: [InspectedFile]) -> [DiffFinding] {
        guard !files.contains(where: { $0.file.path == relationsJSON || $0.file.oldPath == relationsJSON })
        else { return [] }
        return files
            .filter { $0.file.isMarkdown && $0.file.path.hasPrefix(contentPrefix) && staleDerivedFiles($0) }
            .map { finding(.derivedFilesStale, $0.file.path, derivedFilesMessage) }
    }

    private static func staleDerivedFiles(_ file: InspectedFile) -> Bool {
        let old = file.old
        let new = file.new
        let types = [old?.frontmatter.string("type"), new?.frontmatter.string("type")]
            .compactMap { $0?.lowercased() }
        let directories = [file.file.path, file.file.oldPath].compactMap { $0 }.map { topDirectory(of: $0) }

        if types.contains(where: { $0 == "reduction" || $0 == "barrier" })
            || directories.contains(where: { $0 == "Reductions" || $0 == "Barriers" }) {
            return old?.frontmatterText != new?.frontmatterText
        }

        let isObject = [old, new].contains { side in
            side.map { isObjectPage(file.file.path, frontmatter: $0.frontmatter) } ?? false
        }
        guard isObject else { return false }
        if identityFields.contains(where: { old?.field($0) != new?.field($0) }) { return true }

        let anchors = Set((old?.variantAnchors ?? []) + (new?.variantAnchors ?? []))
        guard !anchors.isEmpty else { return false }
        let oldIDs = old?.headingIDs(path: file.file.path) ?? []
        let newIDs = new?.headingIDs(path: file.file.path) ?? []
        return anchors.contains { oldIDs.contains($0) != newIDs.contains($0) }
    }

    // MARK: - Helpers

    private static let contentPrefix = "content/"

    /// The directory under `content/` a path is in: "Primitives", or "" for
    /// a root page and anything outside `content/`.
    private static func topDirectory(of path: String) -> String {
        guard path.hasPrefix(contentPrefix) else { return "" }
        let components = path.dropFirst(contentPrefix.count).split(separator: "/")
        return components.count > 1 ? String(components[0]) : ""
    }

    private static func spelled(_ count: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        return words.indices.contains(count) ? words[count] : String(count)
    }

    private static func severity(of rule: DiffFinding.Rule) -> DiffFinding.Severity {
        switch rule {
        case .outsideContent, .renamedOrDeleted, .binaryFile, .generatedRegionEdited,
             .relationFieldOnObjectPage, .wikilinkMath, .privateText:
            .blocking
        case .newObjectPage, .otherPages, .largeEdit, .ingestionScope, .proseRelationBullet,
             .derivedFilesStale, .relationsJSONByHand, .humanVerified, .statusComplete,
             .changedUpstream, .rawHTML:
            .warning
        case .regionRegenerated:
            .note
        }
    }

    private static func finding(
        _ rule: DiffFinding.Rule, _ path: String, lines: LineRange? = nil, _ message: String
    ) -> DiffFinding {
        DiffFinding(rule: rule, severity: severity(of: rule), path: path, lines: lines, message: message)
    }

    /// A finding on one 0-based line, or on the file when there is none.
    private static func finding(
        _ rule: DiffFinding.Rule, _ path: String, line: Int?, _ message: String
    ) -> DiffFinding {
        finding(rule, path, lines: line.map { LineRange(first: $0 + 1, last: $0 + 1) }, message)
    }

    /// Blocking first, then by path, line and rule; one finding per id.
    private static func ordered(_ findings: [DiffFinding]) -> [DiffFinding] {
        let rank = Dictionary(uniqueKeysWithValues: DiffFinding.Rule.allCases.enumerated().map { ($1, $0) })
        let sorted = findings.sorted { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            if a.path != b.path { return a.path < b.path }
            let lineA = a.lines?.first ?? 0
            let lineB = b.lines?.first ?? 0
            if lineA != lineB { return lineA < lineB }
            return rank[a.rule, default: 0] < rank[b.rule, default: 0]
        }
        var seen: Set<String> = []
        return sorted.filter { seen.insert($0.id).inserted }
    }
}

// MARK: - A file, read once

/// A changed file as every rule reads it: each side's lines, frontmatter
/// and generated regions, and the lines the change added.
private struct InspectedFile {
    let file: ChangedFile
    let old: InspectedText?
    let new: InspectedText?
    /// 0-based lines of the new text the change added or rewrote, in order.
    let added: [Int]
    /// A Markdown page of the wiki: the rules about pages apply.
    let isPage: Bool

    init(_ file: ChangedFile) {
        self.file = file
        let old = file.isBinary ? nil : file.oldText.map { InspectedText($0) }
        let new = file.isBinary ? nil : file.newText.map { InspectedText($0) }
        self.old = old
        self.new = new
        let lineCount = new?.lines.count ?? 0
        self.added = file.hunks.flatMap { Array($0.new) }.filter { $0 < lineCount }
        self.isPage = file.isMarkdown && file.path.hasPrefix("content/") && !file.isBinary
    }
}

/// One side of a file.
private struct InspectedText {
    let text: String
    /// Without their line endings, numbered as `LineDiff` numbers them.
    let lines: [Substring]
    let frontmatter: Frontmatter
    /// The lines between the fences; empty without frontmatter.
    let frontmatterLines: Range<Int>
    /// The 0-based line the body starts on.
    let bodyStartLine: Int
    let body: String
    let regions: GeneratedRegions

    init(_ text: String) {
        let lines = LineDiff.lines(of: text).map { line -> Substring in
            line.last == "\n" || line.last == "\r\n" ? line.dropLast() : line
        }
        let frontmatter = Frontmatter.parse(text)

        // When Frontmatter.parse found a closing fence, it is the first
        // `---` or `...` after the first line, as it reads them.
        var close: Int?
        if frontmatter.bodyStart > text.startIndex {
            close = lines.indices.dropFirst().first { (index: Int) -> Bool in
                let line = String(lines[index]).trimmedTrailing
                return line == "---" || line == "..."
            }
        }
        let bodyStartLine = close.map { $0 + 1 } ?? 0
        let body = String(text[frontmatter.bodyStart...])

        self.text = text
        self.lines = lines
        self.frontmatter = frontmatter
        self.frontmatterLines = close.map { 1..<$0 } ?? 0..<0
        self.bodyStartLine = bodyStartLine
        self.body = body
        self.regions = GeneratedRegions(body: body, firstLine: bodyStartLine)
    }

    /// The 0-based line of a top-level frontmatter key.
    func keyLine(_ key: String) -> Int? {
        frontmatterLines.first { lines[$0].hasPrefix(key + ":") }
    }

    /// A top-level key's lines as written, with the indented lines under it:
    /// `variants` is a mapping, which `Frontmatter` leaves out.
    func field(_ key: String) -> String? {
        guard let start = keyLine(key) else { return nil }
        var end = start + 1
        while end < frontmatterLines.upperBound,
              let first = lines[end].first, first == " " || first == "\t" {
            end += 1
        }
        return lines[start..<end].map { String($0).trimmedTrailing }.joined(separator: "\n")
    }

    var frontmatterText: String {
        lines[frontmatterLines].joined(separator: "\n")
    }

    /// The anchors `variants` names: `weak-prf: "#weak-prfs"` gives
    /// "weak-prfs".
    var variantAnchors: [String] {
        guard let block = field("variants") else { return [] }
        return block.split(separator: "\n").dropFirst().compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let value = Frontmatter.unquote(
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            return value.hasPrefix("#") ? String(value.dropFirst()) : nil
        }
    }

    /// The heading anchors the site gives this text.
    func headingIDs(path: String) -> Set<String> {
        Set(WikiPage(path: path, text: text).headings().map(\.id))
    }
}

/// The "Participates in" regions of a page body, found as lint.mjs's
/// `GEN_RE` finds them: each BEGIN marker with its checksum, lazily to the
/// next END marker.
private struct GeneratedRegions {

    struct Region {
        /// 0-based file lines, from the BEGIN marker's to the END marker's.
        let lines: ClosedRange<Int>
        /// The whole region, markers included.
        let text: String
        /// Its contents hash to the checksum its BEGIN marker declares.
        let isIntact: Bool
    }

    static let begin = "<!-- BEGIN GENERATED participates-in"
    static let end = "<!-- END GENERATED participates-in -->"

    private(set) var begins = 0
    private(set) var ends = 0
    private(set) var regions: [Region] = []
    /// The first line holding either marker.
    private(set) var firstMarkerLine: Int?

    var isBalanced: Bool { begins == ends }

    func contains(line: Int) -> Bool {
        regions.contains { $0.lines.contains(line) }
    }

    init(body: String, firstLine: Int) {
        func line(at index: String.Index) -> Int {
            firstLine + body[..<index].utf8.reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
        }

        // The marker counts, as `split(GEN_BEGIN).length - 1` counts them.
        var markers: [String.Index] = []
        for marker in [Self.begin, Self.end] {
            var from = body.startIndex
            while let found = body.range(of: marker, options: .literal, range: from..<body.endIndex) {
                if marker == Self.begin { begins += 1 } else { ends += 1 }
                markers.append(found.lowerBound)
                from = found.upperBound
            }
        }
        firstMarkerLine = markers.min().map(line(at:))

        // `<!-- BEGIN GENERATED participates-in ([0-9a-f]+) -->([\s\S]*?)<!-- END … -->`
        let scalars = body.unicodeScalars
        let open = Self.begin + " "
        let close = " -->".unicodeScalars
        var from = body.startIndex
        while let found = body.range(of: open, options: .literal, range: from..<body.endIndex) {
            var cursor = found.upperBound
            while cursor < body.endIndex, Self.isLowercaseHex(scalars[cursor]) {
                cursor = scalars.index(after: cursor)
            }
            guard cursor > found.upperBound, scalars[cursor...].starts(with: close) else {
                // Not a marker the pattern accepts; it may match further on.
                from = scalars.index(after: found.lowerBound)
                continue
            }
            let declared = String(body[found.upperBound..<cursor])
            let innerStart = scalars.index(cursor, offsetBy: close.count)
            guard let endMarker = body.range(
                of: Self.end, options: .literal, range: innerStart..<body.endIndex)
            else { break }
            let inner = String(body[innerStart..<endMarker.lowerBound])
            regions.append(Region(
                lines: line(at: found.lowerBound)...line(at: endMarker.lowerBound),
                text: String(body[found.lowerBound..<endMarker.upperBound]),
                isIntact: DiffGuard.regionChecksum(inner) == declared))
            from = endMarker.upperBound
        }
    }

    private static func isLowercaseHex(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value) || (0x61...0x66).contains(scalar.value)
    }
}

/// Whether a line is inside a fenced code block, fed one line at a time:
/// three or more backticks or tildes open one, and a run at least as long
/// of the same character, alone on its line, closes it.
private struct FenceTracker {
    private var marker: Character?
    private var length = 0

    /// True for an opening or closing fence and every line between.
    mutating func consume(_ line: Substring) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if let open = marker {
            let run = trimmed.prefix { $0 == open }.count
            if run >= length, trimmed.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) {
                marker = nil
            }
            return true
        }
        guard let first = trimmed.first, first == "`" || first == "~" else { return false }
        let run = trimmed.prefix { $0 == first }.count
        guard run >= 3 else { return false }
        marker = first
        length = run
        return true
    }
}
