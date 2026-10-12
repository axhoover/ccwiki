import Foundation

// The app-wide half of correcting a page (plans/corrections.md §8, §11.6):
// what blocks a route, and opening an issue. What is about the page being
// read — whether it can be corrected, and starting a route — is the
// window's own, in `ReaderSession+Corrections.swift` (§17).
extension AppModel {

    /// Why `route` cannot start here, from local conditions only: the tools
    /// and the kind of wiki copy. GitHub is `jobCenter.gitHubAccess`'s.
    /// git counts as missing while it is only Apple's stub, before the
    /// Command Line Tools are installed.
    func correctionBlockers(_ route: CorrectionRoute, target: CorrectionTarget) -> [String] {
        CorrectionBlockers.list(
            route: route, region: target.region,
            gitPresent: tools.path(for: .git) != nil && !needsDeveloperTools,
            claudePresent: tools.path(for: .claude) != nil,
            ghPresent: tools.path(for: .gh) != nil,
            store: paths.wikiStore)
    }

    /// The signed-in account's login, for the issue sheet's footer: `gh api
    /// user --jq .login`, asked once and cached for the session. Nil when gh
    /// is missing, signed out or offline; asked again next time.
    func githubLogin() async -> String? {
        if let login = IssueSession.login { return login }
        guard let gh = tools.path(for: .gh) else { return nil }
        let result = await Subprocess.run(
            executable: gh, arguments: ["api", "user", "--jq", ".login"],
            environment: tools.childEnvironment())
        let login = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !login.isEmpty, !login.contains(where: \.isWhitespace) else {
            return nil
        }
        IssueSession.login = login
        return login
    }

    /// The footer CCwiki adds to an issue's body (§8.2): the line after a
    /// rule, then the sheet's hidden marker, which a retry searches for.
    func issueFooter(marker: String) -> String {
        PullRequestDraft.footer(
            PullRequestDraft.Provenance(
                appVersion: appVersion, isDevBuild: publishTarget.isDevBuild,
                route: "reported from the reader"),
            marker: "ccwiki-issue: \(marker)")
    }

    /// `gh issue create` with the sheet's text and CCwiki's footer (§8.2),
    /// on `publishTarget.repository`. Nothing is recorded locally: the issue
    /// on GitHub is the record.
    ///
    /// A retry first asks GitHub for an issue already carrying the sheet's
    /// marker: gh's reply to the last attempt may have been lost after the
    /// issue was made. `CCWIKI_PUBLISH_DRY_RUN=1` stops short of sending and
    /// says what would have run.
    func openIssue(_ draft: IssueDraft) async -> Result<URL, JobError> {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .failure(JobError("The issue needs a title.")) }
        guard let gh = tools.path(for: .gh) else {
            return .failure(JobError(CorrectionBlockers.ghMissing))
        }
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n" + issueFooter(marker: draft.marker)
        let found = PrivateText.findings(
            in: title + "\n" + body, privatePaths: jobCenter.environment().privatePaths)
        if let first = found.first {
            return .failure(JobError("This text contains a local path or a token: \(first). "
                + "Take it out, then open the issue."))
        }

        let repository = publishTarget.repository
        let environment = tools.childEnvironment()
        if IssueSession.attempted.contains(draft.marker) {
            switch await Self.issue(
                marked: draft.marker, gh: gh, repository: repository, environment: environment) {
            case .found(let existing):
                return .success(existing)
            case .notFound:
                break
            case .unknown:
                // Sending again blind could open the issue twice.
                return .failure(JobError("CCwiki could not check whether the last attempt "
                    + "opened the issue. Nothing was sent; try again."))
            }
        }

        let bodyFile = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-issue-\(draft.marker).md")
        do {
            try body.write(to: bodyFile, atomically: true, encoding: .utf8)
        } catch {
            return .failure(JobError("The issue's text could not be written for gh: "
                + error.localizedDescription))
        }
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        let arguments = ["issue", "create", "--repo", repository, "--title", title,
                         "--body-file", bodyFile.path(percentEncoded: false)]
        if ProcessInfo.processInfo.environment["CCWIKI_PUBLISH_DRY_RUN"] == "1" {
            return .failure(JobError("Dry run: nothing was sent. CCwiki would have run "
                + Self.commandLine(["gh"] + arguments)))
        }

        IssueSession.attempted.insert(draft.marker)
        let result = await Subprocess.run(
            executable: gh, arguments: arguments, environment: environment)
        if result.succeeded, let url = Self.lastURL(in: result.stdout) {
            return .success(url)
        }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(JobError(output.isEmpty
            ? "gh issue create failed (exit \(result.status))."
            : "gh issue create failed: \(output)"))
    }

    /// An issue by `@me` whose body carries the marker, open or closed: the
    /// newest of them, listed, and each body read here. Not GitHub's
    /// search, whose index lags a new issue by up to minutes and may not
    /// read inside the comment that holds the marker.
    private static func issue(
        marked marker: String, gh: String, repository: String, environment: [String: String]
    ) async -> IssueComposer.Lookup {
        let result = await Subprocess.run(
            executable: gh,
            arguments: ["issue", "list", "--repo", repository, "--author", "@me", "--state", "all",
                        "--limit", "50", "--json", "url,body"],
            environment: environment)
        guard result.succeeded else { return .unknown }
        return IssueComposer.lookup(marker: marker, inList: result.stdout)
    }

    /// The last line of `output` that is an https URL: gh prints the new
    /// issue's address last.
    private static func lastURL(in output: String) -> URL? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { $0.hasPrefix("https://") })
            .flatMap { URL(string: $0) }
    }

    /// A command as it would be typed, for the dry run to show.
    private static func commandLine(_ words: [String]) -> String {
        words.map { word in
            word.contains(where: { $0.isWhitespace || "\"'$`\\".contains($0) })
                ? "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
                : word
        }.joined(separator: " ")
    }
}

/// What opening issues remembers for the session: the login, and the
/// sheets that have tried to send, so a retry looks for its issue first.
@MainActor
private enum IssueSession {
    static var login: String?
    static var attempted: Set<String> = []
}
