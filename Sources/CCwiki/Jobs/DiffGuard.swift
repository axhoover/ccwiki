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
///   `generated-region-edited`: lint.mjs 1075–1109 (and, for a region's
///   whitespace or its removal, `generate-relations.mjs --check`, 309–336);
/// - `relationFieldOnObjectPage`, its `object-relation-field`: lint.mjs
///   95–104 (`TYPES`), 159–171 (`FORBIDDEN_ON_OBJECTS`) and 500–511;
/// - `wikilinkMath`, its `wikilink-math`: lint.mjs 1238–1272, scanning with
///   `dollarWikilinks`, markdown-text.mjs 183–196.
///
/// Rules about lines look only at the lines the change added, so a page
/// that already broke a rule at the base does not block a fix elsewhere on
/// it. `wikilinkMath` counts its hits against the base's instead, because
/// an edit elsewhere can take a link out of a code fence.
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
        // `relations.json` is part of the change, so the generator ran in
        // this worktree, at some point: a region it rewrote is its doing.
        // (A correction's agent cannot run it; `relationsJSONByHand` asks.)
        let relations = files.first { $0.file.path == relationsJSON && $0.file.status != .deleted }
        let relationsRegenerated = relations != nil
        // What it wrote: a region gone is its doing only if its records say
        // so, and they say whether a page was edited after it ran.
        let manifest: WrittenManifest? = relations?.file.newText.flatMap(WrittenManifest.init(json:))
        // The generator drops a region only from an object page it leaves
        // with no relation (generate-relations.mjs 320–336).
        let scriptRemovals = Set(files.filter { file in
            guard let manifest, let new = file.new, !file.removedRegions.isEmpty else { return false }
            return !manifest.expectsRegion(on: new)
        }.map(\.file.path))

        var findings: [DiffFinding] = []
        for file in files {
            findings += pathFindings(file.file, context: context)
            findings += privateTextFindings(file, privatePaths: context.privatePaths)
            if file.isPage {
                findings += regionFindings(
                    file, relationsRegenerated: relationsRegenerated,
                    removedByScript: scriptRemovals.contains(file.file.path))
                findings += relationFieldFindings(file)
                findings += wikilinkMathFindings(file)
                findings += proseBulletFindings(file)
                findings += statusFindings(file)
                findings += rawHTMLFindings(file)
            }
        }
        findings += scopeFindings(files, context: context, scriptRemovals: scriptRemovals)
        findings += derivedFilesFindings(files, relations: relations, manifest: manifest)
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
        // isPublishable lets it through, and no other rule reads a deletion
        // outside content/.
        if file.status == .deleted, file.path == relationsJSON {
            found.append(finding(.renamedOrDeleted, file.path,
                "`relations.json` is generated, and the site reads it. Restore the file."))
        }
        if file.status != .deleted, file.isBinary || file.path.lowercased().hasSuffix(".pdf") {
            // A page or relations.json that git calls binary, or whose text
            // the snapshot could not read (`ReviewSnapshot.assemble`).
            let message = isPublishable(file.path)
                ? "CCwiki could not read this file as UTF-8 text, so it checked nothing in it. "
                    + "Revert it, or save it as UTF-8."
                : "PDFs and other binary files never enter the wiki."
            found.append(finding(.binaryFile, file.path, message))
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

    /// Unbalanced markers, and regions edited or removed by hand, block; a
    /// region the script rewrote, with `relations.json` regenerated, or
    /// removed from a page its records relate nothing to, is a note. A
    /// region changed as the script writes one, but without
    /// `relations.json`, warns. A region already broken at the base,
    /// character for character, is not this change's doing.
    private static func regionFindings(
        _ file: InspectedFile, relationsRegenerated: Bool, removedByScript: Bool
    ) -> [DiffFinding] {
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
            if !region.isIntact {
                let message = """
                    The “Participates in” section on \(lines.label) was edited by hand. It is \
                    rebuilt from the reduction pages; correct those instead. \
                    (lint: `generated-region-edited`)
                    """
                found.append(finding(.generatedRegionEdited, path, lines: lines, message))
            } else if !region.hasGeneratorShape {
                // The lint's checksum trims; the generator's `--check`
                // compares bytes (generate-relations.mjs 309–336). The blank
                // lines may be intact, with a space added at an edge of the
                // section, so the message names the whole layout.
                let message = """
                    The whitespace in the “Participates in” section on \(lines.label) was changed \
                    by hand. Its checksum still matches, but the wiki's \
                    `generate-relations.mjs --check` fails; restore the layout the script writes: \
                    one blank line after the BEGIN marker, one before the END marker, and no other \
                    whitespace at either end of the section (or run \
                    `node scripts/generate-relations.mjs`).
                    """
                found.append(finding(.generatedRegionEdited, path, lines: lines, message))
            } else if relationsRegenerated {
                found.append(finding(.regionRegenerated, path, lines: lines,
                    "Regenerated by the script, not edited by hand."))
            } else {
                // A region is built from what `relations.json` records, so
                // the script changes the two together. Without it, this one
                // was most likely pasted, from an older version, say.
                found.append(finding(.derivedFilesStale, path, lines: lines, regionStaleMessage(lines)))
            }
        }

        // A region gone, markers and all, leaves the counts equal. The
        // generator writes it back, so the wiki's `generate-relations.mjs
        // --check` fails (its lines 320–336), unless the generator itself
        // dropped it, from a page left with no relation.
        if let removed = file.removedRegions.first {
            let line = file.newLine(changingOld: removed.lines)
            if removedByScript {
                found.append(finding(.regionRegenerated, path, line: line,
                    "Removed by the script, not by hand: `relations.json` was regenerated too."))
            } else {
                found.append(finding(.generatedRegionEdited, path, line: line,
                    "The “Participates in” section was removed by hand. It is rebuilt from the "
                        + "reduction pages; restore it, and correct those instead."))
            }
        }
        return found
    }

    /// JavaScript's `trim()`: WhiteSpace (tab, VT, FF, ZWNBSP and every
    /// space separator) and LineTerminator (LF, CR, LS, PS).
    fileprivate static func isECMAScriptSpace(_ scalar: Unicode.Scalar) -> Bool {
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

    /// A key the change adds to an object page's frontmatter, quoted or
    /// not, as js-yaml reads keys. The lint decides by `type:`; a page
    /// without one is judged by its directory. A key the page had before
    /// counts only if it was an object page then: a reduction page's
    /// `hypotheses` breaks the lint once the page becomes an object page.
    private static func relationFieldFindings(_ file: InspectedFile) -> [DiffFinding] {
        guard let new = file.new, isObjectPage(file.file.path, new) else { return [] }
        let before = file.old.flatMap { old in
            isObjectPage(file.file.oldPath ?? file.file.path, old) ? old : nil
        }
        return forbiddenOnObjects.compactMap { key -> DiffFinding? in
            guard let line = new.keyLine(key), before?.keyLine(key) == nil else { return nil }
            return finding(.relationFieldOnObjectPage, file.file.path, line: line,
                "Relation fields such as `\(key)` are not allowed on object pages. A relation is "
                    + "a page in `content/Reductions/`. (lint: `object-relation-field`)")
        }
    }

    /// By `type:` as js-yaml reads it, a comment after it dropped, or else
    /// by the page's directory.
    private static func isObjectPage(_ path: String, _ text: InspectedText) -> Bool {
        if let type = text.type?.lowercased() { return objectTypes.contains(type) }
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

    /// The hits the change adds: the new text's, less as many of each link
    /// as the base already had. A page that already broke the rule does not
    /// block a fix elsewhere on it; but the fences pair across the whole
    /// body, so an edit on another line can take an unchanged link out of
    /// code, and that link counts. The unchanged lines' hits spend the
    /// base's first, so a hit is reported where the change added it.
    private static func wikilinkMathFindings(_ file: InspectedFile) -> [DiffFinding] {
        guard let new = file.new else { return [] }
        let hits = dollarHits(new)
        guard !hits.isEmpty else { return [] }
        var budget: [String: Int] = [:]
        for hit in file.old.map(dollarHits) ?? [] { budget[hit.raw, default: 0] += 1 }

        let added = Set(file.added)
        var lines: Set<Int> = []
        for hit in hits.filter({ !added.contains($0.line) }) + hits.filter({ added.contains($0.line) }) {
            if let left = budget[hit.raw], left > 0 {
                budget[hit.raw] = left - 1
            } else {
                lines.insert(hit.line)
            }
        }
        return lines.sorted().map { line in
            finding(.wikilinkMath, file.file.path, line: line,
                "Math in a wikilink breaks the link on the site. Write `[text $x$](slug)` instead. "
                    + "(lint: `wikilink-math`)")
        }
    }

    /// `dollarWikilinks`, line for line: code fences and inline code are
    /// blanked to spaces first, keeping every offset, then each `[[…]]`
    /// holding an unescaped `$` is a hit, with its 0-based file line. A hit
    /// inside a generated region, from its BEGIN marker to the end of its
    /// END marker, is left out: there the lint blames the generator, and a
    /// hand edit is `generatedRegionEdited`. Text after a marker on its
    /// line is outside, as it is to the lint's `generated` spans.
    private static func dollarHits(_ text: InspectedText) -> [(line: Int, raw: String)] {
        var units = Array(text.body.utf16)
        blank(fencedSpan, in: &units)
        blank(inlineCodeSpan, in: &units)
        let scan = String(decoding: units, as: UTF16.self) as NSString
        let lineStarts = Self.lineStarts(units)

        var hits: [(line: Int, raw: String)] = []
        for match in wikilinkSpan.matches(in: scan as String, range: NSRange(location: 0, length: units.count)) {
            let inner = scan.substring(with: match.range(at: 1))
            let innerRange = NSRange(location: 0, length: (inner as NSString).length)
            guard unescapedDollar.firstMatch(in: inner, range: innerRange) != nil,
                  !text.regions.contains(utf16Offset: match.range.location)
            else { continue }
            let line = text.bodyStartLine + Self.line(of: match.range.location, lineStarts: lineStarts)
            hits.append((line: line, raw: scan.substring(with: match.range)))
        }
        return hits
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
    /// Only the lines a hand changed count (`InspectedFile.isHandLine`).
    private static func scopeFindings(
        _ files: [InspectedFile], context: Context, scriptRemovals: Set<String>
    ) -> [DiffFinding] {
        func handChanged(_ file: InspectedFile) -> Int {
            handChangedLines(file, removedByScript: scriptRemovals.contains(file.file.path))
        }
        switch context.family {
        case .correction:
            let counted = files.filter { $0.file.isMarkdown }.map { ($0, handChanged($0)) }
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
                .map { ($0, handChanged($0)) }
                .filter { $0.1 > 0 }
            if touched.count > 1 {
                found.append(finding(.ingestionScope, touched[0].0.file.path,
                    "This changes \(spelled(touched.count)) existing pages. An ingestion normally adds "
                        + "pages and touches at most one."))
            }
            for (file, count) in touched where count > 5 {
                let name = (file.file.path as NSString).lastPathComponent
                let line = firstHandChangedLine(
                    file, removedByScript: scriptRemovals.contains(file.file.path))
                found.append(finding(.ingestionScope, file.file.path, line: line,
                    "This changes \(count) lines of `\(name)` by hand. An ingestion normally changes "
                        + "at most five lines of an existing page."))
            }
            return found
        }
    }

    /// Per hunk, the larger side, counting the lines a hand changed.
    private static func handChangedLines(_ file: InspectedFile, removedByScript: Bool) -> Int {
        file.file.hunks.reduce(0) { (total: Int, hunk: LineHunk) -> Int in
            let removed = hunk.old.filter {
                file.isHandLine(old: $0, regionsRemovedByScript: removedByScript)
            }.count
            let added = hunk.new.filter { file.isHandLine(new: $0) }.count
            return total + max(removed, added)
        }
    }

    /// The new text's line where the first hand change is, for a finding
    /// that would otherwise share its id with the file's other one.
    private static func firstHandChangedLine(_ file: InspectedFile, removedByScript: Bool) -> Int {
        let lastLine = max(0, (file.new?.lines.count ?? 0) - 1)
        for hunk in file.file.hunks {
            if let line = hunk.new.first(where: { file.isHandLine(new: $0) }) { return line }
            let removesHandLines = hunk.old.contains {
                file.isHandLine(old: $0, regionsRemovedByScript: removedByScript)
            }
            if removesHandLines { return min(hunk.new.lowerBound, lastLine) }
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

    /// A region changed as the script writes one, without `relations.json`.
    private static func regionStaleMessage(_ lines: LineRange) -> String {
        """
        The “Participates in” section on \(lines.label) changed, but `relations.json` did not, \
        so the script did not write it, and the wiki's `generate-relations.mjs --check` may fail. \
        In this job's worktree (Open in Terminal), run `npm ci` and \
        `node scripts/generate-relations.mjs`, then review again.
        """
    }

    /// `relations.json` changed the records of `pages`, sorted, and the
    /// change leaves them as they were.
    private static func relationsStaleMessage(_ pages: [String]) -> String {
        var names = pages.prefix(3).map { "`\($0)`" }
        if pages.count > 3 { names.append("\(pages.count - 3) more") }
        let list = names.count > 1
            ? names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
            : names.joined()
        let left = pages.count == 1 ? "that page as it was" : "those pages as they were"
        return """
            `relations.json` changed what it records for \(list), but this change leaves \(left), \
            so the wiki's `generate-relations.mjs --check` fails. In this job's worktree (Open in \
            Terminal), run `npm ci` and `node scripts/generate-relations.mjs`, then review again.
            """
    }

    /// Without a regenerated `relations.json`, the pages whose change
    /// touches what the generator reads (`staleDerivedFiles`). With one, its
    /// records are compared with the pages instead, since a page edited
    /// after the generator ran may have been edited back to the base, and
    /// so look unchanged: each page in the diff its new records disagree
    /// with; and, in one finding on `relations.json`, the pages of the
    /// records added, removed or changed since the base that the change
    /// leaves as they were. The generator writes each record from its page
    /// alone, so a record changes only with its page. A `relations.json`
    /// that does not read proves nothing; a base that does not read has no
    /// records.
    private static func derivedFilesFindings(
        _ files: [InspectedFile], relations: InspectedFile?, manifest: WrittenManifest?
    ) -> [DiffFinding] {
        let pages = files.filter { readsAsGeneratorInput($0) }
        guard let relations, let manifest else {
            return pages.filter { staleDerivedFiles($0) }
                .map { finding(.derivedFilesStale, $0.file.path, derivedFilesMessage) }
        }
        var found = pages.filter { !manifest.matches($0) }
            .map { finding(.derivedFilesStale, $0.file.path, derivedFilesMessage) }

        // The pages in the diff were compared above; one CCwiki could not
        // read, or a template, blocks on its own.
        let base = relations.file.oldText.flatMap(WrittenManifest.init(json:))
        let inDiff = Set(files.flatMap { file in
            [file.file.path] + (file.file.oldPath.map { [$0] } ?? [])
        })
        let untouched = manifest.changedPages(since: base).subtracting(inDiff).sorted()
        if !untouched.isEmpty {
            found.append(finding(.derivedFilesStale, relationsJSON, relationsStaleMessage(untouched)))
        }
        return found
    }

    /// A page the generator reads: a Markdown file under `content/` but not
    /// `content/Templates/` (generate-relations.mjs 74–75), whose text
    /// CCwiki could read.
    private static func readsAsGeneratorInput(_ file: InspectedFile) -> Bool {
        file.file.isMarkdown && file.file.path.hasPrefix(contentPrefix)
            && !file.file.path.hasPrefix(contentPrefix + "Templates/") && !file.file.isBinary
    }

    /// The change touches what the generator reads: a reduction or barrier
    /// page's frontmatter, an object page's identity, or a heading a
    /// `variants` anchor names.
    private static func staleDerivedFiles(_ file: InspectedFile) -> Bool {
        let old = file.old
        let new = file.new
        let types = [old?.type, new?.type].compactMap { $0?.lowercased() }
        let directories = [file.file.path, file.file.oldPath].compactMap { $0 }.map { topDirectory(of: $0) }

        if types.contains(where: { $0 == "reduction" || $0 == "barrier" })
            || directories.contains(where: { $0 == "Reductions" || $0 == "Barriers" }) {
            return old?.frontmatterText != new?.frontmatterText
        }

        let isObject = [old, new].contains { side in
            side.map { isObjectPage(file.file.path, $0) } ?? false
        }
        guard isObject else { return false }
        if identityFields.contains(where: { old?.field($0) != new?.field($0) }) { return true }

        // A variant is titled by the heading its anchor names, with its math
        // kept (generate-relations.mjs 101–108, 137), and other pages'
        // "(via …)" lines show that title. So a heading reworded under the
        // same anchor counts, as does one gained or lost. Headings compare
        // as written, so a change to their math counts too. An anchor is
        // slugged first, as `headingAt` slugs it (markdown-text.mjs 172), so
        // `#Strong-RSA` names `## Strong RSA`.
        let anchors = Set((old?.variantAnchors ?? []) + (new?.variantAnchors ?? []))
        guard !anchors.isEmpty else { return false }
        let oldHeadings = old?.headingsByAnchor() ?? [:]
        let newHeadings = new?.headingsByAnchor() ?? [:]
        return anchors.contains { anchor in
            let id = GithubSlugger.slug(anchor)
            return oldHeadings[id] != newHeadings[id]
        }
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
    /// The old text's generated regions the new one no longer has, when it
    /// has fewer: each region of the new text accounts for one of the old
    /// with the same text, so a duplicate dropped counts.
    let removedRegions: [GeneratedRegions.Region]

    init(_ file: ChangedFile) {
        self.file = file
        let old = file.isBinary ? nil : file.oldText.map { InspectedText($0) }
        let new = file.isBinary ? nil : file.newText.map { InspectedText($0) }
        self.old = old
        self.new = new
        let lineCount = new?.lines.count ?? 0
        self.added = file.hunks.flatMap { Array($0.new) }.filter { $0 < lineCount }
        self.isPage = file.isMarkdown && file.path.hasPrefix("content/") && !file.isBinary

        var removed: [GeneratedRegions.Region] = []
        if let before = old?.regions.regions, let after = new?.regions.regions, after.count < before.count {
            var unmatched = after.map(\.text)
            for region in before {
                if let match = unmatched.firstIndex(of: region.text) {
                    unmatched.remove(at: match)
                } else {
                    removed.append(region)
                }
            }
        }
        self.removedRegions = removed
    }

    /// A line of the new text that a hand changed: not blank, and not in a
    /// generated region. The generator writes the blank line before a
    /// region it adds to a page, and drops it with a region it removes
    /// (generate-relations.mjs 329–330).
    func isHandLine(new index: Int) -> Bool {
        guard let text = new, text.lines.indices.contains(index) else { return true }
        return !text.lines[index].allSatisfy(\.isWhitespace) && !text.regions.contains(line: index)
    }

    /// A line of the old text that a hand changed: not blank, and not in a
    /// generated region, unless that region is gone and the generator did
    /// not remove it.
    func isHandLine(old index: Int, regionsRemovedByScript: Bool) -> Bool {
        guard let text = old, text.lines.indices.contains(index) else { return true }
        guard !text.lines[index].allSatisfy(\.isWhitespace) else { return false }
        guard text.regions.contains(line: index) else { return true }
        return !regionsRemovedByScript && removedRegions.contains { $0.lines.contains(index) }
    }

    /// Where the change to these old lines is in the new text: the start of
    /// the hunk that changed them, or of the first, within the new text.
    func newLine(changingOld lines: ClosedRange<Int>) -> Int {
        let hunk = file.hunks.first(where: { $0.old.overlaps(lines) }) ?? file.hunks.first
        let lastLine = max(0, (new?.lines.count ?? 0) - 1)
        return min(hunk?.new.lowerBound ?? 0, lastLine)
    }
}

/// One side of a file.
private struct InspectedText {
    /// Without their line endings, numbered as `LineDiff` numbers them.
    let lines: [Substring]
    let frontmatter: Frontmatter
    /// The lines between the fences; empty without frontmatter.
    let frontmatterLines: Range<Int>
    /// The 0-based line the body starts on.
    let bodyStartLine: Int
    let body: String
    let regions: GeneratedRegions
    /// Each top-level frontmatter key's first line, the key unquoted.
    private let keyLines: [String: Int]

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
        let frontmatterLines = close.map { 1..<$0 } ?? 0..<0

        self.lines = lines
        self.frontmatter = frontmatter
        self.frontmatterLines = frontmatterLines
        self.bodyStartLine = bodyStartLine
        self.body = body
        self.regions = GeneratedRegions(body: body, firstLine: bodyStartLine)

        var keyLines: [String: Int] = [:]
        for index in frontmatterLines {
            guard let entry = YAMLLine.entry(lines[index]), keyLines[entry.key] == nil else { continue }
            keyLines[entry.key] = index
        }
        self.keyLines = keyLines
    }

    /// The 0-based line of a top-level frontmatter key, quoted or not.
    func keyLine(_ key: String) -> Int? {
        keyLines[key]
    }

    /// A top-level key's lines as written: its own, and the lines YAML reads
    /// as its value, indented under it, or `- ` items flush left when it has
    /// no value on its line (as `Frontmatter` reads them), with any blank
    /// or comment lines between them. `variants` is a mapping, which
    /// `Frontmatter` leaves out.
    func field(_ key: String) -> String? {
        guard let start = keyLine(key) else { return nil }
        return lines[start..<fieldEnd(from: start)]
            .map { String($0).trimmedTrailing }.joined(separator: "\n")
    }

    /// Just past the last line of the key on line `start`.
    private func fieldEnd(from start: Int) -> Int {
        let inline = YAMLLine.entry(lines[start])?.value ?? ""
        let takesFlushItems = YAMLLine.isEmptyValue(inline)
        var end = start + 1
        var index = start + 1
        while index < frontmatterLines.upperBound {
            let line = lines[index]
            index += 1
            if YAMLLine.isBlankOrComment(line) { continue }
            let isIndented = line.first == " " || line.first == "\t"
            guard isIndented || (takesFlushItems && YAMLLine.isFlushItem(line)) else { break }
            end = index
        }
        return end
    }

    var frontmatterText: String {
        lines[frontmatterLines].joined(separator: "\n")
    }

    /// `type:` as js-yaml reads it: unquoted, a comment after it dropped.
    var type: String? {
        guard case .scalar(let type, _) = yamlValue("type"), !type.isEmpty else { return nil }
        return type
    }

    /// The anchors `variants` names: `weak-prf: "#weak-prfs"` gives
    /// "weak-prfs", as written; `headingAt` slugs it.
    var variantAnchors: [String] {
        guard let block = field("variants") else { return [] }
        return block.split(separator: "\n").dropFirst().compactMap { line -> String? in
            guard !YAMLLine.isBlankOrComment(line), let colon = line.firstIndex(of: ":"),
                  let value = YAMLLine.scalar(line[line.index(after: colon)...])?.value
            else { return nil }
            return value.hasPrefix("#") ? String(value.dropFirst()) : nil
        }
    }

    /// A top-level key's value as js-yaml reads the forms the wiki writes:
    /// a scalar, plain or quoted, a comment after it or not; a sequence of
    /// scalars, flow or block; a mapping of scalars one level deep.
    /// Anything else, a value over several lines included, is `.unread`,
    /// and compares with nothing.
    func yamlValue(_ key: String) -> YAMLValue {
        guard let start = keyLine(key), let entry = YAMLLine.entry(lines[start]) else { return .absent }
        let below = lines[(start + 1)..<fieldEnd(from: start)].filter { !YAMLLine.isBlankOrComment($0) }
        if YAMLLine.isEmptyValue(entry.value) {
            guard let first = below.first else { return .null }
            let item = first.drop { $0 == " " || $0 == "\t" }
            return item.hasPrefix("- ") || item == "-"
                ? YAMLLine.blockSequence(below) : YAMLLine.mapping(below)
        }
        guard below.isEmpty else { return .unread }
        if entry.value.hasPrefix("[") { return YAMLLine.flowSequence(entry.value) }
        guard let scalar = YAMLLine.scalar(entry.value) else { return .unread }
        if scalar.plain, YAMLLine.nulls.contains(scalar.value) { return .null }
        return .scalar(scalar.value, plain: scalar.plain)
    }

    /// Each heading's text as written, by the anchor the site gives it: the
    /// headings `WikiPage.headings()` finds, and the first of any repeated
    /// anchor, as the generator's `headingsByAnchor` keeps it.
    func headingsByAnchor() -> [String: String] {
        var slugger = GithubSlugger()
        var headings: [String: String] = [:]
        let inert = CodeMask.inertRanges(in: body)

        var lineStart = body.startIndex
        while lineStart < body.endIndex {
            // CRLF too: `"\r\n"` is one Character, never `"\n"`.
            let lineEnd = body[lineStart...].firstIndex(where: \.isMarkdownLineEnding)
                ?? body.endIndex
            defer {
                lineStart = lineEnd < body.endIndex ? body.index(after: lineEnd) : body.endIndex
            }
            guard let heading = WikiPage.atxHeading(body[lineStart..<lineEnd]),
                  !inert.contains(where: { $0.contains(lineStart) })
            else { continue }
            let plain = WikiPage.Heading.plainText(heading.text)
            guard !plain.isEmpty else { continue }
            let id = slugger.slug(plain)
            if headings[id] == nil { headings[id] = heading.text }
        }
        return headings
    }
}

/// The "Participates in" regions of a page body, found as lint.mjs's
/// `GEN_RE` finds them: each BEGIN marker with its checksum, lazily to the
/// next END marker.
private struct GeneratedRegions {

    struct Region {
        /// 0-based file lines, from the BEGIN marker's to the END marker's.
        let lines: ClosedRange<Int>
        /// UTF-16 offsets in the body, from the start of the BEGIN marker to
        /// the end of the END marker: lint.mjs's `generated` span.
        let span: Range<Int>
        /// The whole region, markers included.
        let text: String
        /// Its contents hash to the checksum its BEGIN marker declares.
        let isIntact: Bool
        /// Laid out as the generator writes it (`hasGeneratorShape`).
        let hasGeneratorShape: Bool
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

    func contains(utf16Offset offset: Int) -> Bool {
        regions.contains { $0.span.contains(offset) }
    }

    /// `${BEGIN} ${digest(inner)} -->\n\n${inner}\n\n${END}`, the contents
    /// trimmed by `trimEnd()` and starting with their heading
    /// (generate-relations.mjs 309–315, participates-in.mjs 155): a blank
    /// line after the BEGIN marker, one before the END marker, and no other
    /// whitespace at either end. The lint's checksum trims, so whitespace
    /// changed here passes the lint, and fails `generate-relations.mjs
    /// --check`, which compares bytes.
    static func hasGeneratorShape(_ inner: String) -> Bool {
        let scalars = Array(inner.unicodeScalars)
        let blank: [Unicode.Scalar] = ["\n", "\n"]
        guard scalars.count > 4, scalars.prefix(2).elementsEqual(blank),
              scalars.suffix(2).elementsEqual(blank)
        else { return false }
        return !DiffGuard.isECMAScriptSpace(scalars[2])
            && !DiffGuard.isECMAScriptSpace(scalars[scalars.count - 3])
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
                span: found.lowerBound.utf16Offset(in: body)..<endMarker.upperBound.utf16Offset(in: body),
                text: String(body[found.lowerBound..<endMarker.upperBound]),
                isIntact: DiffGuard.regionChecksum(inner) == declared,
                hasGeneratorShape: Self.hasGeneratorShape(inner)))
            from = endMarker.upperBound
        }
    }

    private static func isLowercaseHex(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value) || (0x61...0x66).contains(scalar.value)
    }
}

// MARK: - Frontmatter as js-yaml reads it

/// A top-level frontmatter value (`InspectedText.yamlValue`).
private enum YAMLValue: Equatable {
    case absent
    case null
    case scalar(String, plain: Bool)
    case sequence([String])
    case mapping([String: String])
    /// A form DiffGuard does not read.
    case unread
}

/// Frontmatter lines, read as js-yaml reads the forms the wiki writes,
/// for the rules that must agree with the lint and the generator:
/// `Frontmatter` keeps a quoted key's quotes.
private enum YAMLLine {

    /// Plain scalars js-yaml reads as null.
    static let nulls: Set<String> = ["", "~", "null", "Null", "NULL"]

    /// A top-level `key: value` line: the key, unquoted, and the value after
    /// the colon, trimmed. An indented line, a comment and a `- ` item are
    /// not one.
    static func entry(_ line: Substring) -> (key: String, value: Substring)? {
        guard let first = line.first, first != " ", first != "\t", first != "#", !isFlushItem(line)
        else { return nil }
        if first == "\"" || first == "'" {
            guard let close = line.dropFirst().firstIndex(of: first) else { return nil }
            let rest = line[line.index(after: close)...].drop { $0 == " " || $0 == "\t" }
            guard rest.first == ":" else { return nil }
            return (Frontmatter.unquote(String(line[...close])), trimmed(rest.dropFirst()))
        }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        return (String(trimmed(line[..<colon])), trimmed(line[line.index(after: colon)...]))
    }

    /// No value on the key's line, or only a comment.
    static func isEmptyValue(_ value: Substring) -> Bool {
        value.isEmpty || value.hasPrefix("#")
    }

    static func isBlankOrComment(_ line: Substring) -> Bool {
        let text = line.drop { $0 == " " || $0 == "\t" }
        return text.isEmpty || text.hasPrefix("#")
    }

    /// `- item` flush left, as `Frontmatter` reads one: the closing `---`
    /// never is.
    static func isFlushItem(_ line: Substring) -> Bool {
        line.hasPrefix("- ") || String(line).trimmedTrailing == "-"
    }

    /// A scalar, unquoted, and whether it was plain; nil for what DiffGuard
    /// does not read: a quote left open, a flow collection, a block scalar,
    /// an anchor, an alias or a tag, a mapping.
    static func scalar(_ text: Substring) -> (value: String, plain: Bool)? {
        let text = trimmed(text)
        if let quote = text.first, quote == "\"" || quote == "'" {
            guard let quoted = Frontmatter.quotedValue(String(text)) else { return nil }
            return (Frontmatter.unquote(quoted), false)
        }
        // A plain scalar ends where a comment starts: a `#` first, or after
        // a space or a tab.
        var end = text.endIndex
        var previous: Character = " "
        for index in text.indices {
            if text[index] == "#", previous == " " || previous == "\t" {
                end = index
                break
            }
            previous = text[index]
        }
        let value = trimmed(text[..<end])
        if let first = value.first, "[]{}&*!|>%@`".contains(first) { return nil }
        if value.contains(": ") || value.hasSuffix(":") { return nil }
        return (String(value), true)
    }

    /// `[a, "b, c"]`, with a comment after it or not.
    static func flowSequence(_ text: Substring) -> YAMLValue {
        var items: [String] = []
        var current = ""
        var quote: Character?
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            if let open = quote {
                current.append(character)
                if open == "\"", character == "\\", index < text.endIndex {
                    current.append(text[index])
                    index = text.index(after: index)
                } else if character == open {
                    quote = nil
                }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                current.append(character)
            case "[", "{":
                return .unread
            case ",", "]":
                let item = trimmed(Substring(current))
                current = ""
                if item.isEmpty {
                    // Only `[]`, or a comma before the `]`.
                    guard character == "]" else { return .unread }
                } else {
                    guard let read = Self.scalar(item), !(read.plain && nulls.contains(read.value))
                    else { return .unread }
                    items.append(read.value)
                }
                if character == "]" {
                    return isEmptyValue(trimmed(text[index...])) ? .sequence(items) : .unread
                }
            default:
                current.append(character)
            }
        }
        return .unread
    }

    /// `- item` lines at one indent, each a scalar.
    static func blockSequence(_ lines: [Substring]) -> YAMLValue {
        guard let indent = lines.first.map(indentation) else { return .null }
        var items: [String] = []
        for line in lines {
            guard indentation(line) == indent else { return .unread }
            let item = line.dropFirst(indent)
            guard item.hasPrefix("- ") || String(item).trimmedTrailing == "-",
                  let read = Self.scalar(item.dropFirst()), !(read.plain && nulls.contains(read.value))
            else { return .unread }
            items.append(read.value)
        }
        return .sequence(items)
    }

    /// `key: scalar` lines at one indent. A plain value js-yaml may read as
    /// other than a string is not read.
    static func mapping(_ lines: [Substring]) -> YAMLValue {
        guard let indent = lines.first.map(indentation) else { return .null }
        var entries: [String: String] = [:]
        for line in lines {
            guard indentation(line) == indent,
                  let parsed = Self.entry(line.dropFirst(indent)), entries[parsed.key] == nil,
                  let read = Self.scalar(parsed.value), !(read.plain && isTyped(read.value))
            else { return .unread }
            entries[parsed.key] = read.value
        }
        return .mapping(entries)
    }

    /// A null, a boolean, or what may be a number or a date.
    private static func isTyped(_ plain: String) -> Bool {
        guard let first = plain.first else { return true }
        return nulls.contains(plain) || ["true", "True", "TRUE", "false", "False", "FALSE"].contains(plain)
            || first.isNumber || first == "-" || first == "+" || first == "."
    }

    private static func indentation(_ line: Substring) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    private static func trimmed(_ text: Substring) -> Substring {
        var text = text.drop { $0 == " " || $0 == "\t" }
        while let last = text.last, last == " " || last == "\t" { text = text.dropLast() }
        return text
    }
}

