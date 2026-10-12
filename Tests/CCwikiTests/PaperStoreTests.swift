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

    @Test("a PDF you add is copied, and replaces the reference's own file")
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
