import Foundation

/// `CHANGELOG.md`, as the app reads it for its What's New page.
///
/// One section per release, newest first, each headed `## <version>` with an
/// optional ` — <date>`. Everything before the first section is the file's
/// own preamble and is not shown. The same file supplies each GitHub
/// release's notes (`make release-notes`), so there is one place to write
/// them.
struct Changelog: Sendable, Equatable {

    struct Entry: Sendable, Equatable {
        /// `0.1.2`, without a `v`.
        let version: String
        /// Whatever followed the version in the heading: a date, or
        /// "unreleased".
        let label: String?
        /// The section's markdown, heading excluded, trimmed.
        let body: String
    }

    let entries: [Entry]

    static let empty = Changelog(entries: [])

    static func parse(_ text: String) -> Changelog {
        var entries: [Entry] = []
        var current: (version: String, label: String?)?
        var lines: [Substring] = []

        func close() {
            guard let current else { return }
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(Entry(version: current.version, label: current.label, body: body))
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                close()
                current = heading(String(line.dropFirst(3)))
                lines = []
            } else if current != nil {
                lines.append(line)
            }
        }
        close()
        return Changelog(entries: entries)
    }

    /// `0.1.2 — 2026-09-28` → (`0.1.2`, `2026-09-28`). The separator may be
    /// an em dash, an en dash or a hyphen with spaces around it.
    static func heading(_ text: String) -> (version: String, label: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for separator in [" — ", " – ", " - "] {
            if let range = trimmed.range(of: separator) {
                let version = UpdateChecker.normalize(String(trimmed[..<range.lowerBound]))
                let label = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                return (version, label.isEmpty ? nil : label)
            }
        }
        return (UpdateChecker.normalize(trimmed), nil)
    }

    /// The releases a person moving from `old` to `current` has not seen:
    /// newer than `old` (everything, when `old` is nil) and no newer than
    /// `current`, in the file's order.
    func entries(after old: String?, upTo current: String) -> [Entry] {
        entries.filter { entry in
            (old.map { UpdateChecker.isNewer(entry.version, than: $0) } ?? true)
                && !UpdateChecker.isNewer(entry.version, than: current)
        }
    }

    /// The What's New page's markdown.
    static func whatsNewMarkdown(_ entries: [Entry], since old: String?) -> String {
        var text = "# What's new in CCwiki\n\n"
        if entries.isEmpty {
            text += "Nothing to report for this version.\n"
            return text
        }
        if let old {
            text += "Changes since \(old), newest first.\n\n"
        }
        for entry in entries {
            text += "## \(entry.version)"
            if let label = entry.label { text += " · \(label)" }
            text += "\n\n\(entry.body)\n\n"
        }
        return text
    }
}