// MARK: - What the generator wrote

/// The records `generate-relations.mjs` wrote to `relations.json` (its
/// lines 110–192), read as far as DiffGuard compares them with the pages
/// it wrote them from.
private struct WrittenManifest {
    typealias Record = [String: Any]

    let objects: [Record]
    let reductions: [Record]
    let barriers: [Record]

    init?(json: String) {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let objects = root["objects"] as? [Record],
              let reductions = root["reductions"] as? [Record],
              let barriers = root["barriers"] as? [Record]
        else { return nil }
        self.objects = objects
        self.reductions = reductions
        self.barriers = barriers
    }

    /// How the generator copies a frontmatter key into a record.
    enum Copy: Sendable {
        /// `fm.key`, or `fallback` when it is missing or null.
        case scalar(fallback: String?)
        /// `fm.key ?? []`, or `[].concat(fm.key ?? [])`.
        case list
        /// `fm.key === true`.
        case flag
    }

    /// A value as either side holds it.
    enum Copied: Equatable {
        case missing
        case text(String)
        case list([String])
        case flag(Bool)
        case mapping([String: String])
    }

    typealias Field = (key: String, record: String, copy: Copy)

    /// Lines 152–172; `rationale` is compared on its own.
    static let reductionFields: [Field] = [
        ("id", "id", .scalar(fallback: nil)),
        ("title", "title", .scalar(fallback: nil)),
        ("kind", "kind", .scalar(fallback: "implication")),
        ("hypotheses", "hypotheses", .list),
        ("conclusion", "conclusion", .scalar(fallback: nil)),
        ("class", "class", .scalar(fallback: "unstated")),
        ("model", "model", .scalar(fallback: "standard")),
        ("source", "source", .list),
        ("via", "via", .list),
        ("heuristic", "heuristic", .flag),
        ("security-loss", "securityLoss", .scalar(fallback: "")),
        ("status", "status", .scalar(fallback: nil)),
    ]

