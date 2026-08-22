import Foundation

/// One line in a job's transcript.
///
/// `claude --output-format stream-json` emits a structured event per step, so
/// the jobs panel can show "▸ Bash  git status" rather than a wall of raw JSON
/// — and the terminal event carries the turn count, the cost, and any
/// permission denials, which is exactly what you want when a job goes wrong.
struct JobLogEntry: Identifiable, Sendable {

    enum Role: Sendable {
        /// CCwiki itself: "creating worktree", "pruning".
        case system
        /// Prose from the agent.
        case assistant
        /// A tool invocation.
        case tool(name: String)
        /// A tool's output, trimmed.
        case toolResult(isError: Bool)
        /// Anything the child wrote to stderr.
        case stderr
        case error
    }

    let id = UUID()
    let role: Role
    let text: String
    let timestamp: Date

    init(_ role: Role, _ text: String, at timestamp: Date = Date()) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

/// How a job ended, from the `result` event.
struct ClaudeOutcome: Sendable {
    var isError: Bool
    var subtype: String
    /// The agent's final message — where the PR URL is.
    var result: String
    var turns: Int
    var costUSD: Double?
    var durationMS: Int?
    var sessionID: String?
    var permissionDenials: [String]
}

/// Turns `claude --output-format stream-json` lines into log entries.
///
/// Deliberately lenient: an unrecognized event type is surfaced as a system
/// line rather than dropped or fatal, because the CLI's event vocabulary will
/// grow and a job that silently swallows new events is worse than one that
/// prints something slightly ugly.
struct ClaudeStreamParser {

    private(set) var outcome: ClaudeOutcome?
    private(set) var sessionID: String?
    private(set) var model: String?

    /// Parse one line. Returns the entries to append — usually one, sometimes
    /// several (an assistant turn can carry text *and* a tool call), sometimes
    /// none (bookkeeping events).
    mutating func consume(_ line: String) -> [JobLogEntry] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Not JSON: the CLI printed a bare message. Show it.
            return [JobLogEntry(.system, trimmed)]
        }

        switch event["type"] as? String {
        case "system":
            if event["subtype"] as? String == "init" {
                sessionID = event["session_id"] as? String
                model = event["model"] as? String
                let cwd = (event["cwd"] as? String).map { ($0 as NSString).lastPathComponent }
                return [JobLogEntry(.system,
                    "Session started" + (model.map { " · \($0)" } ?? "")
                        + (cwd.map { " · \($0)" } ?? ""))]
            }
            return []

        case "assistant":
            return assistantEntries(event)

        case "user":
            return toolResultEntries(event)

        case "result":
            outcome = ClaudeOutcome(
                isError: event["is_error"] as? Bool ?? false,
                subtype: event["subtype"] as? String ?? "unknown",
                result: event["result"] as? String ?? "",
                turns: event["num_turns"] as? Int ?? 0,
                costUSD: event["total_cost_usd"] as? Double,
                durationMS: event["duration_ms"] as? Int,
                sessionID: event["session_id"] as? String ?? sessionID,
                permissionDenials: Self.denials(event))
            return []

        case "rate_limit_event":
            guard let info = event["rate_limit_info"] as? [String: Any],
                  let status = info["status"] as? String, status != "allowed"
            else { return [] }
            return [JobLogEntry(.system, "Rate limit: \(status)")]

        case nil:
            return [JobLogEntry(.system, trimmed)]

        default:
            return []
        }
    }

    private func assistantEntries(_ event: [String: Any]) -> [JobLogEntry] {
        guard let message = event["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return [] }

        var entries: [JobLogEntry] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                let text = (block["text"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { entries.append(JobLogEntry(.assistant, text)) }
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                entries.append(JobLogEntry(
                    .tool(name: name),
                    Self.summarize(tool: name, input: block["input"] as? [String: Any] ?? [:])))
            default:
                break
            }
        }
        return entries
    }

    private func toolResultEntries(_ event: [String: Any]) -> [JobLogEntry] {
        guard let message = event["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return [] }

        var entries: [JobLogEntry] = []
        for block in content where block["type"] as? String == "tool_result" {
            let isError = block["is_error"] as? Bool ?? false
            let text = Self.flatten(block["content"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            entries.append(JobLogEntry(.toolResult(isError: isError), Self.clip(text)))
        }
        return entries
    }

    /// A one-line description of a tool call — the command for `Bash`, the path
    /// for a file tool, the query for a search.
    static func summarize(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Bash":
            return (input["command"] as? String ?? "").replacingOccurrences(of: "\n", with: " ⏎ ")
        case "Read", "Write", "Edit", "NotebookEdit":
            return input["file_path"] as? String ?? ""
        case "Glob", "Grep":
            let pattern = input["pattern"] as? String ?? ""
            let path = input["path"] as? String
            return path.map { "\(pattern)  in \($0)" } ?? pattern
        case "WebFetch", "WebSearch":
            return (input["url"] as? String) ?? (input["query"] as? String ?? "")
        case "Task":
            return input["description"] as? String ?? ""
        case "TodoWrite":
            guard let todos = input["todos"] as? [[String: Any]] else { return "" }
            let active = todos.first { ($0["status"] as? String) == "in_progress" }
            return active?["content"] as? String ?? "\(todos.count) items"
        default:
            guard let data = try? JSONSerialization.data(withJSONObject: input),
                  let json = String(data: data, encoding: .utf8)
            else { return "" }
            return clip(json, limit: 160)
        }
    }

    /// Tool results arrive either as a bare string or as content blocks.
    private static func flatten(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    /// Tool output can be a whole file. The transcript keeps the head; the raw
    /// stream is on disk in `…/CCwiki/logs/<job>.log` if anyone needs it.
    private static func clip(_ text: String, limit: Int = 600) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n… (\(text.count - limit) more characters)"
    }

    private static func denials(_ event: [String: Any]) -> [String] {
        guard let raw = event["permission_denials"] as? [[String: Any]] else { return [] }
        return raw.map { denial in
            let tool = denial["tool_name"] as? String ?? "tool"
            let input = denial["tool_input"] as? [String: Any] ?? [:]
            return "\(tool): \(summarize(tool: tool, input: input))"
        }
    }
}

extension ClaudeOutcome {
    /// The pull-request URL the agent printed, if it opened one.
    ///
    /// Taken from the agent's final message rather than by watching `gh`'s
    /// output, because the agent may run `gh pr create` inside a script or
    /// retry it; its own closing statement is the thing it is asked to make
    /// authoritative.
    var pullRequestURL: URL? {
        Self.findPullRequestURL(in: result)
    }

    static func findPullRequestURL(in text: String) -> URL? {
        let pattern = #"https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // The last one: the agent may quote the template before printing the
        // real thing.
        guard let match = matches.last else { return nil }
        return URL(string: ns.substring(with: match.range))
    }

    /// The agent was asked to abort rather than open a bad PR.
    var abortReason: String? {
        guard let range = result.range(of: "ABORTED:") else { return nil }
        return String(result[range.lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
