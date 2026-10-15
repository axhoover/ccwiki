import Foundation
import Testing
@testable import CCwiki

/// The review's Source mode, as rows (plans/corrections.md §6.3): each hunk
/// with three unchanged lines either side, the runs between as gaps, both
/// line numbers in the gutter, and a changed pair emphasised word by word.
///
/// The snapshots are built by hand, hunks included, so these tests read the
/// rows alone and not `LineDiff`.
struct SourceDiffTests {

    // MARK: Fixtures

    static let path = "content/Primitives/pseudorandom-function.md"

    /// "line 1" to "line `count`", each ending in a newline.
    static func numbered(_ count: Int, replacing changes: [Int: String] = [:]) -> String {
        (1...count).map { changes[$0] ?? "line \($0)" }.joined(separator: "\n") + "\n"
    }

    static func file(
        status: ChangedFile.Status = .modified, old: String?, new: String?, hunks: [LineHunk],
        isBinary: Bool = false
    ) -> ChangedFile {
        ChangedFile(
            path: path, oldPath: nil, status: status, isBinary: isBinary,
            oldText: old, newText: new, hunks: hunks)
    }

    static func hunk(_ old: Range<Int>, _ new: Range<Int>) -> LineHunk {
        LineHunk(old: old, new: new)
    }

    /// A row, as the tests read it: its kind, its two line numbers, its text.
    struct Shape: Equatable, CustomStringConvertible {
        let kind: SourceDiff.Row.Kind
        let old: Int?
        let new: Int?
        let text: String

        var description: String { "\(kind) \(old.map(String.init) ?? "-") \(new.map(String.init) ?? "-") \(text)" }
    }

    static func shapes(_ rows: [SourceDiff.Row]) -> [Shape] {
        rows.map { Shape(kind: $0.kind, old: $0.oldLine, new: $0.newLine, text: $0.text) }
    }

    static func context(_ line: Int, _ new: Int? = nil) -> Shape {
        Shape(kind: .context, old: line, new: new ?? line, text: "line \(line)")
    }

    // MARK: Hunks and context