    /// Lines 173–190.
    static let barrierFields: [Field] = [
        ("id", "id", .scalar(fallback: nil)),
        ("title", "title", .scalar(fallback: nil)),
        ("hypotheses", "hypotheses", .list),
        ("conclusion", "conclusion", .scalar(fallback: nil)),
        ("class", "class", .scalar(fallback: "unstated")),
        ("consequences", "consequences", .list),
        ("strength", "strength", .scalar(fallback: nil)),
        ("conditional-on", "conditionalOn", .list),
        ("circumvented-by", "circumventedBy", .list),
        ("source", "source", .list),
        ("status", "status", .scalar(fallback: nil)),
    ]

    /// lint-edges.mjs `RATIONALE_FIELDS`: the `rationale` keys each type
    /// records, by the record field each explains.
    static let rationaleFields: [String: [(key: String, record: String)]] = [
        "reduction": [
            ("kind", "kind"), ("class", "class"), ("model", "model"), ("source", "source"),
            ("via", "via"), ("heuristic", "heuristic"), ("security-loss", "securityLoss"),
        ],
        "barrier": [
            ("class", "class"), ("strength", "strength"), ("conditional-on", "conditionalOn"),
            ("oracle", "oracle"), ("source", "source"),
        ],
    ]

    /// The `type:`s the generator writes an object for, case and all.
    static let objectTypes: Set<String> = [
        "primitive", "assumption", "complexity-class", "glossary", "folklore", "note",
    ]

