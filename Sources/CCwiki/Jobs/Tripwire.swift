import Foundation

/// Looks, once an agent has finished, for a push or a pull request CCwiki
/// did not make (plans/corrections.md §5.5).
///
/// The seal (`AgentInvocation.sealed`) makes a push unlikely, not
/// impossible. The tripwire is how CCwiki finds out, and says so; it cannot
/// undo anything. Before the agent starts the runner records every branch
/// on GitHub. Afterwards, unless the job was cancelled, `check` asks again:
///
/// 1. **Branches.** A head that is new or moved, and is not another CCwiki
///    job's branch, was pushed while the agent ran. That covers the
///    contract's own `paper-submission/<KEY>-<slug>` too. The job still goes
///    to review, with an orange notice.
/// 2. **Pull requests.** Open ones by the signed-in account, created since
///    a minute before the job started, but for those from another job's
///    branch in the target repository. Only one from the job's own branch,
///    in the target repository itself, makes the job `opened(url)`, with an
///    orange notice. Any other is named in an orange notice, and the job
///    still goes to review with its own diff: the maintainer may open a
///    pull request from Terminal while a job runs, and a pull request from
///    another branch is no evidence that this job's changes are in it.
///
/// It says what CCwiki knows and no more: the maintainer may push from
/// Terminal in the same twenty minutes, so a branch it cannot account for is
/// "not pushed by CCwiki", never "pushed by the agent", unless it is the
/// job's own.
@MainActor
struct Tripwire {

    let git: GitService
    let tools: ToolLocator
    let target: PublishTarget

    /// How long either question to GitHub may take before the tripwire
    /// says it did not run.
    nonisolated static let deadline: Duration = .seconds(30)

    /// Every branch on GitHub, by name. Nil when GitHub could not be asked.
    func headsBefore() async -> [String: String]? {
        await heads()
    }

    /// §5.5's two checks, for a job whose agent has exited. `otherBranches`
    /// are other CCwiki jobs' branches, which CCwiki itself may push while
    /// this agent runs. Each finding, and each check that could not run, is
    /// written to the job's log.
    func check(
        _ job: Job, headsBefore before: [String: String]?, otherBranches: Set<String>
    ) async -> (pullRequest: URL?, notice: JobNotice?) {
        let ignoring = Self.branchesToIgnore(otherBranches, jobBranch: job.branch)
        var moved: [String] = []
        if let before, let after = await heads() {
            moved = Self.movedBranches(before: before, after: after, ignoring: ignoring)
        } else {
            job.append(JobLogEntry(.system,
                "The tripwire could not list the branches on GitHub before and after the "
                + "agent ran, so it did not check for a push."))
        }

        let since = (job.startedAt ?? job.createdAt).addingTimeInterval(-60)
        var opened: [OpenedPullRequest] = []
        if let listing = await pullRequestListing() {
            // CCwiki opens its pull requests from branches in the target
            // repository itself, so only those can be another job's.
            opened = Self.pullRequests(createdAfter: since, in: listing)
                .filter { $0.isCrossRepository || !ignoring.contains($0.head) }
        } else {
            job.append(JobLogEntry(.system,
                "The tripwire could not ask GitHub for open pull requests, so it did not "
                + "check for one."))
        }

        let finding = Self.finding(jobBranch: job.branch, moved: moved, opened: opened)
        if let notice = finding.notice {
            job.append(JobLogEntry(.error, "Tripwire: \(notice.text)"))
            for branch in moved {
                job.append(JobLogEntry(.system, "Pushed while the agent ran: \(branch)"))
            }
            for pullRequest in opened {
                job.append(JobLogEntry(.system,
                    "Opened while the agent ran: \(pullRequest.url.absoluteString) "
                    + "(from \(pullRequest.source))"))
            }
        } else {
            job.append(JobLogEntry(.system,
                "The tripwire found no push and no pull request that CCwiki did not make."))
        }
        return finding
    }

    // MARK: Asking GitHub

