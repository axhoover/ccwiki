import Foundation
import Testing
@testable import CCwiki

/// The library on disk, in a temporary directory. Remove From Library goes to
/// a stand-in Trash, so running the tests never fills the real one.
struct PaperStoreTests {

    private struct Scratch {
        let root: URL
        let store: PaperStore
        let trash: URL

        init() throws {
            root = try PaperFixtures.temporaryDirectory("papers")
            let trash = root.appending(path: "Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            self.trash = trash
            store = PaperStore(directory: root.appending(path: "papers")) { file in
                try FileManager.default.moveItem(
                    at: file, to: trash.appending(path: file.lastPathComponent))
            }
        }

        /// A file standing in for a download or a PDF you chose.
        func file(_ contents: String) throws -> URL {
            let url = root.appending(path: "incoming-\(UUID().uuidString).pdf")
            try Data(contents.utf8).write(to: url)
            return url
        }

        func contents(of record: PaperRecord) throws -> String {
            try String(contentsOf: store.fileURL(for: record), encoding: .utf8)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private let eprint = URL(string: "https://eprint.iacr.org/2002/022.pdf")!

    private func source(_ key: String, title: String = "A Paper") -> PaperSource {
        PaperSource(page: PaperFixtures.reference(
            key, source: "https://eprint.iacr.org/2002/022", title: title))
    }

    @Test("a download is kept once, under its key, and recorded")
    func keptOnce() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let aabn = source("AABN02")
        let download = try scratch.file("%PDF-1.4 first")

        let record = try scratch.store.keep(download, for: aabn, origin: .downloaded(from: eprint))
        #expect(record.fileName == "AABN02.pdf")
        #expect(record.referencePath == aabn.referencePath)
        #expect(record.origin == .downloaded(from: eprint))
        #expect(record.bytes == 14)
        #expect(try scratch.contents(of: record) == "%PDF-1.4 first")
        #expect(!FileManager.default.fileExists(atPath: download.path(percentEncoded: false)),
                "a download's temporary file is moved in, not copied")

        let files = try FileManager.default.contentsOfDirectory(
            atPath: scratch.store.directory.path(percentEncoded: false))
        #expect(files.sorted() == ["AABN02.pdf", "papers.json"], "no staging file is left behind")
    }

    @Test("the index round-trips through papers.json")
    func indexRoundTrips() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let first = try scratch.store.keep(
            try scratch.file("%PDF one"), for: source("AABN02"), origin: .downloaded(from: eprint))
        let second = try scratch.store.keep(
            try scratch.file("%PDF two"), for: source("BGI15"), origin: .addedByYou)

        // A fresh store reads what the first wrote.
        let reopened = PaperStore(directory: scratch.store.directory)
        #expect(reopened.record(for: first.referencePath) == first)
        #expect(reopened.record(for: second.referencePath) == second)
        #expect(reopened.records().count == 2)
        #expect(reopened.record(for: "References/Nothing.md") == nil)
    }

    @Test("a record whose file is gone counts as not downloaded")
    func missingFile() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let record = try scratch.store.keep(
            try scratch.file("%PDF"), for: source("AABN02"), origin: .downloaded(from: eprint))
        try FileManager.default.removeItem(at: scratch.store.fileURL(for: record))

