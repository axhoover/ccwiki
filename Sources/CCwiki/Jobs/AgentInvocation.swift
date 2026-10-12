import Foundation

/// How CCwiki starts `claude` for a job: its arguments, and the environment
/// it runs in (plans/corrections.md §5.1, §5.4). Pure, so every layer of the
/// seal is tested.
///
/// An agent job stops before GitHub. The agent leaves its changes in the
/// worktree and its pull request's text in the handover file; CCwiki shows
/// both to a person, and only once they approve does CCwiki commit, push and
/// open the pull request, with its own unsealed environment. A prompt that
/// says "do not push" is not enough, so every agent runs inside three
/// layers:
///
/// 1. **The allow-list** leaves out `gh` and every git command that writes.
///    A correction gets no `Bash` at all.
/// 2. **The deny-list**, which wins over any allow.
/// 3. **The environment** (`sealed`): no GitHub token, no SSH agent, an
///    empty `gh` configuration, no credential helper, and a push URL that
///    goes nowhere.
///
/// The seal stops a confused agent and an accident: a plain `git push` or
/// `gh pr create` fails. It does not stop a determined one. `git -c
/// credential.helper=… push` does not match the deny rule's prefix, and an
/// ingestion keeps `node`, which can run anything. So the tripwire
/// (`Tripwire`) looks afterwards, and the review is the gate: nothing the
/// agent leaves in the worktree reaches GitHub without approval (§13).
struct AgentInvocation: Sendable, Equatable {

    /// For `claude`, after the executable.
    var arguments: [String]
    var environment: [String: String]

    /// A paper ingestion: the CLI's default model, and the tools the wiki's
    /// own workflow grants plus what the local lint needs.
    static func ingestion(
        prompt: String, maxTurns: String, base: [String: String], scratch: URL
    ) -> AgentInvocation {
        AgentInvocation(
            arguments: arguments(
                prompt: prompt, model: "", allowed: ingestionTools, maxTurns: maxTurns),
            environment: sealed(base, scratch: scratch))
    }

    /// A correction: a smaller model where one is chosen (`""` is the CLI's
    /// default), the file tools, and nothing else (§5.4).
    static func correction(
        prompt: String, model: String, maxTurns: String,
        base: [String: String], scratch: URL
    ) -> AgentInvocation {
        AgentInvocation(
            arguments: arguments(
                prompt: prompt, model: model, allowed: correctionTools, maxTurns: maxTurns),
            environment: sealed(base, scratch: scratch))
    }

    /// ```
    /// claude -p "<prompt>" --output-format stream-json --verbose [--model <m>]
    ///   --permission-mode acceptEdits --allowedTools … --disallowedTools …
    ///   --max-turns <n>
    /// ```
    ///
    /// The prompt goes first: `--allowedTools` and `--disallowedTools` take
    /// a list, and would swallow a prompt that followed them. Edits inside a
    /// throwaway worktree are safe to auto-accept; every other tool still
    /// has to match the allow-list, so a job that wanders off fails visibly,
    /// with the denied call named in the transcript, rather than doing
    /// something nobody asked for.
    private static func arguments(
        prompt: String, model: String, allowed: [String], maxTurns: String
    ) -> [String] {
        var arguments = ["-p", prompt, "--output-format", "stream-json", "--verbose"]
        if !model.isEmpty { arguments += ["--model", model] }
        arguments += [
            "--permission-mode", "acceptEdits",
            "--allowedTools", allowed.joined(separator: ","),
            "--disallowedTools", denied.joined(separator: ","),
            "--max-turns", maxTurns,
        ]
        return arguments
    }

    // MARK: The environment

    /// `environment`, sealed for an agent (§5.1):
    ///
    /// - `GH_CONFIG_DIR` is an empty directory under the job's scratch,
    ///   outside the worktree, so `gh` sees no signed-in host and nothing it
    ///   writes can be staged;
    /// - the GitHub tokens and `SSH_AUTH_SOCK` are removed;
    /// - three git settings, appended after any the environment already
    ///   carries so they are read last: `remote.origin.pushurl` goes
    ///   nowhere, and both `credential.helper` and the clone's own
    ///   `credential.https://github.com.helper` are emptied, which clears
    ///   each list;
    /// - `GIT_SSH_COMMAND` and both askpass programs are `/usr/bin/false`,
    ///   and git never prompts.
    ///
    /// `GIT_CONFIG_COUNT` needs git 2.31; Apple's is 2.39. CCwiki's own
    /// commands use the environment unsealed.
    static func sealed(_ environment: [String: String], scratch: URL) -> [String: String] {
        var sealed = environment
        for name in removedVariables { sealed[name] = nil }
        sealed["GH_CONFIG_DIR"] = ghConfigDirectory(scratch: scratch).path(percentEncoded: false)

        let start = max(environment["GIT_CONFIG_COUNT"].flatMap { Int($0) } ?? 0, 0)
        for (offset, setting) in gitSettings.enumerated() {
            sealed["GIT_CONFIG_KEY_\(start + offset)"] = setting.key
            sealed["GIT_CONFIG_VALUE_\(start + offset)"] = setting.value
        }
        sealed["GIT_CONFIG_COUNT"] = String(start + gitSettings.count)

        for program in ["GIT_SSH_COMMAND", "GIT_ASKPASS", "SSH_ASKPASS"] {
            sealed[program] = "/usr/bin/false"
        }
        sealed["GIT_TERMINAL_PROMPT"] = "0"
        return sealed
    }

