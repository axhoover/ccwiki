import Foundation

/// The pull request a job would open: its title and body as the review
/// edits them (plans/corrections.md §6.4).
///
/// Phase 0 declares it; Track A fills it (§11.2).
struct PullRequestDraft: Codable, Sendable, Equatable {
    var title: String
    var body: String

    /// What the footer says about where the change came from.
    struct Provenance: Sendable, Equatable {
        let appVersion: String
        let isDevBuild: Bool
        /// "edited by hand", "drafted by claude (sonnet)", "ingested by claude".
        let route: String
    }

    /// `.ccwiki/pull-request.md`: the first line `# <title>`, the rest the
    /// body. Nil without a title.
    static func parse(handover: String) -> PullRequestDraft? {
        nil
    }

    /// What CCwiki proposes, merged with the agent's handover when there is
    /// one.
    static func make(for kind: JobKind, handover: PullRequestDraft?, siteURL: URL?) -> PullRequestDraft {
        handover ?? PullRequestDraft(title: "", body: "")
    }

    /// The line after a rule, then the hidden marker. Shared with issues
    /// (§8.2).
    static func footer(_ provenance: Provenance, marker: String) -> String {
        ""
    }

    /// The body as sent: the edited body, then the footer with
    /// "ccwiki-job: <id>".
    func bodyForGitHub(jobID: String, provenance: Provenance) -> String {
        body
    }
}