    /// participates-in.mjs `MODEL_PAGES`.
    static let modelPages = ["rom": "rom", "generic-group": "ggm", "algebraic-group": "agm"]

    /// `[[slug#anchor|text]]`'s page part (participates-in.mjs 31).
    static let wikilinkTarget = try! NSRegularExpression(pattern: #"\[\[([^\]|#]*)"#)

    // MARK: A page and its records

    /// Whether the records written for this page agree with it as it is
    /// now. A value either side holds in a form DiffGuard does not read
    /// agrees with anything, so a page this says is out of date is.
    func matches(_ file: InspectedFile) -> Bool {
        let path = file.file.path
        if let oldPath = file.file.oldPath, oldPath != path, !records(on: oldPath).isEmpty { return false }
        let written = records(on: path)
        guard let page = file.new else { return written.isEmpty }

        if let type = page.type, type == "reduction" || type == "barrier" {
            let edges = type == "reduction" ? Self.on(reductions, path) : Self.on(barriers, path)
            let fields = type == "reduction" ? Self.reductionFields : Self.barrierFields
            guard written.count == 1, let record = edges.first else { return false }
            return fields.allSatisfy({ Self.agrees(page.yamlValue($0.key), $0.copy, record[$0.record]) })
                && Self.agreesRationale(page, type: type, record["rationale"])
        }
        guard let type = page.type, Self.objectTypes.contains(type) else { return written.isEmpty }
        return objectMatches(page, path: path, written: written)
    }

    /// Lines 110–143: the page's object, and its variants.
    private func objectMatches(_ page: InspectedText, path: String, written: [Record]) -> Bool {
        guard Self.on(reductions, path).isEmpty, Self.on(barriers, path).isEmpty else { return false }
        let objectRecords = written.filter { $0["kind"] as? String == "object" }
        let id = page.yamlValue("id")
        guard case .scalar(let pageID, _) = id, !pageID.isEmpty else {
            // No object without an id; its variants are not checked.
            if case .unread = id { return true }
            return objectRecords.isEmpty
        }
        let slug = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let fields: [Field] = [
            ("type", "type", .scalar(fallback: nil)),
            ("title", "title", .scalar(fallback: slug)),
            ("aliases", "aliases", .list),
            ("unlisted", "unlisted", .flag),
        ]
        guard objectRecords.count == 1, let record = objectRecords.first,
              Self.agrees(id, .scalar(fallback: nil), record["id"]),
              fields.allSatisfy({ Self.agrees(page.yamlValue($0.key), $0.copy, record[$0.record]) })
        else { return false }
        let variantRecords = written.filter { $0["kind"] as? String == "variant" }
        return variantsMatch(page, id: pageID, written: variantRecords)
    }

    /// Each variant's anchor, its page's id, and its title: the heading
    /// its anchor names, markdown removed (markdown-text.mjs 114–173). A
    /// heading with no markdown in it reads as written, its whitespace
    /// collapsed; another is not compared.
    private func variantsMatch(_ page: InspectedText, id: String, written: [Record]) -> Bool {
        let declared: [String: String]
        switch page.yamlValue("variants") {
        case .absent, .null: declared = [:]
        case .mapping(let entries): declared = entries
        case .scalar, .sequence, .unread: return true
        }
        guard written.count == declared.count,
              Set(written.compactMap { $0["id"] as? String }) == Set(declared.keys)
        else { return false }
        let headings = page.headingsByAnchor()
        return written.allSatisfy { record in
            guard let variant = record["id"] as? String, let anchor = declared[variant],
                  record["of"] as? String == id, record["anchor"] as? String == anchor
            else { return false }
            let slug = GithubSlugger.slug(anchor.hasPrefix("#") ? String(anchor.dropFirst()) : anchor)
            guard let heading = headings[slug],
                  heading.allSatisfy({ !"[]<>*_~`\\$".contains($0) })
            else { return true }
            let title = heading.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return record["title"] as? String == title
        }
    }

    private func records(on path: String) -> [Record] {
        Self.on(objects, path) + Self.on(reductions, path) + Self.on(barriers, path)
    }

    private static func on(_ records: [Record], _ path: String) -> [Record] {
        records.filter { $0["page"] as? String == path }
    }

    /// Nil from either side, a form not read, agrees.
    private static func agrees(_ value: YAMLValue, _ copy: Copy, _ written: Any?) -> Bool {
        guard let expected = expected(value, copy), let actual = actual(written, copy) else { return true }
        return expected == actual
    }

    /// What the generator writes for a frontmatter value.
    private static func expected(_ value: YAMLValue, _ copy: Copy) -> Copied? {
        switch copy {
        case .scalar(let fallback):
            switch value {
            case .absent, .null: return fallback.map(Copied.text) ?? .missing
            case .scalar(let text, _): return .text(text)
            case .sequence, .mapping, .unread: return nil
            }
        case .list:
            switch value {
            case .absent, .null: return .list([])
            case .scalar(let text, _): return .list([text])
            case .sequence(let items): return .list(items)
            case .mapping, .unread: return nil
            }
        case .flag:
            switch value {
            case .scalar(let text, let plain): return .flag(plain && ["true", "True", "TRUE"].contains(text))
            case .absent, .null, .sequence, .mapping: return .flag(false)
            case .unread: return nil
            }
        }
    }

    /// A record's value; nil for a form not compared, a number say.
    private static func actual(_ written: Any?, _ copy: Copy) -> Copied? {
        let value: Any? = written is NSNull ? nil : written
        switch copy {
        case .scalar:
            guard let value else { return .missing }
            return (value as? String).map(Copied.text)
        case .list:
            guard let value else { return .list([]) }
            if let text = value as? String { return .list([text]) }
            guard let array = value as? [Any] else { return nil }
            let texts = array.compactMap { $0 as? String }
            return texts.count == array.count ? .list(texts) : nil
        case .flag:
            return (value as? Bool).map(Copied.flag)
        }
    }

    /// lint-edges.mjs `rationaleRecord`: the type's keys whose value is
    /// text, trimmed, by the field each explains; no record when none is.
    private static func agreesRationale(_ page: InspectedText, type: String, _ written: Any?) -> Bool {
        let expected: Copied
        switch page.yamlValue("rationale") {
        case .mapping(let entries):
            var record: [String: String] = [:]
            for field in rationaleFields[type] ?? [] {
                let text = entries[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty { record[field.record] = text }
            }
            expected = record.isEmpty ? .missing : .mapping(record)
        case .absent, .null, .scalar, .sequence:
            expected = .missing
        case .unread:
            return true
        }
        guard let value = written, !(value is NSNull) else { return expected == .missing }
        guard let dictionary = value as? [String: Any] else { return true }
        var actual: [String: String] = [:]
        for (key, item) in dictionary {
            guard let text = item as? String else { return true }
            actual[key] = text
        }
        return expected == .mapping(actual)
    }

    // MARK: What changed since the base

    /// The pages of the records added, removed or changed since `base`,
    /// matched by id within each list: a changed record names its page on
    /// both sides. Without a base, every record is added.
    func changedPages(since base: WrittenManifest?) -> Set<String> {
        let lists: [(old: [Record], new: [Record])] = [
            (base?.objects ?? [], objects),
            (base?.reductions ?? [], reductions),
            (base?.barriers ?? [], barriers),
        ]
        var pages: Set<String> = []
        for (old, new) in lists {
            let before = Dictionary(grouping: old) { $0["id"] as? String }
            let after = Dictionary(grouping: new) { $0["id"] as? String }
            for id in Set(before.keys).union(after.keys) {
                let was = before[id] ?? []
                let now = after[id] ?? []
                guard !Self.same(was, now) else { continue }
                pages.formUnion((was + now).compactMap { $0["page"] as? String })
            }
        }
        return pages
    }

    /// The same records, value for value, compared as JSON with sorted
    /// keys. Records that do not serialize are not the same.
    private static func same(_ a: [Record], _ b: [Record]) -> Bool {
        guard let left = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
        else { return false }
        return left == right
    }

    // MARK: A region the generator writes

    /// Whether the generator writes a region on this page, and so
    /// `--check` fails without one: an object page, by its `type:` and
    /// `id`, that something relates to (generate-relations.mjs 320–336). It
    /// drops the region from one nothing relates to, and passes over a page
    /// that is not an object page.
    func expectsRegion(on page: InspectedText) -> Bool {
        guard let type = page.type, Self.objectTypes.contains(type) else { return false }
        switch page.yamlValue("id") {
        case .scalar(let id, _): return !id.isEmpty && hasRelations(id)
        case .unread: return true
        case .absent, .null, .sequence, .mapping: return false
        }
    }

    /// participates-in.mjs 91–131: an edge on the id or one of its
    /// variants, a reduction proved in the model its page defines, or one
    /// whose `via` links to its page.
    private func hasRelations(_ id: String) -> Bool {
        let variants = objects.filter { $0["kind"] as? String == "variant" && $0["of"] as? String == id }
        let ends = Set(variants.compactMap { $0["id"] as? String }).union([id])
        let meets = { (edge: Record) -> Bool in
            Self.strings(edge["hypotheses"]).contains(where: ends.contains)
                || (edge["conclusion"] as? String).map(ends.contains) == true
        }
        if reductions.contains(where: meets) || barriers.contains(where: meets) { return true }
        let inModel = reductions.contains { reduction in
            (reduction["model"] as? String).flatMap { model in Self.modelPages[model] } == id
        }
        if inModel { return true }
        let pages = pageIDsBySlug()
        return reductions.contains { reduction in
            Self.strings(reduction["via"]).contains { Self.linkedPage($0, in: pages) == id }
        }
    }

    /// Each object's slug, lowercased, then each alias no slug claims, to
    /// its id (participates-in.mjs 48–65).
    private func pageIDsBySlug() -> [String: String] {
        let pages = objects.filter { $0["kind"] as? String != "variant" }
        var ids: [String: String] = [:]
        for object in pages {
            guard let slug = object["slug"] as? String, let id = object["id"] as? String else { continue }
            ids[slug.lowercased()] = id
        }
        for object in pages {
            guard let id = object["id"] as? String else { continue }
            for alias in Self.strings(object["aliases"]) where ids[alias.lowercased()] == nil {
                ids[alias.lowercased()] = id
            }
        }
        return ids
    }

    /// The id of the page a wikilink names, by the last segment of its
    /// target (participates-in.mjs 66–69).
    private static func linkedPage(_ link: String, in ids: [String: String]) -> String? {
        let text = link as NSString
        guard let match = wikilinkTarget.firstMatch(in: link, range: NSRange(location: 0, length: text.length))
        else { return nil }
        let target = text.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let last = target.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? target
        return ids[last.lowercased()]
    }

    private static func strings(_ value: Any?) -> [String] {
        if let text = value as? String { return [text] }
        return (value as? [Any])?.compactMap { $0 as? String } ?? []
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
