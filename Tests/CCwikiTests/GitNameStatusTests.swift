import Foundation
import Testing
@testable import CCwiki

/// `git diff --cached -M --name-status -z` and `--numstat -z`, parsed, and
/// the snapshot assembled from them (plans/corrections.md §6.1, §12.1). The
/// fixtures are real git output; Fixtures/review/README.md says how they
/// were made.
struct GitNameStatusTests {

    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/review/\(name)"))
    }

    /// The renamed reference, with a space, `&` and a non-ASCII letter.
    static let renamed = "content/References/\u{C9}crit - Ref & Co.md"
    static let renamedFrom = "content/References/Old - Ref & Co.md"

    // MARK: --name-status -z

    @Test("real -z output: modified, deleted, added, and an R100 rename with both paths")
    func realNameStatus() throws {
        let entries = GitNameStatus.parse(nameStatusZ: try Self.fixture("name-status.z"))
        let expected: [GitNameStatus.Entry] = [
            .init(status: .modified, path: "content/Primitives/a.md", oldPath: nil),
            .init(status: .deleted, path: "content/Primitives/gone.md", oldPath: nil),
            .init(status: .added, path: "content/Primitives/new page.md", oldPath: nil),
            .init(status: .modified, path: "content/Primitives/nonl.md", oldPath: nil),
            .init(status: .renamed, path: Self.renamed, oldPath: Self.renamedFrom),
            .init(status: .modified, path: "content/img.bin", oldPath: nil),
            .init(status: .added, path: "content/new bin.png", oldPath: nil),
        ]
        #expect(entries == expected)
    }

    @Test("paths keep their spaces, `&` and non-ASCII letters, unquoted")
    func unquotedPaths() {
        let data = Data("A\0content/References/A & B - \u{1F510} \u{E9}t\u{E9}.md\0".utf8)
        #expect(GitNameStatus.parse(nameStatusZ: data) == [
            GitNameStatus.Entry(
                status: .added, path: "content/References/A & B - \u{1F510} \u{E9}t\u{E9}.md", oldPath: nil),
        ])
    }

    @Test("a partial rename score, a copy, a type change, and a truncated record")
    func otherStatuses() {
        let data = Data("R087\0content/a.md\0content/b.md\0C075\0content/c.md\0content/d.md\0T\0content/e.md\0M\0".utf8)
        let expected: [GitNameStatus.Entry] = [
            .init(status: .renamed, path: "content/b.md", oldPath: "content/a.md"),
            // A copy leaves its source in place: it adds a file.
            .init(status: .added, path: "content/d.md", oldPath: nil),
            // A type change is a change to the file.
            .init(status: .modified, path: "content/e.md", oldPath: nil),
        ]
        #expect(GitNameStatus.parse(nameStatusZ: data) == expected)
        #expect(GitNameStatus.parse(nameStatusZ: Data()).isEmpty)
    }

    // MARK: --numstat -z

    @Test("binary paths from real --numstat -z: `-\\t-\\t`, and not a rename's 0 0")
    func realNumstat() throws {
        let binary = GitNameStatus.binaryPaths(numstatZ: try Self.fixture("numstat.z"))
        #expect(binary == ["content/img.bin", "content/new bin.png"])
    }

    @Test("a binary rename reports its new path; the records after it still parse")
    func binaryRename() {
        let data = Data("-\t-\t\0old.pdf\0content/new.pdf\01\t1\tcontent/x.md\0-\t-\tcontent/y z.bin\0".utf8)
        #expect(GitNameStatus.binaryPaths(numstatZ: data) == ["content/new.pdf", "content/y z.bin"])
        // A tab in a path stays in the path.
        let tabbed = Data("-\t-\tcontent/odd\tname.bin\0".utf8)
        #expect(GitNameStatus.binaryPaths(numstatZ: tabbed) == ["content/odd\tname.bin"])
    }

    // MARK: The snapshot, end to end

    /// The scratch repository's files at the base, by path.
    static let oldTexts = [
        "content/Primitives/a.md": "line one\nline two\nline three\n",
        "content/Primitives/gone.md": "delete me\n",
        "content/Primitives/nonl.md": "no newline",
        renamedFrom: "Old ref body\nwith two lines\nand a third\nand a fourth\n",
    ]

    /// And in the index.
    static let newTexts = [
        "content/Primitives/a.md": "line one\nline 2\nline three\n",
        "content/Primitives/new page.md": "new file with spaces\n",
        "content/Primitives/nonl.md": "no newline\n",
        renamed: "Old ref body\nwith two lines\nand a third\nand a fourth\n",
    ]

    @Test("assemble: git's order, each side's text, hunks as the patch has them, binaries bare")
    func assemble() throws {
        let entries = GitNameStatus.parse(nameStatusZ: try Self.fixture("name-status.z"))
        let binary = GitNameStatus.binaryPaths(numstatZ: try Self.fixture("numstat.z"))
        let patch = try Self.fixture("staged.patch")
        let snapshot = ReviewSnapshot.assemble(
            base: "4b825dc", entries: entries, binary: binary, patch: patch,
            oldTexts: Self.oldTexts, newTexts: Self.newTexts)

        #expect(snapshot.baseCommit == "4b825dc")
        #expect(snapshot.digest == "d2f71b32c9b6f7ea8ca95e37347920bb23f3739dbd98ed4b790c62fbd5011c20")
        #expect(snapshot.files.map(\.path) == entries.map(\.path))
        #expect(!snapshot.isEmpty)

        let files = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.path, $0) })

        let modified = try #require(files["content/Primitives/a.md"])
        #expect(modified.hunks == [LineHunk(old: 1..<2, new: 1..<2)])
        #expect(modified.addedLines == 1 && modified.removedLines == 1)
        #expect(modified.isMarkdown)

        let deleted = try #require(files["content/Primitives/gone.md"])
        #expect(deleted.oldText == "delete me\n" && deleted.newText == nil)
        #expect(deleted.hunks == [LineHunk(old: 0..<1, new: 0..<0)])

        let added = try #require(files["content/Primitives/new page.md"])
        #expect(added.oldText == nil && added.newText == "new file with spaces\n")
        #expect(added.hunks == [LineHunk(old: 0..<0, new: 0..<1)])

        // "\ No newline at end of file": the patch changes line 1.
        let newline = try #require(files["content/Primitives/nonl.md"])
        #expect(newline.hunks == [LineHunk(old: 0..<1, new: 0..<1)])

        let rename = try #require(files[Self.renamed])
        #expect(rename.status == .renamed && rename.oldPath == Self.renamedFrom)
        #expect(rename.oldText != nil && rename.hunks.isEmpty)

        for path in ["content/img.bin", "content/new bin.png"] {
            let file = try #require(files[path])
            #expect(file.isBinary && file.oldText == nil && file.newText == nil && file.hunks.isEmpty)
            #expect(!file.isMarkdown)
        }
    }

    @Test("a text the snapshot could not read fails closed: a binary, never a file emptied")
    func unreadableText() throws {
        let entries: [GitNameStatus.Entry] = [
            .init(status: .modified, path: "content/Primitives/a.md", oldPath: nil),
            .init(status: .added, path: "content/Primitives/b.md", oldPath: nil),
            .init(status: .renamed, path: "content/Primitives/c.md", oldPath: "content/Primitives/old c.md"),
            .init(status: .deleted, path: "content/Primitives/d.md", oldPath: nil),
        ]
        // a.md's new text is missing (not UTF-8, say), and so is the old
        // text of c.md, by its path at the base.
        let snapshot = ReviewSnapshot.assemble(
            base: "4b825dc", entries: entries, binary: [], patch: Data("diff".utf8),
            oldTexts: ["content/Primitives/a.md": "line one\n", "content/Primitives/d.md": "gone\n"],
            newTexts: ["content/Primitives/b.md": "new\n", "content/Primitives/c.md": "moved\n"])
        let files = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.path, $0) })

        for path in ["content/Primitives/a.md", "content/Primitives/c.md"] {
            let file = try #require(files[path])
            #expect(file.isBinary && file.oldText == nil && file.newText == nil && file.hunks.isEmpty, "\(path)")
        }
        // A side that has no text to read is not missing: an added file's
        // old side, a deleted file's new one.
        #expect(files["content/Primitives/b.md"]?.isBinary == false)
        #expect(files["content/Primitives/d.md"]?.isBinary == false)

        // DiffGuard blocks what no rule could read.
        let context = DiffGuard.Context(
            kind: .edit, humanVerifiedPaths: [], changedUpstream: [], target: nil, privatePaths: [])
        let unread = DiffGuard.check(snapshot, context: context)
            .filter { $0.rule == .binaryFile }
        #expect(unread.map(\.path) == ["content/Primitives/a.md", "content/Primitives/c.md"])
        #expect(unread.allSatisfy { $0.severity == .blocking && $0.message.hasPrefix("CCwiki could not read") })
    }

    @Test("an empty change is an empty snapshot, digested all the same")
    func emptySnapshot() {
        let snapshot = ReviewSnapshot.assemble(
            base: "4b825dc", entries: [], binary: [], patch: Data(), oldTexts: [:], newTexts: [:])
        #expect(snapshot.isEmpty)
        #expect(snapshot.digest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