    /// The repository as a URL. `PublishTarget.pushURL` may be "origin",
    /// which means something only inside the clone; a URL means the same
    /// thing everywhere, so `ls-remote` needs no repository at all.
    private var remoteURL: String {
        target.pushURL.contains("://")
            ? target.pushURL
            : "https://github.com/\(target.repository).git"
    }

    /// `ls-remote` against a URL runs outside any repository. Running it
    /// from `/` keeps the app's own working directory, which may be a
    /// checkout of something else, out of it.
    nonisolated private static let anywhere = URL(fileURLWithPath: "/")

    private func heads() async -> [String: String]? {
        let git = self.git
        let remote = remoteURL
        return await Subprocess.withDeadline(Self.deadline) {
            await git.remoteHeads(remote: remote, in: Self.anywhere)
        } ?? nil
    }

    /// `<createdAt> <isCrossRepository> <head> <url>` lines, or nil when
    /// `gh` is missing or could not answer. Unsealed: this is CCwiki asking,
    /// not the agent.
    private func pullRequestListing() async -> String? {
        guard let gh = tools.path(for: .gh) else { return nil }
        let arguments = Self.listArguments(target: target)
        let environment = tools.childEnvironment()
        let result = await Subprocess.withDeadline(Self.deadline) {
            await Subprocess.run(executable: gh, arguments: arguments, environment: environment)
        }
        guard let result, result.succeeded else { return nil }
        return result.stdout
    }

    // MARK: Pure

    /// The branches whose pushes and pull requests are CCwiki's own: other
    /// jobs', never this job's. A name is used again once its local branch
    /// is gone, after an agent that changed nothing or a Discard, so an old
    /// record can carry this job's own branch; a push of it is still this
    /// agent's.
    nonisolated static func branchesToIgnore(
        _ otherBranches: Set<String>, jobBranch: String
    ) -> Set<String> {
        otherBranches.subtracting([jobBranch])
    }

    /// Branches that are new in `after`, or at another commit than in
    /// `before`, less `ignoring`. Sorted. A branch that went away is not a
    /// push.
    nonisolated static func movedBranches(
        before: [String: String], after: [String: String], ignoring: Set<String>
    ) -> [String] {
        after.filter { branch, commit in before[branch] != commit && !ignoring.contains(branch) }
            .keys.sorted()
    }

    /// `gh pr list` for the signed-in account's open pull requests in the
    /// target repository, one `<createdAt> <isCrossRepository> <head> <url>`
    /// line each. Whether the head is in another repository is asked
    /// because `headRefName` is a branch's name alone, which a fork's branch
    /// can share.
    nonisolated static func listArguments(target: PublishTarget) -> [String] {
        [
            "pr", "list", "--repo", target.repository, "--author", "@me", "--state", "open",
            "--json", "url,createdAt,headRefName,isCrossRepository",
            "--jq", #".[] | "\(.createdAt) \(.isCrossRepository) \(.headRefName) \(.url)""#,
        ]
    }

