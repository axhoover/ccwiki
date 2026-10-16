import Foundation
import Testing
@testable import CCwiki

/// The pages a human verified, from the wiki's `.fact-check/queue.json`
/// (plans/corrections.md §6.2 `humanVerified`, §12.1).
struct FactCheckQueueTests {

    /// The live format at the wiki's `ab81f02`: `version`, the update stamp,
    /// and `pages` keyed by repository path. The first two entries are the
    /// live file's own, findings shortened; the third is the status the wiki
    /// has none of yet.
    static let live = #"""
        {
          "version": 1,
          "updated_at": "2026-08-21T00:00:00Z",
          "updated_at_sha": "370800c335216f3a8a9ca930e7f0c5e8e7082ef0",
          "pages": {
            "content/Primitives/attribute-based-encryption.md": {
              "status": "bot_flagged",
              "blob_sha": "ca477e2edaff169ef7e2b4c6fe6ea4db9262b017",
              "verified_at_sha": null,
              "last_checked_at": "2026-08-21T00:00:00Z",
              "last_checked_by": "claude-schema-cleanup",
              "findings": [{ "severity": "error", "location": "see description", "description": "…" }]
            },
            "content/Primitives/broadcast-encryption.md": {
              "status": "unreviewed",
              "blob_sha": null,
              "verified_at_sha": null,
              "findings": []
            },
            "content/Primitives/pseudorandom-function.md": {
              "status": "human_verified",
              "blob_sha": "0c2aa38",
              "verified_at_sha": "ab81f02",
              "last_checked_by": "axhoover",
              "findings": []
            }
          }
        }
        """#

    @Test("human_verified pages are read from the live format, by repository path")
    func liveFormat() {
        #expect(FactCheckQueue.humanVerifiedPaths(json: Data(Self.live.utf8))
            == ["content/Primitives/pseudorandom-function.md"])
    }

    @Test("bot_verified, stale, unreviewed and bot_flagged are not human_verified")
    func otherStatuses() {
        let json = #"""
            {"version": 1, "pages": {
              "content/a.md": {"status": "bot_verified"},
              "content/b.md": {"status": "stale"},
              "content/c.md": {"status": "unreviewed"},
              "content/d.md": {"status": "bot_flagged"}
            }}
            """#
        #expect(FactCheckQueue.humanVerifiedPaths(json: Data(json.utf8)).isEmpty)
    }

    @Test("malformed input gives no paths")
    func malformed() {
        for text in ["", "not json", "[]", "{}", #"{"pages": 3}"#, #"{"pages": "content/a.md"}"#] {
            #expect(FactCheckQueue.humanVerifiedPaths(json: Data(text.utf8)).isEmpty)
        }
    }

    @Test("an entry it cannot read does not hide the others")
    func oddEntry() {
        let json = #"""
            {"pages": {
              "content/a.md": {"status": 7},
              "content/b.md": "human_verified",
              "content/c.md": {"status": "human_verified"}
            }}
            """#
        #expect(FactCheckQueue.humanVerifiedPaths(json: Data(json.utf8)) == ["content/c.md"])
    }
}
