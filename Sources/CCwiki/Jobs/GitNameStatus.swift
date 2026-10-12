import Foundation

/// `git diff --cached -M --name-status -z` and `--numstat -z`, parsed
/// (plans/corrections.md §6.1). `-z`, because reference filenames carry
/// spaces, `&` and non-ASCII titles, which git otherwise quotes. Pure.
///
/// With `-z` every field ends in a NUL and nothing is quoted:
///
/// ```
/// --name-status   M\0path\0   A\0path\0   D\0path\0   R100\0old\0new\0
/// --numstat       1\t1\tpath\0   -\t-\tpath\0   0\t0\t\0old\0new\0
/// ```
///
/// `git diff` detects renames by default (`diff.renames`), so `--numstat`
/// reports a rename in its three-field form even without `-M`.
enum GitNameStatus {

    struct Entry: Sendable, Equatable {
        let status: ChangedFile.Status
        /// Repository-relative; the new path of a rename.
        let path: String
        /// The path before a rename.
        let oldPath: String?
    }

    static func parse(nameStatusZ: Data) -> [Entry] {
        let fields = Self.fields(nameStatusZ)
        var entries: [Entry] = []
        var index = 0
        while index < fields.count {
            let letter = fields[index].first ?? "M"
            switch letter {
            case "R", "C":
                // A rename or a copy names both paths. A copy (only with
                // `diff.renames=copies`) leaves its source in place: it adds
                // a file.
                guard index + 2 < fields.count else { return entries }
                let old = fields[index + 1]
                let new = fields[index + 2]
                entries.append(letter == "R"
                    ? Entry(status: .renamed, path: new, oldPath: old)
                    : Entry(status: .added, path: new, oldPath: nil))
                index += 3
            default:
                guard index + 1 < fields.count else { return entries }
                entries.append(Entry(
                    status: Self.status(letter), path: fields[index + 1], oldPath: nil))
                index += 2
            }
        }
        return entries
    }

    /// The paths `--numstat -z` reports as binary ("-\t-\t"): the new path
    /// of a rename.
    static func binaryPaths(numstatZ: Data) -> Set<String> {
        let fields = Self.fields(numstatZ)
        var binary: Set<String> = []
        var index = 0
        while index < fields.count {
            let parts = fields[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            let isBinary = parts.count >= 2 && parts[0] == "-" && parts[1] == "-"
            if parts.count == 3, parts[2].isEmpty {
                // A rename: the paths are the next two fields.
                guard index + 2 < fields.count else { return binary }
                if isBinary { binary.insert(fields[index + 2]) }
                index += 3
            } else {
                if isBinary, parts.count == 3 { binary.insert(String(parts[2])) }
                index += 1
            }
        }
        return binary
    }

    /// A status letter as `ChangedFile` knows it. A type change (`T`) is a
    /// change to the file; anything unexpected is shown as modified rather
    /// than left out of the review.
    private static func status(_ letter: Character) -> ChangedFile.Status {
        switch letter {
        case "A": .added
        case "D": .deleted
        default: .modified
        }
    }

    /// The NUL-terminated fields, decoded as UTF-8. The empty field after
    /// the final NUL is dropped.
    private static func fields(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }
}