    /// `<ISO8601 createdAt> <isCrossRepository> <head> <url>` lines → the
    /// pull requests created at or after `date`, newest first. A branch name
    /// holds no space, so the four fields split cleanly. Anything but
    /// `false` in the second is taken for another repository's head, which
    /// is never a job's own. The variant of
    /// `Publisher.pullRequest(createdAfter:in:)` that keeps the head.
    nonisolated static func pullRequests(createdAfter date: Date, in listing: String)
        -> [OpenedPullRequest] {
        let formatter = ISO8601DateFormatter()
        var found: [OpenedPullRequest] = []
        for line in listing.components(separatedBy: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3).map(String.init)
            guard fields.count == 4,
                  let created = formatter.date(from: fields[0]),
                  created >= date,
                  fields[3].hasPrefix("https://"),
                  let url = URL(string: fields[3])
            else { continue }
            found.append(OpenedPullRequest(
                url: url, head: fields[2], isCrossRepository: fields[1] != "false",
                createdAt: created))
        }
        return found.sorted { $0.createdAt > $1.createdAt }
    }

    /// What the two checks found, in words.
    ///
    /// Only a pull request from the job's own branch in the target
    /// repository (`OpenedPullRequest.isFrom`) is evidence that this job's
    /// changes left without review, and only it makes the job `opened`. Any
    /// other is named, with where to look, and the job goes to review with
    /// its own diff: CCwiki cannot tell the maintainer's pull request from
    /// Terminal from one the agent opened on a branch of its own, and does
    /// not guess. The push of the job's own branch goes without saying when
    /// its pull request is named.
    nonisolated static func finding(
        jobBranch: String, moved: [String], opened: [OpenedPullRequest]
    ) -> (pullRequest: URL?, notice: JobNotice?) {
        let own = opened.first { $0.isFrom(jobBranch) }
        let others = opened.filter { $0 != own }
        var sentences: [String] = []
        if own != nil {
            sentences.append("The agent opened this pull request itself, bypassing review.")
        } else if moved.contains(jobBranch) {
            sentences.append("The agent pushed \(jobBranch) itself, bypassing review.")
        }
        if let sentence = openedSentence(others, inReview: own == nil) {
            sentences.append(sentence)
        }
        if let sentence = pushedSentence(moved.filter { $0 != jobBranch }) {
            sentences.append(sentence)
        }

        guard !sentences.isEmpty else { return (nil, nil) }
        return (own?.url, JobNotice(tone: .warning, text: sentences.joined(separator: " ")))
    }

    /// "A pull request from manual/b was opened … : <url>.", and, when the
    /// job goes to review, where to look and what CCwiki has sent.
    nonisolated private static func openedSentence(
        _ pullRequests: [OpenedPullRequest], inReview: Bool
    ) -> String? {
        guard !pullRequests.isEmpty else { return nil }
        let sources = list(pullRequests.map(\.source))
        let urls = list(pullRequests.map(\.url.absoluteString))
        let found = pullRequests.count == 1
            ? "A pull request from \(sources) was opened while the agent ran, "
                + "and CCwiki did not open it: \(urls)."
            : "Pull requests from \(sources) were opened while the agent ran, "
                + "and CCwiki did not open them: \(urls)."
        guard inReview else { return found }
        let them = pullRequests.count == 1 ? "it" : "them"
        return found + " Look at \(them) on GitHub to see whether the agent made \(them); "
            + "CCwiki has sent nothing from this job, which waits for your review."
    }

    /// "fix/a was pushed …", "fix/a and fix/b were pushed …".
    nonisolated private static func pushedSentence(_ branches: [String]) -> String? {
        switch branches.count {
        case 0:
            return nil
        case 1:
            return "\(branches[0]) was pushed to GitHub while the agent ran, "
                + "and CCwiki did not push it."
        default:
            return "\(list(branches)) were pushed to GitHub while the agent ran, "
                + "and CCwiki did not push them."
        }
    }

    /// "a", "a and b", "a, b and c".
    nonisolated private static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    /// The branches of every other job with a record beside the
    /// transcripts. A push one of them makes while this agent runs is
    /// CCwiki's own (an Approve), not the agent's. Clear Finished deletes
    /// records, so the runner adds the branches the job center still knows
    /// of (`Job.otherJobBranches`).
    nonisolated static func otherJobBranches(logs: URL, excluding jobID: String) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: logs, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        var branches: Set<String> = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(JobRecord.self, from: data),
                  record.id != jobID
            else { continue }
            branches.insert(record.branch)
        }
        return branches
    }
}

/// A pull request GitHub lists as open, as the tripwire reads it.
struct OpenedPullRequest: Sendable, Equatable {
    let url: URL
    /// The name of the branch it is opened from.
    let head: String
    /// Whether that branch is in another repository than the target, as a
    /// fork's is.
    let isCrossRepository: Bool
    let createdAt: Date

    /// Whether it is opened from `branch` in the target repository itself:
    /// the only pull request that can be a job's own.
    func isFrom(_ branch: String) -> Bool {
        head == branch && !isCrossRepository
    }

    /// Where it is opened from, in words.
    var source: String {
        isCrossRepository ? "\(head) in another repository" : head
    }
}
