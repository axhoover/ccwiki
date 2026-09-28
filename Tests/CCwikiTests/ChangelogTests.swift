import Foundation
import Testing
@testable import CCwiki

/// The What's New page is built from `CHANGELOG.md`; these pin the format and
/// the rules for which releases a person is shown.
struct ChangelogTests {

    private static let sample = """
        # What's new

        <!-- a note for maintainers, not shown -->

        ## 0.2.0 — unreleased

        **New thing.**

        ## v0.1.1 – 2026-09-27

        Second.

        ## 0.1.0

        First.
        """

    @Test("sections parse with their version, label and body, preamble ignored")
    func parse() {
        let log = Changelog.parse(Self.sample)
        #expect(log.entries.map(\.version) == ["0.2.0", "0.1.1", "0.1.0"])
        #expect(log.entries.map(\.label) == ["unreleased", "2026-09-27", nil])
        #expect(log.entries[0].body == "**New thing.**")
        #expect(log.entries[2].body == "First.")
    }

    @Test("an update shows what is newer than the old version and no newer than this one")
    func window() {
        let log = Changelog.parse(Self.sample)
        #expect(log.entries(after: "0.1.0", upTo: "0.1.1").map(\.version) == ["0.1.1"])
        #expect(log.entries(after: "0.1.0", upTo: "0.2.0").map(\.version) == ["0.2.0", "0.1.1"])
        #expect(log.entries(after: nil, upTo: "0.1.1").map(\.version) == ["0.1.1", "0.1.0"])
        #expect(log.entries(after: "0.2.0", upTo: "0.2.0").isEmpty)
    }

    @Test("first launch welcomes; an update shows what's new; a dev build shows neither")
    func launchDocument() {
        let log = Changelog.parse(Self.sample)

        let first = AppModel.launchDocument(lastSeen: nil, current: "0.1.1", changelog: log)
        #expect(first?.document == .welcome)

        let updated = AppModel.launchDocument(lastSeen: "0.1.0", current: "0.1.1", changelog: log)
        #expect(updated?.document == .whatsNew)
        #expect(updated?.since == "0.1.0")

        #expect(AppModel.launchDocument(lastSeen: "0.1.1", current: "0.1.1", changelog: log) == nil,
                "same version: nothing")
        #expect(AppModel.launchDocument(lastSeen: "0.1.1", current: "0.1.0", changelog: log) == nil,
                "a downgrade is not news")
        #expect(AppModel.launchDocument(lastSeen: "0.1.0", current: "0.2.0-dev", changelog: log) == nil,
                "a local build never announces anything")
        #expect(AppModel.launchDocument(lastSeen: "0.1.0", current: "0.1.1", changelog: .empty) == nil,
                "nothing written, nothing shown")
    }

    @Test("the What's New markdown says what it covers")
    func markdown() {
        let log = Changelog.parse(Self.sample)
        let text = Changelog.whatsNewMarkdown(
            log.entries(after: "0.1.0", upTo: "0.2.0"), since: "0.1.0")
        #expect(text.hasPrefix("# What's new in CCwiki"))
        #expect(text.contains("Changes since 0.1.0"))
        #expect(text.contains("## 0.2.0 · unreleased"))
        #expect(!text.contains("First."))
    }

    /// The repository's own changelog is what ships. A malformed heading here
    /// would quietly drop a release from What's New and from its GitHub notes.
    @Test("the repository's CHANGELOG.md parses, newest first, every version valid")
    func repositoryChangelog() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appending(path: "CHANGELOG.md"), encoding: .utf8)
        let log = Changelog.parse(text)
        #expect(!log.entries.isEmpty)
        for entry in log.entries {
            #expect(UpdateChecker.components(entry.version).count == 3,
                    "\(entry.version) is not X.Y.Z")
            #expect(!entry.body.isEmpty, "\(entry.version) has no notes")
        }
        for (newer, older) in zip(log.entries, log.entries.dropFirst()) {
            #expect(UpdateChecker.isNewer(newer.version, than: older.version),
                    "\(newer.version) should come before \(older.version)")
        }
    }
}
