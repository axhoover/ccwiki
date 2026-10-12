import Foundation
import Testing
@testable import CCwiki

/// The Rendered view of a change shows the blocks it changed, a block of
/// context either side, and a line for each run of unchanged ones
/// (plans/corrections.md §6.3). `CCwikiMarkdown.reviewEntries` decides
/// which, from §6.3's file payload, in JavaScriptCore as in the web view.
struct ReviewEntriesTests {

    /// One entry, as much of it as the review's layout reads.
    struct Entry: Equatable, CustomStringConvertible {
        let kind: String
        let side: String
        let lines: [Int]
        var text: String? = nil
        var note: String? = nil
        var flags = 0

        var description: String {
            "\(kind)\(lines)" + (text.map { "(\($0))" } ?? "") + (note.map { "{\($0)}" } ?? "")
                + (flags > 0 ? "!\(flags)" : "")
        }
    }

    private func entries(_ file: [String: Any]) throws -> [Entry] {
        let script = try MarkdownScript.load()
        let raw = try script.json("CCwikiMarkdown.reviewEntries(md, \(MarkdownScript.literal(file)))")
        let list = try #require(raw as? [[String: Any]])
        return try list.map { entry in
            Entry(
                kind: try #require(entry["kind"] as? String),
                side: try #require(entry["side"] as? String),
                lines: try #require(entry["lines"] as? [Int]),
                text: entry["text"] as? String,
                note: entry["note"] as? String,
                flags: (entry["flags"] as? [Any])?.count ?? 0)
        }
    }

    /// A §6.3 file: a Markdown page, modified, with no frontmatter.
    private func file(
        old: [String], new: [String], hunks: [([Int], [Int])],
        status: String = "modified", flags: [[String: Any]] = []
    ) -> [String: Any] {
        [
            "id": "f0",
            "path": "content/Primitives/x.md",
            "title": "X",
            "status": status,
            "summary": "",
            "isMarkdown": true,
            "header": "",
            "frontmatter": [Any](),
            "old": old.joined(separator: "\n"),
            "new": new.joined(separator: "\n"),
            "bodyLine": ["old": 8, "new": 8],
            "hunks": hunks.map { ["old": $0.0, "new": $0.1] },
            "flags": flags,
            "links": [String: Any](),
        ]
    }

    /// Seven paragraphs under a title: "# T", then "One." to "Six.", each
    /// with a blank line after it.
    static let page = ["# T", "", "One.", "", "Two.", "", "Three.", "", "Four.", "", "Five.", "", "Six."]

    @Test("a one-word change: removed and added, a block of context either side, gaps beyond")
    func oneWord() throws {
        var changed = Self.page
        changed[6] = "Three, changed."
        let found = try entries(file(old: Self.page, new: changed, hunks: [([6, 7], [6, 7])]))
        #expect(found.map(\.kind) == ["gap", "context", "removed", "added", "context", "gap"])
        #expect(found[0].text == "2 unchanged blocks")
        #expect(found[1].lines == [4, 5], "Two.")
        #expect(found[2].side == "old" && found[2].lines == [6, 7])
        #expect(found[3].side == "new" && found[3].lines == [6, 7])
        #expect(found[4].lines == [8, 9], "Four.")
        #expect(found[5].text == "2 unchanged blocks")
    }

    @Test("every entry carries a kind, an id and a side")
    func everyEntryHasAKind() throws {
        var changed = Self.page
        changed[2] = "One, changed."
        let script = try MarkdownScript.load()
        let payload = MarkdownScript.literal(file(old: Self.page, new: changed, hunks: [([2, 3], [2, 3])]))
        let raw = try script.json("CCwikiMarkdown.reviewEntries(md, \(payload))")
        let list = try #require(raw as? [[String: Any]])
        #expect(!list.isEmpty)
        for entry in list {
            let kind = entry["kind"] as? String
            #expect(["added", "removed", "context", "gap"].contains(kind ?? ""))
            #expect((entry["id"] as? String)?.hasPrefix("f0-") == true)
            #expect(["old", "new"].contains(entry["side"] as? String ?? ""))
        }
        // The rendered block, through the reader's own pipeline.
        let added = try #require(list.first { $0["kind"] as? String == "added" })
        #expect((added["html"] as? String)?.contains("One, changed.") == true)
        #expect(added["fileLines"] as? [Int] == [10, 10], "body line 2, with the body at line 8")
    }

    @Test("a pair that differs only in whitespace says so")
    func whitespaceOnly() throws {
        var changed = Self.page
        changed[8] = "Four.  "
        let found = try entries(file(old: Self.page, new: changed, hunks: [([8, 9], [8, 9])]))
        let pair = found.filter { $0.kind == "removed" || $0.kind == "added" }
        #expect(pair.count == 2)
        #expect(pair.allSatisfy { $0.note == "Whitespace only" })
    }

