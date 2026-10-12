import Foundation

/// One paper kept in the library: which reference it belongs to, its file,
/// and where it came from (plans/reader-comforts.md §2.5).
struct PaperRecord: Codable, Equatable, Sendable {

    enum Origin: Codable, Equatable, Sendable {
        /// Fetched by CCwiki from this URL: the link the reference led to.
        case downloaded(from: URL)
        /// Chosen or dropped by the reader. CCwiki keeps the only copy it has.
        case addedByYou
    }

    let referencePath: String
    let fileName: String
    let origin: Origin
    /// When it was kept, to the second: `papers.json` stores whole seconds.
    let addedAt: Date
    let bytes: Int64
}

/// The papers on disk: `library/papers/`, one PDF per reference, indexed by
/// `papers.json` (plans/reader-comforts.md §2.5).
///
/// Under `library/`, outside the clone, so a PDF can never enter the
/// repository. The index is the truth about what is kept, and the file the
/// truth about whether it is still there: a record whose file is gone counts
/// as not downloaded. Every write of the index is atomic, and a file is only
/// put in place once it is whole, so a half-written PDF is never shown.
struct PaperStore: Sendable {

    /// `AppPaths.papers`, or a temporary directory for the shots.
    let directory: URL
    /// What Remove From Library does with a file: the Trash, so a paper that
    /// will not download again, or the only copy of one you added, can be
    /// put back. Tests pass their own, and leave the real Trash alone.
    private let discard: @Sendable (URL) throws -> Void

    init(directory: URL, discard: (@Sendable (URL) throws -> Void)? = nil) {
        self.directory = directory
        self.discard = discard ?? { file in
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
    }

    var indexURL: URL { directory.appending(path: "papers.json") }

    // MARK: Reading

    /// Every record in `papers.json`, by reference path, whether or not its
    /// file is still there. A missing or unreadable index is an empty one.
    func records() -> [String: PaperRecord] {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? Self.decoder.decode(Index.self, from: data)
        else { return [:] }
        return Dictionary(
            index.papers.map { ($0.referencePath, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The paper kept for a reference; nil when there is none, or its file
    /// is gone.
    func record(for referencePath: String) -> PaperRecord? {
        guard let record = records()[referencePath], fileExists(for: record) else { return nil }
        return record
    }

    func fileURL(for record: PaperRecord) -> URL {
        directory.appending(component: record.fileName)
    }

    func fileExists(for record: PaperRecord) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: record).path(percentEncoded: false))
    }

    // MARK: Writing

    /// Puts `file` in the library as the paper for `source`'s reference, and
    /// records it. A download's temporary file is moved in; a PDF you add is
    /// copied, and yours stays where it was.
    ///
    /// The file is named for the citation key, made unique (§2.3): APFS is
    /// case-insensitive by default and keys are unique only once someone
    /// notices a clash, so it takes the first of `SW25.pdf`, `SW25-2.pdf`, …
    /// that no other reference's record holds and no other file has,
    /// compared case-insensitively. A reference that already has a paper
    /// keeps its file name, and only that file is replaced.
    func keep(
        _ file: URL, for source: PaperSource, origin: PaperRecord.Origin
    ) throws -> PaperRecord {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        var records = self.records()
        let name = records[source.referencePath]?.fileName
            ?? uniqueFileName(for: source, among: records)
        let destination = directory.appending(component: name)

        // Whole before it is in place: a reader never sees a partial file.
        let staged = directory.appending(component: ".incoming-\(UUID().uuidString).pdf")
        switch origin {
        case .downloaded: try manager.moveItem(at: file, to: staged)
        case .addedByYou: try manager.copyItem(at: file, to: staged)
        }
        do {
            if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: staged, to: destination)
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }

        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let record = PaperRecord(
            referencePath: source.referencePath, fileName: name, origin: origin,
            addedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
            bytes: Int64(size))
        records[source.referencePath] = record
        try save(records)
        return record
    }

    /// Discards the reference's paper (to the Trash, by default) and drops
    /// its record. Nothing kept is nothing to do.
    func remove(_ referencePath: String) throws {
        var records = self.records()
        guard let record = records[referencePath] else { return }
        let file = fileURL(for: record)
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            try discard(file)
        }
        records[referencePath] = nil
        try save(records)
    }

    // MARK: Index

    /// What `papers.json` holds: the records sorted by path, so the file
    /// reads well and diffs well.
    private struct Index: Codable {
        var version = 1
        var papers: [PaperRecord]
    }

    private func save(_ records: [String: PaperRecord]) throws {
        let index = Index(papers: records.values.sorted { $0.referencePath < $1.referencePath })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(index).write(to: indexURL, options: .atomic)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The first of `KEY.pdf`, `KEY-2.pdf`, … that no other reference's
    /// record holds and no file in the folder already has.
    private func uniqueFileName(
        for source: PaperSource, among records: [String: PaperRecord]
    ) -> String {
        let held = Set(records.values
            .filter { $0.referencePath != source.referencePath }
            .map { $0.fileName.lowercased() })
        let present = Set(((try? FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false))) ?? []).map { $0.lowercased() })

        let stem = source.fileName.hasSuffix(".pdf")
            ? String(source.fileName.dropLast(4)) : source.fileName
        var number = 1
        while true {
            let name = number == 1 ? stem + ".pdf" : "\(stem)-\(number).pdf"
            let folded = name.lowercased()
            if !held.contains(folded), !present.contains(folded) { return name }
            number += 1
        }
    }
}