    /// The agent's `GH_CONFIG_DIR`: `<scratch>/gh`. The runner creates it,
    /// empty, before the agent starts.
    static func ghConfigDirectory(scratch: URL) -> URL {
        scratch.appending(path: "gh")
    }

    /// Credentials an agent must not inherit.
    static let removedVariables = [
        "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN",
        "SSH_AUTH_SOCK",
    ]

    /// The push URL a sealed `git push origin` is sent to: no transport
    /// answers to it, so the push fails before anything leaves.
    static let blockedPushURL = "ccwiki-review-first://blocked"

    /// In order; an empty helper clears the list of helpers before it.
    static let gitSettings: [(key: String, value: String)] = [
        ("remote.origin.pushurl", blockedPushURL),
        ("credential.helper", ""),
        ("credential.https://github.com.helper", ""),
    ]

    // MARK: Tools

    /// What an ingestion agent may use: the allow-list the wiki's own GitHub
    /// workflow grants (`paper-submission.yml`), less everything that
    /// reaches GitHub, plus the node and npm commands the **local** lint
    /// needs, which the server pipeline does not run.
    ///
    /// git only reads. The agent no longer commits (§5.1): it leaves its
    /// change in the worktree, and CCwiki commits it after review. `gh` is
    /// not here at all.
    ///
    /// The allow-list matches on a command's **first words**, so `cd X &&
    /// git …` is denied however harmless it looks. The first real job hit
    /// seven denials, every one a `cd`-prefixed or `ln` command, which is
    /// why `prompts/ingest.md` says plainly that the shell already starts in
    /// the worktree. The rest are read-only inspection tools.
    static let ingestionTools = [
        "Read", "Write", "Edit", "Glob", "Grep", "TodoWrite",
        // git, to read with.
        "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)",
        "Bash(git ls-files:*)", "Bash(git grep:*)", "Bash(git rev-parse:*)",
        "Bash(git submodule update:*)",
        // The lint and the build.
        "Bash(npm:*)", "Bash(npx:*)", "Bash(node:*)",
        // Read-only inspection.
        "Bash(find:*)", "Bash(file:*)", "Bash(jq:*)", "Bash(cat:*)", "Bash(ls:*)",
        "Bash(head:*)", "Bash(tail:*)", "Bash(wc:*)", "Bash(grep:*)", "Bash(rg:*)",
        "Bash(echo:*)", "Bash(pwd)", "Bash(test:*)", "Bash(diff:*)",
        "Bash(sort:*)", "Bash(uniq:*)", "Bash(cut:*)", "Bash(basename:*)",
        "Bash(dirname:*)", "Bash(hexdump:*)", "Bash(xxd:*)", "Bash(od:*)",
        "Bash(pdftotext:*)", "Bash(mdls:*)",
        // Fetching the paper.
        "WebFetch", "WebSearch",
    ]

    /// What a correction agent may use: the file tools. No `Bash` (CCwiki
    /// computes the diff itself, and `git diff --output=<file>` writes
    /// anywhere), and no web: a correction that needs the cited paper read
    /// again is beyond a cheap job, and the prompt says to abort (§5.4).
    static let correctionTools = ["Read", "Edit", "Write", "Glob", "Grep"]

    /// Denied whatever the allow-list says.
    static let denied = [
        "Bash(git push:*)", "Bash(git commit:*)", "Bash(git remote:*)", "Bash(git config:*)",
        "Bash(gh:*)",
    ]
}

/// The agent's side of the hand-over (plans/corrections.md §5.2). It leaves
/// its changes in the worktree, and the pull request's text in
/// `.ccwiki/pull-request.md`: the first line `# <title>`, the rest the body.
///
/// `.ccwiki/` is also where an agent writes any scratch output, such as a
/// lint log. Every `git add` CCwiki runs leaves it out (`GitService.stageAll`),
/// so nothing in it can reach a pull request.
enum Handover {

    /// Repository-relative.
    static let directory = ".ccwiki"
    static let pullRequestPath = ".ccwiki/pull-request.md"

    /// The pull request text the agent left in `worktree`, if any.
    static func pullRequestText(in worktree: URL) -> String? {
        try? String(contentsOf: worktree.appending(path: pullRequestPath), encoding: .utf8)
    }
}
