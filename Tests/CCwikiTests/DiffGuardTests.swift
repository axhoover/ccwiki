import Foundation
import Testing
@testable import CCwiki

/// DiffGuard, rule by rule, firing and not (plans/corrections.md §6.2,
/// §12.1). The rules copied from the wiki's lint cite the `lint.mjs` lines
/// they follow, at the wiki's `ab81f02`.
struct DiffGuardTests {

    // MARK: Building snapshots

    static let pagePath = "content/Primitives/pseudorandom-function.md"

    static let target = CorrectionTarget(
        pagePath: "Primitives/pseudorandom-function.md", pageTitle: "Pseudorandom function",
        baseCommit: "ab81f02", section: nil, lines: nil, region: .body, quote: nil, excerpt: nil)

    /// A short object page. Its lines, 0-based: the frontmatter 0–5, the H1
    /// 7, the first paragraph 9, `## Security` 11, its paragraph 13,
    /// `# Other results` 15 and its one bullet 17.
    static let page = #"""
        ---
        type: primitive
        status: draft
        title: Pseudorandom function
        id: prf
        ---

        # Pseudorandom function

        A **PRF** is a keyed function that looks random.

        ## Security

        For every efficient $\calA$, the advantage is negligible.

        # Other results

        - [[prf-to-mac|PRF ⇒ MAC]]

        """#

    /// A reduction page: everything in its frontmatter feeds the generator.
    static let reduction = #"""
        ---
        type: reduction
        id: red-owf-to-prg-hill99
        kind: construction
        hypotheses:
          - owf
        conclusion: prg
        class: fully-black-box
        model: standard
        source: "[[HILL99]]"
        ---

        # OWF ⇒ PRG

        A construction.