    @Test("a hunk shows three unchanged lines either side, and the rest as gaps")
    func oneChangedLine() {
        let changed = Self.file(
            old: Self.numbered(20), new: Self.numbered(20, replacing: [10: "line 10 changed"]),
            hunks: [Self.hunk(9..<10, 9..<10)])
        let rows = SourceDiff.rows(for: changed)

        #expect(Self.shapes(rows) == [
            Shape(kind: .gap(6), old: nil, new: nil, text: ""),
            Self.context(7), Self.context(8), Self.context(9),
            Shape(kind: .removed, old: 10, new: nil, text: "line 10"),
            Shape(kind: .added, old: nil, new: 10, text: "line 10 changed"),
            Self.context(11), Self.context(12), Self.context(13),
            Shape(kind: .gap(7), old: nil, new: nil, text: ""),
        ])
        // Every row is told apart, for the scroll to a finding.
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test("both gutters follow an insertion: the new numbers run ahead of the old")
    func insertionShiftsNumbers() {
        let old = Self.numbered(8)
        let new = old.replacingOccurrences(of: "line 4\n", with: "line 4\nadded\n")
        let rows = SourceDiff.rows(for: Self.file(
            old: old, new: new, hunks: [Self.hunk(4..<4, 4..<5)]))

        #expect(Self.shapes(rows) == [
            Shape(kind: .gap(1), old: nil, new: nil, text: ""),
            Self.context(2), Self.context(3), Self.context(4),
            Shape(kind: .added, old: nil, new: 5, text: "added"),
            Self.context(5, 6), Self.context(6, 7), Self.context(7, 8),
            Shape(kind: .gap(1), old: nil, new: nil, text: ""),
        ])
    }

    @Test("two hunks seven lines apart share their context; eight apart, a gap comes between")
    func nearbyHunks() {
        // Seven unchanged lines between the two changes: all shown, since a
        // gap would take as much room as what it hides.
        let near = Self.file(
            old: Self.numbered(30),
            new: Self.numbered(30, replacing: [5: "five", 13: "thirteen"]),
            hunks: [Self.hunk(4..<5, 4..<5), Self.hunk(12..<13, 12..<13)])
        #expect(Self.shapes(SourceDiff.rows(for: near)) == [
            Shape(kind: .gap(1), old: nil, new: nil, text: ""),
            Self.context(2), Self.context(3), Self.context(4),
            Shape(kind: .removed, old: 5, new: nil, text: "line 5"),
            Shape(kind: .added, old: nil, new: 5, text: "five"),
        ] + (6...12).map { Self.context($0) } + [
            Shape(kind: .removed, old: 13, new: nil, text: "line 13"),
            Shape(kind: .added, old: nil, new: 13, text: "thirteen"),
            Self.context(14), Self.context(15), Self.context(16),
            Shape(kind: .gap(14), old: nil, new: nil, text: ""),
        ])

        // Eight: three after the first, a gap of two, three before the second.
        let far = Self.file(
            old: Self.numbered(30),
            new: Self.numbered(30, replacing: [5: "five", 14: "fourteen"]),
            hunks: [Self.hunk(4..<5, 4..<5), Self.hunk(13..<14, 13..<14)])
        #expect(Self.shapes(SourceDiff.rows(for: far)) == [
            Shape(kind: .gap(1), old: nil, new: nil, text: ""),
            Self.context(2), Self.context(3), Self.context(4),
            Shape(kind: .removed, old: 5, new: nil, text: "line 5"),
            Shape(kind: .added, old: nil, new: 5, text: "five"),
            Self.context(6), Self.context(7), Self.context(8),
            Shape(kind: .gap(2), old: nil, new: nil, text: ""),
            Self.context(11), Self.context(12), Self.context(13),
            Shape(kind: .removed, old: 14, new: nil, text: "line 14"),
            Shape(kind: .added, old: nil, new: 14, text: "fourteen"),
            Self.context(15), Self.context(16), Self.context(17),
            Shape(kind: .gap(13), old: nil, new: nil, text: ""),
        ])
    }

    @Test("a change at the very start or end has no gap on that side")
    func edges() {
        let rows = SourceDiff.rows(for: Self.file(
            old: Self.numbered(3), new: Self.numbered(3, replacing: [1: "first", 3: "last"]),
            hunks: [Self.hunk(0..<1, 0..<1), Self.hunk(2..<3, 2..<3)]))
        #expect(Self.shapes(rows) == [
            Shape(kind: .removed, old: 1, new: nil, text: "line 1"),
            Shape(kind: .added, old: nil, new: 1, text: "first"),
            Self.context(2),
            Shape(kind: .removed, old: 3, new: nil, text: "line 3"),
            Shape(kind: .added, old: nil, new: 3, text: "last"),
        ])
    }

    @Test("a deleted file is all removed lines, numbered on the old side only")
    func deletedFile() {
        let rows = SourceDiff.rows(for: Self.file(
            status: .deleted, old: "a\nb\nc\n", new: nil, hunks: [Self.hunk(0..<3, 0..<0)]))
        #expect(Self.shapes(rows) == [
            Shape(kind: .removed, old: 1, new: nil, text: "a"),
            Shape(kind: .removed, old: 2, new: nil, text: "b"),
            Shape(kind: .removed, old: 3, new: nil, text: "c"),
        ])
    }

    @Test("line breaks are not part of a line, \\r\\n included, and a last line without one counts")
    func lineBreaks() {
        #expect(SourceDiff.lines(of: "a\r\nb\nc") == ["a", "b", "c"])
        #expect(SourceDiff.lines(of: "") == [])
        #expect(SourceDiff.lines(of: "\n") == [""])
    }

    @Test("a binary file and a file with no hunks have no rows")
    func noRows() {
        let binary = SourceDiff.file(Self.file(
            old: nil, new: nil, hunks: [Self.hunk(0..<0, 0..<1)], isBinary: true))
        #expect(binary.rows.isEmpty)
        let untouched = SourceDiff.rows(for: Self.file(old: "a\n", new: "a\n", hunks: []))
        #expect(untouched.isEmpty)
    }

    // MARK: Words

    @Test("a changed pair emphasises the words that changed, and only those")
    func changedPair() throws {
        let rows = SourceDiff.rows(for: Self.file(
            old: "A PRF is secure.\n", new: "A PRF is pseudorandom.\n",
            hunks: [Self.hunk(0..<1, 0..<1)]))
        let removed = try #require(rows.first { $0.kind == .removed })
        let added = try #require(rows.first { $0.kind == .added })
        #expect(removed.pieces.filter(\.isChanged).map(\.text) == ["secure."])
        #expect(added.pieces.filter(\.isChanged).map(\.text) == ["pseudorandom."])
        // The pieces put back together are the lines.
        #expect(removed.pieces.map(\.text).joined() == removed.text)
        #expect(added.pieces.map(\.text).joined() == added.text)
    }

    @Test("a formula that changed is one emphasised piece, not a stray letter")
    func formulaPair() throws {
        let rows = SourceDiff.rows(for: Self.file(
            old: "Let $x + y$ be fixed.\n", new: "Let $x + z$ be fixed.\n",
            hunks: [Self.hunk(0..<1, 0..<1)]))
        let added = try #require(rows.first { $0.kind == .added })
        #expect(added.pieces.filter(\.isChanged).map(\.text) == ["$x + z$"])
    }

    @Test("a pair with no word in common, and an unpaired line, are not emphasised")
    func nothingInCommon() {
        let rows = SourceDiff.rows(for: Self.file(
            old: "alpha beta\n", new: "gamma delta\nepsilon\n",
            hunks: [Self.hunk(0..<1, 0..<2)]))
        #expect(rows.allSatisfy { $0.pieces.allSatisfy { !$0.isChanged } })
        #expect(rows.map(\.text) == ["alpha beta", "gamma delta", "epsilon"])
    }

    // MARK: Findings and files

    @Test("a finding scrolls to the row holding its first line, else the nearest")
    func findingRow() throws {
        let file = SourceDiff.file(Self.file(
            old: Self.numbered(20), new: Self.numbered(20, replacing: [10: "ten"]),
            hunks: [Self.hunk(9..<10, 9..<10)]))
        let added = try #require(file.rows.first { $0.kind == .added })
        #expect(SourceDiff.rowID(forLines: LineRange(first: 10, last: 10), in: file) == added.id)
        let last = try #require(file.rows.last { $0.newLine != nil })
        #expect(last.newLine == 13)
        #expect(SourceDiff.rowID(forLines: LineRange(first: 18, last: 19), in: file) == last.id)
        #expect(SourceDiff.rowID(forLines: nil, in: file) == nil)

        // A deleted file's findings are on its old lines.
        let deleted = SourceDiff.file(Self.file(
            status: .deleted, old: "a\nb\n", new: nil, hunks: [Self.hunk(0..<2, 0..<0)]))
        #expect(SourceDiff.rowID(forLines: LineRange(first: 2, last: 2), in: deleted)
            == deleted.rows[1].id)
    }

    @Test("a file of more than 400 changed lines waits behind Show; the gutter fits its numbers")
    func largeFile() {
        let lines = 401
        let large = SourceDiff.file(Self.file(
            status: .added, old: nil, new: Self.numbered(lines), hunks: [Self.hunk(0..<0, 0..<lines)]))
        #expect(large.isLarge)
        #expect(large.added == lines)
        #expect(large.gutterTemplate == "888")
        let small = SourceDiff.file(Self.file(
            status: .added, old: nil, new: Self.numbered(400), hunks: [Self.hunk(0..<0, 0..<400)]))
        #expect(!small.isLarge)
    }

    @Test("the rows are rebuilt when the snapshot's digest or its files change")
    func key() {
        let one = ReviewSnapshot(baseCommit: "a", tree: "t", files: [Self.file(old: "a\n", new: "b\n", hunks: [])], digest: "1")
        let same = ReviewSnapshot(baseCommit: "a", tree: "t", files: [Self.file(old: "a\n", new: "b\n", hunks: [])], digest: "1")
        let other = ReviewSnapshot(baseCommit: "a", tree: "t", files: [], digest: "1")
        #expect(SourceDiff.Key(one) == SourceDiff.Key(same))
        #expect(SourceDiff.Key(one) != SourceDiff.Key(other))
    }
}