    @Test("a new file is all added, a deleted one all removed")
    func wholeFiles() throws {
        let added = try entries(file(
            old: [], new: ["# New", "", "Body."], hunks: [([0, 0], [0, 3])], status: "added"))
        #expect(added.map(\.kind) == ["added", "added"])

        let deleted = try entries(file(
            old: ["# Gone", "", "Text."], new: [], hunks: [([0, 3], [0, 0])], status: "deleted",
            flags: [["lines": [2, 3], "severity": "blocking", "text": "Restore the file."]]))
        #expect(deleted.map(\.kind) == ["removed", "removed"])
        #expect(deleted.map(\.flags) == [0, 1], "a deletion's flag is on its old lines")
    }

    @Test("a hunk of blank lines only is a gap that says to see Source")
    func blankLinesOnly() throws {
        let old = ["# T", "", "One.", "", "Two."]
        let new = ["# T", "", "One.", "", "", "Two."]
        let found = try entries(file(old: old, new: new, hunks: [([4, 4], [4, 5])]))
        let gaps = found.filter { $0.kind == "gap" }
        #expect(gaps.contains { $0.text == "Only blank lines changed here. See Source." })
        #expect(!found.contains { $0.kind == "added" || $0.kind == "removed" })
    }

    @Test("an insertion and a deletion of a whole block")
    func insertionAndDeletion() throws {
        let short = ["A.", "", "B.", "", "C.", "", "D.", "", "E."]
        let long = ["A.", "", "B.", "", "C.", "", "New.", "", "D.", "", "E."]
        let inserted = try entries(file(old: short, new: long, hunks: [([6, 6], [6, 8])]))
        #expect(inserted.map(\.kind) == ["gap", "context", "added", "context", "gap"])
        #expect(inserted[2].lines == [6, 7])

        let deleted = try entries(file(old: long, new: short, hunks: [([6, 8], [6, 6])]))
        #expect(deleted.map(\.kind) == ["gap", "context", "removed", "context", "gap"])
    }

    @Test("two hunks in one list are one change, shown once")
    func sharedBlock() throws {
        let old = ["- a", "- b", "- c", "", "Para."]
        let new = ["- a!", "- b", "- c!", "", "Para."]
        let found = try entries(file(old: old, new: new, hunks: [([0, 1], [0, 1]), ([2, 3], [2, 3])]))
        #expect(found.map(\.kind) == ["removed", "added", "context"])
    }

    @Test("a flag is on the first entry its lines meet")
    func flags() throws {
        var changed = Self.page
        changed[6] = "Three [[x]]."
        let flag: [String: Any] = ["lines": [6, 7], "severity": "warning", "text": "A warning."]
        let found = try entries(file(old: Self.page, new: changed, hunks: [([6, 7], [6, 7])], flags: [flag]))
        #expect(found.first { $0.kind == "added" }?.flags == 1)
        #expect(found.filter { $0.flags > 0 }.count == 1)
    }

    @Test("the frontmatter's rows: lines of the YAML with their signs, and gaps as captions")
    func frontmatterRows() throws {
        let script = try MarkdownScript.load()
        // As ReviewPayload sends them (§6.3), and a kind it never sends.
        let lines: [[String: Any]] = [
            ["kind": "context", "text": "type: primitive"],
            ["kind": "removed", "text": "status: draft"],
            ["kind": "added", "text": "status: complete"],
            ["kind": "gap", "text": "3 unchanged lines"],
            ["kind": "unknown", "text": "title: X"],
        ]
        let payload = MarkdownScript.literal(["lines": lines])
        let raw = try script.json("CCwikiMarkdown.reviewFrontmatter(\(payload).lines)")
        let rows = try #require(raw as? [[String: Any]])
        #expect(rows.map { $0["kind"] as? String } == ["context", "removed", "added", "gap", "context"])
        #expect(rows.map { $0["sign"] as? String } == [" ", "\u{2212}", "+", "", " "])
        #expect(rows.map { $0["text"] as? String }
            == ["type: primitive", "status: draft", "status: complete", "3 unchanged lines", "title: X"])

        let none = try script.json("CCwikiMarkdown.reviewFrontmatter(null)")
        #expect((none as? [Any])?.isEmpty == true)
    }

    @Test("a file that is not Markdown has no entries")
    func notMarkdown() throws {
        var json = file(old: ["{}"], new: ["{\"a\": 1}"], hunks: [([0, 1], [0, 1])])
        json["isMarkdown"] = false
        #expect(try entries(json).isEmpty)
    }
}