        """#

    static func modified(_ path: String = DiffGuardTests.pagePath, old: String, new: String) -> ChangedFile {
        ChangedFile(
            path: path, oldPath: nil, status: .modified, isBinary: false, oldText: old, newText: new,
            hunks: LineDiff.hunks(old: old, new: new))
    }

    static func added(_ path: String, _ text: String) -> ChangedFile {
        ChangedFile(
            path: path, oldPath: nil, status: .added, isBinary: false, oldText: nil, newText: text,
            hunks: LineDiff.hunks(old: "", new: text))
    }

    static func deleted(_ path: String, _ text: String) -> ChangedFile {
        ChangedFile(
            path: path, oldPath: nil, status: .deleted, isBinary: false, oldText: text, newText: nil,
            hunks: LineDiff.hunks(old: text, new: ""))
    }

    static func renamed(from oldPath: String, to path: String, _ text: String) -> ChangedFile {
        ChangedFile(
            path: path, oldPath: oldPath, status: .renamed, isBinary: false, oldText: text, newText: text,
            hunks: [])
    }

    static func binary(_ path: String, _ status: ChangedFile.Status = .added) -> ChangedFile {
        ChangedFile(
            path: path, oldPath: nil, status: status, isBinary: true, oldText: nil, newText: nil, hunks: [])
    }

    static func check(
        _ files: [ChangedFile], kind: JobKind.Tag = .edit,
        target: CorrectionTarget? = DiffGuardTests.target,
        humanVerified: Set<String> = [], upstream: Set<String> = [], privatePaths: [String] = []
    ) -> [DiffFinding] {
        let snapshot = ReviewSnapshot(baseCommit: "ab81f02", files: files, digest: "")
        let context = DiffGuard.Context(
            kind: kind, humanVerifiedPaths: humanVerified, changedUpstream: upstream,
            target: target, privatePaths: privatePaths)
        return DiffGuard.check(snapshot, context: context)
    }

    /// An ingestion, which has no target page.
    static func ingest(_ files: [ChangedFile]) -> [DiffFinding] {
        check(files, kind: .ingestion, target: nil)
    }

    static func finding(_ rule: DiffFinding.Rule, in findings: [DiffFinding]) -> DiffFinding? {
        findings.first(where: { $0.rule == rule })
    }

    /// The short page with one passage replaced.
    static func edited(_ old: String, _ new: String, in text: String = DiffGuardTests.page) -> String {
        text.replacingOccurrences(of: old, with: new)
    }

    /// The short page's first paragraph, rewritten: its line 9, 1-based 10.
    static func withParagraph(_ paragraph: String) -> ChangedFile {
        modified(old: page, new: edited("A **PRF** is a keyed function that looks random.", paragraph))
    }

    static func fixture(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appending(path: "Fixtures/review/\(name)"),
            encoding: .utf8)
    }

    static let beginMarker = "<!-- BEGIN GENERATED participates-in 865206d47c53 -->"
    static let endMarker = "<!-- END GENERATED participates-in -->"

    /// The fixture page as `generate-relations.mjs` would leave it after a
    /// new reduction: one more bullet in its region, and the checksum to
    /// match.
    static func regenerated(_ page: String) throws -> String {
        let begin = try #require(page.range(of: beginMarker))
        let end = try #require(page.range(of: endMarker))
        let inner = String(page[begin.upperBound..<end.lowerBound]).replacingOccurrences(
            of: "- [[prp-to-prf|PRP ⇒ PRF]]\n",
            with: "- [[prp-to-prf|PRP ⇒ PRF]]\n- [[prp-to-sprp|PRP ⇒ SPRP]]\n")
        return String(page[..<begin.lowerBound])
            + "<!-- BEGIN GENERATED participates-in \(DiffGuard.regionChecksum(inner)) -->"
            + inner + String(page[end.lowerBound...])
    }

    /// The fixture page with its region cut out, markers and all: its
    /// lines 153–176, as a hand that took it for a copy of `# Other
    /// results` would leave it. The blank line before it stays.
    static func withoutRegion(_ page: String) throws -> String {
        let begin = try #require(page.range(of: beginMarker))
        let end = try #require(page.range(of: endMarker + "\n"))
        return String(page[..<begin.lowerBound]) + String(page[end.upperBound...])
    }

    /// A region as `generate-relations.mjs` writes one (its lines 309–315),
    /// its checksum right.
    static func region(_ inner: String) -> String {
        "<!-- BEGIN GENERATED participates-in \(DiffGuard.regionChecksum(inner)) -->\n\n"
            + inner + "\n\n" + endMarker
    }

    /// A page as the generator leaves it when a new reduction gives it its
    /// first region: `src.trimEnd() + "\n\n" + region + "\n"` (its line 329).
    static func withFirstRegion(_ page: String) -> String {
        var text = Substring(page)
        while text.last?.isWhitespace == true { text.removeLast() }
        return String(text) + "\n\n" + region("## Participates in\n\n**Builds on it**\n\n- [[a-to-b|A ⇒ B]]") + "\n"
    }

    // MARK: outsideContent

    @Test("outsideContent is an allow-list: scripts/, CLAUDE.md, a root lint.log, Templates and .claude/ block")
    func outsideContentBlocks() {
        for path in [
            "scripts/lint.mjs", "CLAUDE.md", "lint.log", "content/Templates/X.md",
            ".claude/skills/city-style/SKILL.md", "tsconfig.tsbuildinfo",
        ] {
            let finding = Self.finding(.outsideContent, in: Self.ingest([Self.added(path, "x\n")]))
            #expect(finding?.severity == .blocking, "\(path)")
            #expect(finding?.message == "CCwiki opens pull requests that change `content/` only. "
                + "Revert `\(path)`, or make this change outside CCwiki.", "\(path)")
            #expect(!DiffGuard.isPublishable(path), "\(path)")
        }
        // A rename from outside content/ brings a file in from outside.
        let moved = Self.ingest([Self.renamed(from: "notes/prf.md", to: Self.pagePath, Self.page)])
        #expect(Self.finding(.outsideContent, in: moved)?.message.contains("`notes/prf.md`") == true)
    }

    @Test("outsideContent allows a reference page with spaces and `&`, a root page, and relations.json")
    func outsideContentAllows() {
        for path in [
            "content/References/A - B.md", "content/References/Smith & Jones - A title.md",
            "content/impagliazzos-five-worlds.md", ".reductions/relations.json",
        ] {
            #expect(DiffGuard.isPublishable(path), "\(path)")
            #expect(Self.finding(.outsideContent, in: Self.ingest([Self.added(path, "x\n")])) == nil, "\(path)")
        }
    }

    // MARK: renamedOrDeleted

    @Test("renamedOrDeleted: a rename says revert it; a deletion says restore the file")
    func renamedOrDeleted() {
        let rename = Self.check([Self.renamed(from: "content/Primitives/prf.md", to: Self.pagePath, Self.page)])
        let renameFinding = Self.finding(.renamedOrDeleted, in: rename)
        #expect(renameFinding?.severity == .blocking)
        #expect(renameFinding?.message == "Filenames under `content/` are live URLs. Revert the rename.")

        let deletion = Self.finding(.renamedOrDeleted, in: Self.check([Self.deleted(Self.pagePath, Self.page)]))
        #expect(deletion?.severity == .blocking)
        #expect(deletion?.message == "Filenames under `content/` are live URLs. Restore the file.")

        let edit = Self.check([Self.withParagraph("A **PRF** is a keyed function that looks random to all.")])
        #expect(Self.finding(.renamedOrDeleted, in: edit) == nil)
    }

    @Test("renamedOrDeleted: deleting relations.json blocks in every kind, though it is publishable")
    func relationsDeleted() {
        let json = Self.deleted(".reductions/relations.json", "{\n  \"version\": 1\n}\n")
        for kind in [JobKind.Tag.edit, .correction, .ingestion] {
            let finding = Self.finding(.renamedOrDeleted, in: Self.check([json], kind: kind))
            #expect(finding?.severity == .blocking, "\(kind)")
            #expect(finding?.message == "`relations.json` is generated, and the site reads it. Restore the file.")
        }
        let changed = Self.modified(".reductions/relations.json", old: "{}\n", new: "{\"edges\": 1}\n")
        #expect(Self.finding(.renamedOrDeleted, in: Self.ingest([changed])) == nil)
    }

    // MARK: binaryFile

    @Test("binaryFile: a binary added or changed, and any PDF; not a binary removed, not a page")
    func binaryFile() {
        let png = Self.finding(.binaryFile, in: Self.ingest([Self.binary("content/figure.png")]))
        #expect(png?.severity == .blocking)
        #expect(png?.message == "PDFs and other binary files never enter the wiki.")
        #expect(Self.finding(.binaryFile, in: Self.ingest([Self.binary("content/figure.png", .modified)])) != nil)
        // git read this PDF as text; it is a PDF all the same.
        #expect(Self.finding(.binaryFile, in: Self.ingest([Self.added("content/References/paper.pdf", "%PDF-1.4\n")])) != nil)

        #expect(Self.finding(.binaryFile, in: Self.ingest([Self.binary("content/figure.png", .deleted)])) == nil)
        #expect(Self.finding(.binaryFile, in: Self.check([Self.withParagraph("A PRF.")])) == nil)
    }

    @Test("binaryFile: a page the snapshot could not read as text says so")
    func binaryPage() {
        for path in [Self.pagePath, ".reductions/relations.json"] {
            let finding = Self.finding(.binaryFile, in: Self.check([Self.binary(path, .modified)]))
            #expect(finding?.severity == .blocking, "\(path)")
            #expect(finding?.message == "CCwiki could not read this file as UTF-8 text, so it checked "
                + "nothing in it. Revert it, or save it as UTF-8.", "\(path)")
        }
    }

    // MARK: generatedRegionEdited and regionRegenerated (lint.mjs 1075–1109)

    @Test("the checksum is lint.mjs's: the real region in pseudorandom-function.md hashes to 865206d47c53")
    func checksumOfARealRegion() throws {
        // lint.mjs 1094–1099: sha256 of the region's trimmed contents, as
        // UTF-8, its first twelve hex digits.
        let page = try Self.fixture("pseudorandom-function.md")
        let begin = try #require(page.range(of: Self.beginMarker))
        let end = try #require(page.range(of: Self.endMarker))
        let inner = String(page[begin.upperBound..<end.lowerBound])
        #expect(DiffGuard.regionChecksum(inner) == "865206d47c53")
        // trim(): the whitespace at either end is not part of it.
        #expect(DiffGuard.regionChecksum("\n \u{00A0}" + inner + "\t\u{2028}") == "865206d47c53")
        #expect(DiffGuard.regionChecksum(inner + "x") != "865206d47c53")
    }

    @Test("an edit elsewhere on a real page finds nothing at all")
    func realPageEditedElsewhere() throws {
        let page = try Self.fixture("pseudorandom-function.md")
        let new = page.replacingOccurrences(
            of: "is negligible.\n\n# Variations", with: "is negligible in $\\secpar$.\n\n# Variations")
        #expect(new != page)
        #expect(Self.check([Self.modified(old: page, new: new)]).isEmpty)
    }

    @Test("a hand edit inside the region blocks, naming its lines and the lint's rule")
    func regionEditedByHand() throws {
        let page = try Self.fixture("pseudorandom-function.md")
        let new = page.replacingOccurrences(
            of: "- [[prp-to-prf|PRP ⇒ PRF]]", with: "- [[prp-to-prf|PRP implies PRF]]")
        #expect(new != page)
        let findings = Self.check([Self.modified(old: page, new: new)])
        let finding = try #require(Self.finding(.generatedRegionEdited, in: findings))
        #expect(finding.severity == .blocking)
        #expect(finding.lines == LineRange(first: 153, last: 176))
        #expect(finding.message == "The “Participates in” section on lines 153–176 was edited by hand. "
            + "It is rebuilt from the reduction pages; correct those instead. (lint: `generated-region-edited`)")
        #expect(Self.finding(.regionRegenerated, in: findings) == nil)
    }

    @Test("a region the script rewrote, its checksum matching, is a note and blocks nothing")
    func regionRegenerated() throws {
        let page = try Self.fixture("pseudorandom-function.md")
        let findings = Self.check([Self.modified(old: page, new: try Self.regenerated(page))])
        #expect(Self.finding(.generatedRegionEdited, in: findings) == nil)
        let note = try #require(Self.finding(.regionRegenerated, in: findings))
        #expect(note.severity == .note)
        #expect(note.lines == LineRange(first: 153, last: 177))
        #expect(note.message == "Regenerated by the script, not edited by hand.")
        // Its new bullets carry two wikilinks under # Other results, and its
        // marker is a comment: neither is the hand's.
        #expect(findings.map(\.rule) == [.regionRegenerated])
    }

    @Test("unbalanced markers block, citing generated-region")
    func regionUnbalanced() throws {
        let page = try Self.fixture("pseudorandom-function.md")
        let new = page.replacingOccurrences(of: Self.endMarker + "\n", with: "")
        #expect(new != page)
        let finding = try #require(Self.finding(.generatedRegionEdited, in: Self.check([Self.modified(old: page, new: new)])))
        #expect(finding.severity == .blocking)
        #expect(finding.lines == LineRange(first: 153, last: 153))
        #expect(finding.message.hasPrefix("The “Participates in” markers are unbalanced (1 BEGIN, 0 END)."))
        #expect(finding.message.hasSuffix("(lint: `generated-region`)"))
    }

    @Test("a region already broken at the base, and left as it was, is not this change's doing")
    func regionBrokenAtTheBase() throws {
        let page = try Self.fixture("pseudorandom-function.md").replacingOccurrences(
            of: "- [[prp-to-prf|PRP ⇒ PRF]]", with: "- [[prp-to-prf|PRP implies PRF]]")
        let new = page.replacingOccurrences(of: "TODO: define these", with: "TODO: define them")
        #expect(new != page)
        #expect(Self.finding(.generatedRegionEdited, in: Self.check([Self.modified(old: page, new: new)])) == nil)
    }

    @Test("a region removed by hand, markers and all, blocks: the generator would write it back")
    func regionRemovedByHand() throws {
        let page = try Self.fixture("pseudorandom-function.md")
        let file = Self.modified(old: page, new: try Self.withoutRegion(page))
        let findings = Self.check([file])
        // The counts are equal, 0 and 0, and no region is left to compare.
        #expect(findings.map(\.rule) == [.generatedRegionEdited])
        let finding = try #require(findings.first)
        #expect(finding.severity == .blocking)
        // Where it was: the page's last line now.
        #expect(finding.lines == LineRange(first: 152, last: 152))
        #expect(finding.message == "The “Participates in” section was removed by hand. It is rebuilt from "
            + "the reduction pages; restore it, and correct those instead.")

        // Its lines were the hand's, so they count: 18 that are not blank.
        let ingestion = Self.ingest([file])
        #expect(Self.finding(.generatedRegionEdited, in: ingestion)?.severity == .blocking)
        #expect(ingestion.filter { $0.rule == .ingestionScope }.map(\.message) == [
            "This changes 18 lines of `pseudorandom-function.md` by hand. "
                + "An ingestion normally changes at most five lines of an existing page.",
        ])
    }

    @Test("a region the generator dropped, with relations.json regenerated, is a note")
    func regionRemovedByTheScript() throws {
        let page = try Self.fixture("pseudorandom-function.md")
        let begin = try #require(page.range(of: Self.beginMarker))
        // The region goes, and the blank lines it leaves collapse
        // (generate-relations.mjs 330).
        let dropped = String(page[..<begin.lowerBound].dropLast())
        let files = [
            Self.modified(old: page, new: dropped),
            Self.modified(".reductions/relations.json", old: "{\n  \"edges\": [1]\n}\n", new: "{\n  \"edges\": []\n}\n"),
        ]
        for kind in [JobKind.Tag.edit, .ingestion] {
            let findings = Self.check(files, kind: kind, target: kind == .edit ? Self.target : nil)
            #expect(findings.map(\.rule) == [.regionRegenerated], "\(kind)")
            #expect(findings.first?.severity == .note, "\(kind)")
            #expect(findings.first?.message == "Removed by the script, not by hand: `relations.json` was regenerated too.")
        }

        // A deleted relations.json is no regeneration.
        let deleted = Self.deleted(".reductions/relations.json", "{\n  \"edges\": [1]\n}\n")
        let findings = Self.check([Self.modified(old: page, new: dropped), deleted])
        #expect(Set(findings.filter { $0.severity == .blocking }.map(\.rule)) == [.generatedRegionEdited, .renamedOrDeleted])
    }

    @Test("an edit job with a regenerated relations.json and matching checksums has no blocking finding; a correction's gets relationsJSONByHand")
    func regeneratedRelations() throws {
        let page = try Self.fixture("pseudorandom-function.md")
        let files = [
            Self.modified(old: page, new: try Self.regenerated(page)),
            Self.modified(
                ".reductions/relations.json", old: "{\n  \"edges\": []\n}\n",
                new: "{\n  \"edges\": [\"prp-to-sprp\"]\n}\n"),
        ]
        let edit = Self.check(files, kind: .edit)
        #expect(!edit.contains(where: { $0.severity == .blocking }))
        #expect(Self.finding(.regionRegenerated, in: edit) != nil)
        #expect(Self.finding(.relationsJSONByHand, in: edit) == nil)
        #expect(Self.finding(.derivedFilesStale, in: edit) == nil)

        let correction = Self.check(files, kind: .correction)
        #expect(!correction.contains(where: { $0.severity == .blocking }))
        let warning = try #require(Self.finding(.relationsJSONByHand, in: correction))
        #expect(warning.severity == .warning)
        #expect(warning.path == ".reductions/relations.json")
    }

    // MARK: relationFieldOnObjectPage (lint.mjs 95–104, 159–171, 500–511)

    @Test("relationFieldOnObjectPage: an object page gaining a relation field blocks, at the key's line")
    func relationField() throws {
        let new = Self.edited("id: prf\n", "id: prf\nhypotheses:\n  - owf\n")
        let finding = try #require(Self.finding(
            .relationFieldOnObjectPage, in: Self.check([Self.modified(old: Self.page, new: new)])))
        #expect(finding.severity == .blocking)
        #expect(finding.lines == LineRange(first: 6, last: 6))
        #expect(finding.message.hasSuffix("(lint: `object-relation-field`)"))
    }

    @Test("every key in lint.mjs's FORBIDDEN_ON_OBJECTS fires")
    func relationFieldKeys() {
        for key in [
            "implies", "implied-by", "implied_by", "reductions", "barriers", "separations",
            "from", "to", "between", "hypotheses", "conclusion",
        ] {
            let new = Self.edited("id: prf\n", "id: prf\n\(key): owf\n")
            #expect(Self.finding(.relationFieldOnObjectPage, in: Self.check([Self.modified(old: Self.page, new: new)])) != nil, "\(key)")
        }
    }

    @Test("relationFieldOnObjectPage: not on a reduction page, nor for a key already there")
    func relationFieldQuiet() {
        let reduction = Self.ingest([Self.added("content/Reductions/owf-to-prg-hill99.md", Self.reduction)])
        #expect(Self.finding(.relationFieldOnObjectPage, in: reduction) == nil)

        let before = Self.edited("id: prf\n", "id: prf\nfrom: owf\n")
        let after = Self.edited("looks random.", "looks random to all.", in: before)
        #expect(Self.finding(.relationFieldOnObjectPage, in: Self.check([Self.modified(old: before, new: after)])) == nil)
    }

    // MARK: wikilinkMath (lint.mjs 1238–1272; markdown-text.mjs 183–196)

    @Test("wikilinkMath: an added line with an unescaped $ in a wikilink blocks")
    func wikilinkMath() throws {
        let file = Self.withParagraph("A PRF looks random, as [[bilinear-map-assumptions#k-linear-assumption|$k$-Linear]] does.")
        let finding = try #require(Self.finding(.wikilinkMath, in: Self.check([file])))
        #expect(finding.severity == .blocking)
        #expect(finding.lines == LineRange(first: 10, last: 10))
        #expect(finding.message == "Math in a wikilink breaks the link on the site. "
            + "Write `[text $x$](slug)` instead. (lint: `wikilink-math`)")
        // An embed, and a lone dollar, are the same mistake.
        #expect(Self.finding(.wikilinkMath, in: Self.check([Self.withParagraph("See ![[figure|$x$]].")])) != nil)
        #expect(Self.finding(.wikilinkMath, in: Self.check([Self.withParagraph("See [[ind-cpa|IND$-CPA]].")])) != nil)
    }

    @Test("wikilinkMath: not an escaped $, a markdown link, inline code, a fence, or a line already there")
    func wikilinkMathQuiet() {
        for paragraph in [
            #"A PRF is unlike [[ind-cpa|IND\$-CPA]] here."#,
            "A PRF looks random, as [$k$-Linear](bilinear-map-assumptions) does.",
            "A PRF: `[[x|$y$]]` is the broken form.",
        ] {
            #expect(Self.finding(.wikilinkMath, in: Self.check([Self.withParagraph(paragraph)])) == nil, "\(paragraph)")
        }
        let fenced = Self.edited("## Security\n", "## Security\n\n```text\n[[x|$y$]]\n```\n")
        #expect(Self.finding(.wikilinkMath, in: Self.check([Self.modified(old: Self.page, new: fenced)])) == nil)

        // At the base already: a fix elsewhere on the page is not blocked by it.
        let before = Self.edited("looks random.", "looks random, as [[x|$y$]] does.")
        let after = Self.edited("is negligible.", "is negligible in the security parameter.", in: before)
        #expect(Self.finding(.wikilinkMath, in: Self.check([Self.modified(old: before, new: after)])) == nil)
    }

    @Test("wikilinkMath: inside a generated region the hand edit is the finding, not the link")
    func wikilinkMathInsideARegion() throws {
        let page = try Self.fixture("pseudorandom-function.md")
        let new = page.replacingOccurrences(of: "- [[prp-to-prf|PRP ⇒ PRF]]", with: "- [[prp-to-prf|$\\mathsf{PRP}$ ⇒ PRF]]")
        let findings = Self.check([Self.modified(old: page, new: new)])
        #expect(Self.finding(.generatedRegionEdited, in: findings) != nil)
        #expect(Self.finding(.wikilinkMath, in: findings) == nil)
    }

    // MARK: privateText

    @Test("privateText: an added line with a local path or a token blocks, in any text file")
    func privateText() throws {
        let worktrees = "/Users/alice/Library/Caches/CCwiki/worktrees"
        let file = Self.withParagraph("A PRF (see \(worktrees)/x/notes.md).")
        let finding = try #require(Self.finding(
            .privateText, in: Self.check([file], privatePaths: [worktrees, "/Users/alice"])))
        #expect(finding.severity == .blocking)
        #expect(finding.lines == LineRange(first: 10, last: 10))
        #expect(finding.message == "This line contains a local path or a token: `\(worktrees)`.")

        let token = "ghp_" + String(repeating: "A", count: 36)
        let json = Self.modified(
            ".reductions/relations.json", old: "{\n}\n", new: "{\n  \"token\": \"\(token)\"\n}\n")
        let tokenFinding = try #require(Self.finding(.privateText, in: Self.ingest([json])))
        #expect(tokenFinding.lines == LineRange(first: 2, last: 2))
        // The message shows where it is without repeating it.
        #expect(tokenFinding.message == "This line contains a local path or a token: `ghp_AAAA…`.")
        #expect(!tokenFinding.message.contains(token))
    }

    @Test("privateText: not for a path that was already on the page")
    func privateTextQuiet() {
        let before = Self.edited("looks random.", "looks random (/Users/alice/x).")
        let after = Self.edited("is negligible.", "is negligible, always.", in: before)
        #expect(Self.check([Self.modified(old: before, new: after)], privatePaths: ["/Users/alice"]).isEmpty)
    }

    // MARK: newObjectPage

    @Test("newObjectPage: a new page in each object directory warns; a new reference does not")
    func newObjectPage() {
        for directory in ["Primitives", "Assumptions", "Complexity", "Glossary", "Folklore"] {
            let finding = Self.finding(.newObjectPage, in: Self.ingest([Self.added("content/\(directory)/thing.md", "# Thing\n")]))
            #expect(finding?.severity == .warning, "\(directory)")
            #expect(finding?.message == "This creates an object page. The wiki asks for a human decision on new objects.")
        }
        #expect(Self.finding(.newObjectPage, in: Self.ingest([Self.added("content/References/Key - Title.md", "# Key\n")])) == nil)
        #expect(Self.finding(.newObjectPage, in: Self.check([Self.withParagraph("A PRF.")])) == nil)
    }

    // MARK: The family: otherPages, largeEdit, ingestionScope

    static let otherPage = DiffGuardTests.modified(
        "content/Primitives/one-way-function.md", old: "# OWF\n\nA function.\n",
        new: "# OWF\n\nA function that is hard to invert.\n")

    /// The short page with `count` lines added at its end.
    static func lengthened(by count: Int) -> ChangedFile {
        modified(old: page, new: page + (1...count).map { "Line \($0)." }.joined(separator: "\n") + "\n")
    }

    @Test("otherPages: an edit that also changes another page warns about that page alone")
    func otherPages() {
        let findings = Self.check([Self.withParagraph("A PRF looks random to all."), Self.otherPage])
        let others = findings.filter { $0.rule == .otherPages }
        #expect(others.map(\.path) == ["content/Primitives/one-way-function.md"])
        #expect(others.first?.severity == .warning)
        #expect(others.first?.message == "This also changes `one-way-function.md`, which is not the page you started from.")
    }

    @Test("largeEdit: more than twenty changed lines in all warns; twenty does not")
    func largeEdit() {
        let large = Self.finding(.largeEdit, in: Self.check([Self.lengthened(by: 21)]))
        #expect(large?.severity == .warning)
        #expect(large?.message == "This changes 21 lines. A correction is usually a line or two.")
        #expect(Self.finding(.largeEdit, in: Self.check([Self.lengthened(by: 20)])) == nil)
        #expect(Self.finding(.largeEdit, in: Self.check([Self.lengthened(by: 21)], kind: .correction)) != nil)
    }

    @Test("the family switches largeEdit and otherPages for ingestionScope")
    func familySwitch() {
        let files = [Self.lengthened(by: 25), Self.otherPage]
        for kind in [JobKind.Tag.edit, .correction] {
            let rules = Set(Self.check(files, kind: kind).map(\.rule))
            #expect(rules.contains(.largeEdit) && rules.contains(.otherPages), "\(kind)")
            #expect(!rules.contains(.ingestionScope), "\(kind)")
        }
        let rules = Set(Self.ingest(files).map(\.rule))
        #expect(rules.contains(.ingestionScope))
        #expect(!rules.contains(.largeEdit) && !rules.contains(.otherPages))
    }

    @Test("ingestionScope: two new pages outside References/, Reductions/ and Barriers/")
    func ingestionScopeNewPages() {
        let findings = Self.ingest([
            Self.added("content/Primitives/a.md", "# A\n"), Self.added("content/Glossary/b.md", "# B\n"),
        ])
        #expect(findings.filter { $0.rule == .ingestionScope }.map(\.message) == [
            "This adds two pages outside `References/`, `Reductions/` and `Barriers/`. "
                + "An ingestion normally adds a reference and its reductions.",
        ])
    }

    @Test("ingestionScope: two existing pages changed, and more than five lines on one")
    func ingestionScopeExistingPages() {
        let two = Self.ingest([Self.withParagraph("A PRF looks random to all."), Self.otherPage])
        #expect(two.filter { $0.rule == .ingestionScope }.map(\.message) == [
            "This changes two existing pages. An ingestion normally adds pages and touches at most one.",
        ])

        let six = Self.ingest([Self.lengthened(by: 6)])
        #expect(six.filter { $0.rule == .ingestionScope }.map(\.message) == [
            "This changes 6 lines of `pseudorandom-function.md` by hand. "
                + "An ingestion normally changes at most five lines of an existing page.",
        ])
        #expect(Self.finding(.ingestionScope, in: Self.ingest([Self.lengthened(by: 5)])) == nil)
    }

    @Test("ingestionScope: a normal ingestion, and lines the script regenerated, do not count")
    func ingestionScopeQuiet() throws {
        let normal = Self.ingest([
            Self.added("content/References/HILL99 - A pseudorandom generator.md", "# HILL99\n"),
            Self.added("content/Reductions/owf-to-prg-hill99.md", Self.reduction),
            Self.added("content/Barriers/no-prg.md", "# No PRG\n"),
            Self.withParagraph("A PRF looks random [[HILL99]]."),
        ])
        #expect(Self.finding(.ingestionScope, in: normal) == nil)

        let page = try Self.fixture("pseudorandom-function.md")
        let other = try Self.fixture("pseudorandom-function.md")
            .replacingOccurrences(of: "# Pseudorandom function\n", with: "# Pseudorandom function (copy)\n")
        let regenerated = Self.ingest([
            Self.modified(old: page, new: try Self.regenerated(page)),
            Self.modified("content/Primitives/prf-copy.md", old: other, new: try Self.regenerated(other)),
        ])
        #expect(Self.finding(.ingestionScope, in: regenerated) == nil)
    }

    @Test("ingestionScope: pages given their first region by the script, blank line and all, are not hand changes")
    func ingestionScopeFirstRegions() {
        let owf = "---\ntype: primitive\nid: owf\n---\n\n# OWF\n\nA function.\n"
        let prg = "---\ntype: primitive\nid: prg\n---\n\n# PRG\n\nA generator.\n"
        // trimEnd() drops trailing blank lines too.
        let crhf = "---\ntype: primitive\nid: crhf\n---\n\n# CRHF\n\nA hash function.\n\n\n"
        let findings = Self.ingest([
            Self.added("content/Reductions/owf-to-prg-hill99.md", Self.reduction),
            Self.modified("content/Primitives/collision-resistant-hash.md", old: crhf, new: Self.withFirstRegion(crhf)),
            Self.modified("content/Primitives/one-way-function.md", old: owf, new: Self.withFirstRegion(owf)),
            Self.modified("content/Primitives/pseudorandom-generator.md", old: prg, new: Self.withFirstRegion(prg)),
            Self.modified(".reductions/relations.json", old: "{}\n", new: "{\"edges\": 1}\n"),
        ])
        #expect(Self.finding(.ingestionScope, in: findings) == nil)
        #expect(findings.map(\.rule) == [.regionRegenerated, .regionRegenerated, .regionRegenerated])

        // A blank line is not a hand change in a correction either.
        let spaced = Self.modified(old: Self.page, new: Self.page + (1...20).map { "Line \($0).\n\n" }.joined())
        #expect(Self.finding(.largeEdit, in: Self.check([spaced])) == nil)
    }

    // MARK: proseRelationBullet

    @Test("proseRelationBullet: an added bullet with two wikilinks under # Other results warns")
    func proseBullet() throws {
        let new = Self.edited(
            "- [[prf-to-mac|PRF ⇒ MAC]]\n",
            "- [[prf-to-mac|PRF ⇒ MAC]]\n- [[owf-to-prg|OWF ⇒ PRG]] then [[prg-to-prf|PRG ⇒ PRF]]\n")
        let finding = try #require(Self.finding(.proseRelationBullet, in: Self.check([Self.modified(old: Self.page, new: new)])))
        #expect(finding.severity == .warning)
        #expect(finding.lines == LineRange(first: 19, last: 19))
        #expect(finding.message == "This adds a relationship as a prose bullet. Relationships are reduction pages.")
    }

    @Test("proseRelationBullet: under ## Known Results, at any depth below it")
    func proseBulletNested() {
        let old = "# Thing\n\n## Known Results\n\n### From OWF\n\n- [[a|A]]\n"
        let new = "# Thing\n\n## Known Results\n\n### From OWF\n\n- [[a|A]]\n1. [[owf|OWF]] gives [[prg|PRG]]\n"
        #expect(Self.finding(.proseRelationBullet, in: Self.check([Self.modified(old: old, new: new)])) != nil)
    }

    @Test("proseRelationBullet: not one wikilink, not a paragraph, not under another section")
    func proseBulletQuiet() {
        let one = Self.edited("- [[prf-to-mac|PRF ⇒ MAC]]\n", "- [[prf-to-mac|PRF ⇒ MAC]]\n- [[prf-to-ske|PRF ⇒ SKE]]\n")
        let paragraph = Self.edited("- [[prf-to-mac|PRF ⇒ MAC]]\n", "- [[prf-to-mac|PRF ⇒ MAC]]\n\nSee [[owf|OWF]] and [[prg|PRG]].\n")
        let elsewhere = Self.edited("is negligible.\n", "is negligible.\n\n- [[owf|OWF]] and [[prg|PRG]]\n")
        for new in [one, paragraph, elsewhere] {
            #expect(Self.finding(.proseRelationBullet, in: Self.check([Self.modified(old: Self.page, new: new)])) == nil)
        }
    }

    // MARK: derivedFilesStale

    @Test("derivedFilesStale: a reduction page's frontmatter, without relations.json, warns")
    func derivedFilesReduction() {
        let path = "content/Reductions/owf-to-prg-hill99.md"
        let changed = Self.reduction.replacingOccurrences(of: "class: fully-black-box", with: "class: semi-black-box")
        let stale = Self.finding(.derivedFilesStale, in: Self.ingest([Self.modified(path, old: Self.reduction, new: changed)]))
        #expect(stale?.severity == .warning)
        #expect(stale?.path == path)
        #expect(stale?.message.hasPrefix("The “Participates in” sections and `relations.json` are now out of date") == true)

        let json = Self.modified(".reductions/relations.json", old: "{}\n", new: "{\"edges\": 1}\n")
        #expect(Self.finding(.derivedFilesStale, in: Self.ingest([Self.modified(path, old: Self.reduction, new: changed), json])) == nil)

        let body = Self.reduction.replacingOccurrences(of: "A construction.", with: "A classic construction.")
        #expect(Self.finding(.derivedFilesStale, in: Self.ingest([Self.modified(path, old: Self.reduction, new: body)])) == nil)
    }

    @Test("derivedFilesStale: an object page's identity, its variants, or a heading they name")
    func derivedFilesObject() throws {
        let title = Self.edited("title: Pseudorandom function", "title: Pseudorandom functions")
        #expect(Self.finding(.derivedFilesStale, in: Self.check([Self.modified(old: Self.page, new: title)])) != nil)
        let status = Self.edited("status: draft", "status: stub")
        #expect(Self.finding(.derivedFilesStale, in: Self.check([Self.modified(old: Self.page, new: status)])) == nil)

        let page = try Self.fixture("pseudorandom-function.md")
        func stale(_ old: String, _ new: String) -> Bool {
            let changed = page.replacingOccurrences(of: old, with: new)
            return Self.finding(.derivedFilesStale, in: Self.check([Self.modified(old: page, new: changed)])) != nil
        }
        // `variants` names `#weak-prfs`.
        #expect(stale("## Weak PRFs\n", "## Weakly pseudorandom functions\n"))
        #expect(stale("  weak-prf: \"#weak-prfs\"\n", ""))
        #expect(!stale("## Puncturable PRFs\n", "## Puncturable pseudorandom functions\n"))

        // The variant's title is its heading's text: reworded under the same
        // anchor, or given math, it changes (generate-relations.mjs 107–108).
        #expect(stale("## Weak PRFs\n", "## Weak prfs\n"))
        #expect(stale("## Weak PRFs\n", "## Weak $PRFs$\n"))
        #expect(!stale("A **weak PRF** has the syntax of a PRF", "A **weak PRF** has the same syntax as a PRF"))
    }

    // MARK: humanVerified, statusComplete, changedUpstream

    @Test("humanVerified: a changed page a human verified warns; another does not")
    func humanVerified() {
        let file = Self.withParagraph("A PRF looks random to all.")
        let finding = Self.finding(.humanVerified, in: Self.check([file], humanVerified: [Self.pagePath]))
        #expect(finding?.severity == .warning)
        #expect(finding?.message == "A human verified this page. The wiki asks that a change to a claim here "
            + "also marks its queue entry stale; CCwiki does not edit that file.")
        #expect(Self.finding(.humanVerified, in: Self.check([file], humanVerified: ["content/Primitives/other.md"])) == nil)
    }

    @Test("statusComplete: status becoming complete warns, at its line; staying complete does not")
    func statusComplete() throws {
        let complete = Self.edited("status: draft", "status: complete")
        let finding = try #require(Self.finding(.statusComplete, in: Self.check([Self.modified(old: Self.page, new: complete)])))
        #expect(finding.severity == .warning)
        #expect(finding.lines == LineRange(first: 3, last: 3))

        let later = Self.edited("looks random.", "looks random to all.", in: complete)
        #expect(Self.finding(.statusComplete, in: Self.check([Self.modified(old: complete, new: later)])) == nil)
    }

    @Test("changedUpstream: a path also changed on main since the base warns")
    func changedUpstream() {
        let page = Self.finding(.changedUpstream, in: Self.check([Self.withParagraph("A PRF.")], upstream: [Self.pagePath]))
        #expect(page?.severity == .warning)
        #expect(page?.message == "This page changed on main after the job started. The pull request may conflict.")

        let json = Self.modified(".reductions/relations.json", old: "{}\n", new: "{\"edges\": 1}\n")
        let file = Self.finding(.changedUpstream, in: Self.check([json], upstream: [".reductions/relations.json"]))
        #expect(file?.message == "This file changed on main after the job started. The pull request may conflict.")

        #expect(Self.finding(.changedUpstream, in: Self.check([Self.withParagraph("A PRF.")], upstream: ["content/other.md"])) == nil)
    }

    // MARK: rawHTML

    @Test("rawHTML: a hidden span, a comment, an open tag and a closing one warn")
    func rawHTML() {
        for paragraph in [
            #"A PRF <span style="display:none">and a secret</span> looks random."#,
            "A PRF <!-- a note to self --> looks random.",
            #"<div align="center">"#,
            "A PRF looks random.</details>",
        ] {
            let finding = Self.finding(.rawHTML, in: Self.check([Self.withParagraph(paragraph)]))
            #expect(finding?.severity == .warning, "\(paragraph)")
            #expect(finding?.lines == LineRange(first: 10, last: 10), "\(paragraph)")
            #expect(finding?.message == "This adds raw HTML, which the Rendered view may hide. Check it in Source.")
        }
    }

    @Test("rawHTML: not the generated markers, math, code, an autolink, an escape, or prose with < and >")
    func rawHTMLQuiet() throws {
        for paragraph in [
            "A PRF: for $a <b$ and $c > d$ it holds.",
            "A PRF: $$x <y>$$ inline.",
            "A PRF: `<span>` is code.",
            "A PRF: see <https://example.com>.",
            "A PRF: if a < b and c > d, then so on.",
            #"A PRF: escaped \<span> is text."#,
        ] {
            #expect(Self.finding(.rawHTML, in: Self.check([Self.withParagraph(paragraph)])) == nil, "\(paragraph)")
        }
        let blocks = Self.edited(
            "## Security\n",
            "## Security\n\n$$\n\\langle a <x> b \\rangle\n$$\n\n```html\n<div>\n```\n")
        #expect(Self.finding(.rawHTML, in: Self.check([Self.modified(old: Self.page, new: blocks)])) == nil)

        let page = try Self.fixture("pseudorandom-function.md")
        #expect(Self.finding(.rawHTML, in: Self.check([Self.modified(old: page, new: try Self.regenerated(page))])) == nil)
    }

    // MARK: Order

    @Test("findings are sorted blocking first, then by path and line, and each id is unique")
    func ordering() {
        let findings = Self.ingest([
            Self.added("content/A.md", "# A\n\n<span>x</span>\n\n<b>y</b>\n"),
            Self.added("scripts/z.mjs", "x\n"),
            Self.modified(old: Self.page, new: Self.edited("status: draft", "status: complete")),
        ])
        #expect(findings.first?.rule == .outsideContent)
        let severities = findings.map(\.severity)
        #expect(severities == severities.sorted(by: >))
        let warnings = findings.filter { $0.severity == .warning }
        #expect(warnings.map(\.path) == warnings.map(\.path).sorted())
        #expect(warnings.filter { $0.rule == .rawHTML }.compactMap(\.lines?.first) == [3, 5])
        #expect(Set(findings.map(\.id)).count == findings.count)
    }
}