        #expect(scratch.store.record(for: record.referencePath) == nil)
        #expect(scratch.store.records()[record.referencePath] == record, "the record itself stays")
    }

    @Test("a PDF you add is copied, and replaces the reference's own file, which goes to the Trash")
    func adoptReplaces() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let aabn = source("AABN02")
        let downloaded = try scratch.store.keep(
            try scratch.file("%PDF downloaded"), for: aabn, origin: .downloaded(from: eprint))

        let yours = try scratch.file("%PDF yours")
        let added = try scratch.store.keep(yours, for: aabn, origin: .addedByYou)
        #expect(added.fileName == downloaded.fileName, "the reference keeps its file name")
        #expect(added.origin == .addedByYou)
        #expect(try scratch.contents(of: added) == "%PDF yours")
        #expect(FileManager.default.fileExists(atPath: yours.path(percentEncoded: false)),
                "your own copy stays where it was")
        #expect(scratch.store.records().count == 1)

        // The paper replaced can be put back, like one removed.
        let replaced = scratch.trash.appending(path: downloaded.fileName)
        #expect(try String(contentsOf: replaced, encoding: .utf8) == "%PDF downloaded")
    }

    @Test("remove moves the file to the Trash and drops the record")
    func removeToTrash() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let record = try scratch.store.keep(
            try scratch.file("%PDF"), for: source("AABN02"), origin: .addedByYou)

        try scratch.store.remove(record.referencePath)
        #expect(scratch.store.record(for: record.referencePath) == nil)
        #expect(scratch.store.records().isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: scratch.trash.appending(path: "AABN02.pdf").path(percentEncoded: false)))

        // Removing what is not there is nothing to do.
        try scratch.store.remove(record.referencePath)
    }

    @Test("keys that differ only in case get two files, and neither is replaced")
    func caseInsensitiveNames() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let upper = source("SW25", title: "Binary Codes")
        let lower = source("sw25", title: "Detecting Errors")

        let added = try scratch.store.keep(try scratch.file("%PDF yours"), for: upper, origin: .addedByYou)
        let fetched = try scratch.store.keep(
            try scratch.file("%PDF fetched"), for: lower, origin: .downloaded(from: eprint))

        #expect(added.fileName == "SW25.pdf")
        #expect(fetched.fileName == "sw25-2.pdf")
        #expect(try scratch.contents(of: added) == "%PDF yours")
        #expect(try scratch.contents(of: fetched) == "%PDF fetched")

        // Fetching the second again replaces only its own file.
        let again = try scratch.store.keep(
            try scratch.file("%PDF again"), for: lower, origin: .downloaded(from: eprint))
        #expect(again.fileName == "sw25-2.pdf")
        #expect(try scratch.contents(of: added) == "%PDF yours")
        #expect(try scratch.contents(of: again) == "%PDF again")
    }

    @Test("an index this version cannot read is set aside, never written over")
    func unreadableIndex() throws {
        // Damaged or edited by hand, and written by a newer CCwiki.
        for contents in ["not an index", #"{"version": 2, "papers": []}"#] {
            let scratch = try Scratch()
            defer { scratch.remove() }
            let directory = scratch.store.directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: scratch.store.indexURL)
            #expect(scratch.store.records().isEmpty, "read as empty")

            let record = try scratch.store.keep(
                try scratch.file("%PDF"), for: source("AABN02"), origin: .addedByYou)
            #expect(scratch.store.records() == [record.referencePath: record])

            let files = try FileManager.default.contentsOfDirectory(
                atPath: directory.path(percentEncoded: false))
            let setAside = files.filter { $0.hasPrefix("papers-unreadable-") && $0.hasSuffix(".json") }
            #expect(setAside.count == 1, "\(contents)")
            if let name = setAside.first {
                #expect(try String(contentsOf: directory.appending(path: name), encoding: .utf8)
                    == contents, "kept as it was")
            }
        }
    }

    @Test("a file already in the folder that no record holds is never overwritten")
    func strayFile() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try FileManager.default.createDirectory(
            at: scratch.store.directory, withIntermediateDirectories: true)
        let stray = scratch.store.directory.appending(path: "aabn02.pdf")
        try Data("%PDF stray".utf8).write(to: stray)

        let record = try scratch.store.keep(
            try scratch.file("%PDF"), for: source("AABN02"), origin: .downloaded(from: eprint))
        #expect(record.fileName == "AABN02-2.pdf")
        #expect(try String(contentsOf: stray, encoding: .utf8) == "%PDF stray")
    }
}

/// A replacement that matches the old paper's name, size and second is
/// still a new paper: the window's view identity is the keep's revision, so
/// the open window loads the new file, and a re-read loads nothing.
struct PaperRevisionTests {

    private let eprint = URL(string: "https://eprint.iacr.org/2002/022.pdf")!

    @Test("a same-second, same-size replacement gets a new revision; a re-read keeps it")
    func replacementIsANewRevision() throws {
        let root = try PaperFixtures.temporaryDirectory("papers-revision")
        defer { try? FileManager.default.removeItem(at: root) }
        let instant = Date(timeIntervalSince1970: 1_790_000_000.4)
        let store = PaperStore(
            directory: root.appending(path: "papers"),
            discard: { file in try FileManager.default.removeItem(at: file) },
            now: { instant })
        let source = PaperSource(page: PaperFixtures.reference(
            "AABN02", source: "https://eprint.iacr.org/2002/022", title: "A Paper"))

        func incoming(_ contents: String) throws -> URL {
            let url = root.appending(path: "incoming-\(UUID().uuidString).pdf")
            try Data(contents.utf8).write(to: url)
            return url
        }
        let first = try store.keep(
            try incoming("%PDF-1.4 AAAA"), for: source, origin: .downloaded(from: eprint))
        let second = try store.keep(try incoming("%PDF-1.4 BBBB"), for: source, origin: .addedByYou)

        // Everything the old identity read is the same.
        #expect(first.fileName == second.fileName)
        #expect(first.bytes == second.bytes)
        #expect(first.addedAt == second.addedAt)
        // The revision is not, so the window's paper view is a new one.
        #expect(first.revision != second.revision)
        #expect(PaperWindowView.documentIdentity(of: first)
            != PaperWindowView.documentIdentity(of: second))
        #expect(try String(contentsOf: store.fileURL(for: second), encoding: .utf8)
            == "%PDF-1.4 BBBB")

        // Reading the index again, as every view update does, changes nothing.
        let reread = try #require(PaperStore(directory: store.directory).record(for: source.referencePath))
        #expect(reread == second)
        #expect(PaperWindowView.documentIdentity(of: reread)
            == PaperWindowView.documentIdentity(of: second))
    }

    @Test("a record from before revisions reads with the same revision every time")
    func legacyRecordRevision() throws {
        let root = try PaperFixtures.temporaryDirectory("papers-legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "papers")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("%PDF-1.4 old".utf8).write(to: directory.appending(path: "AABN02.pdf"))
        let index = """
            {
              "papers" : [
                {
                  "addedAt" : "2026-10-01T12:00:00Z",
                  "bytes" : 12,
                  "fileName" : "AABN02.pdf",
                  "origin" : { "addedByYou" : {} },
                  "referencePath" : "References/AABN02.md"
                }
              ],
              "version" : 1
            }
            """
        try Data(index.utf8).write(to: directory.appending(path: "papers.json"))

        let first = try #require(PaperStore(directory: directory).record(for: "References/AABN02.md"))
        let again = try #require(PaperStore(directory: directory).record(for: "References/AABN02.md"))
        #expect(first.revision == again.revision)
        #expect(!first.revision.isEmpty)
    }
}
