import Foundation

/// `git diff --cached -M --name-status -z` and `--numstat -z`, parsed
/// (plans/corrections.md §6.1). `-z`, because reference filenames carry
/// spaces, `&` and non-ASCII titles, which git otherwise quotes. Pure.
///
/// Phase 0 declares it; Track A fills it (§11.2).
enum GitNameStatus {

    struct Entry: Sendable, Equatable {
        let status: ChangedFile.Status
        let path: String
        let oldPath: String?
    }

    static func parse(nameStatusZ: Data) -> [Entry] {
        []
    }

    /// The paths `--numstat -z` reports as binary ("-\t-\t").
    static func binaryPaths(numstatZ: Data) -> Set<String> {
        []
    }
}
