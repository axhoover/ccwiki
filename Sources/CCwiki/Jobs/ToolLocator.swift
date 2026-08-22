import Foundation

/// Finds `git`, `gh`, `claude` and `node` for a Finder-launched app.
///
/// A GUI app inherits `launchd`'s environment, not a login shell's — its `PATH`
/// is `/usr/bin:/bin:/usr/sbin:/sbin`. That is enough for `/usr/bin/git`
/// (which is the Xcode shim) and nothing else: Homebrew lives in
/// `/usr/local/bin`, and `claude` installs to `~/.local/bin`. Without this,
/// the app works from a terminal and silently fails from the Dock.
///
/// Three stages, cheapest first, so the common case costs one `stat`.
struct ToolLocator: Sendable {

    enum Tool: String, CaseIterable, Sendable {
        case git, gh, claude, node

        var purpose: String {
            switch self {
            case .git: "cloning and updating the wiki"
            case .gh: "opening pull requests"
            case .claude: "running ingestion jobs"
            case .node: "running the wiki's lint script"
            }
        }

        /// Whether the reader — as opposed to ingestion — needs it.
        var requiredForReading: Bool { self == .git }
    }

    /// The directories a login shell would normally add, in the order a
    /// `PATH` typically lists them.
    static let commonDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    private(set) var paths: [Tool: String] = [:]
    /// Overrides from Settings, for the case where a tool lives somewhere odd.
    var overrides: [Tool: String] = [:]

    init(overrides: [Tool: String] = [:]) {
        self.overrides = overrides
    }

    mutating func locateAll() {
        for tool in Tool.allCases {
            paths[tool] = Self.locate(tool, override: overrides[tool])
        }
    }

    func path(for tool: Tool) -> String? { paths[tool] }

    var missingForReading: [Tool] {
        Tool.allCases.filter { $0.requiredForReading && paths[$0] == nil }
    }

    var missingForIngestion: [Tool] {
        Tool.allCases.filter { paths[$0] == nil }
    }

    // MARK: Resolution

    static func locate(_ tool: Tool, override: String? = nil) -> String? {
        if let override, isExecutable(override) { return override }

        // 1. Whatever PATH we did inherit.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.components(separatedBy: ":") where !directory.isEmpty {
                let candidate = directory + "/" + tool.rawValue
                if isExecutable(candidate) { return candidate }
            }
        }
        // 2. The usual suspects a GUI app never inherits.
        for directory in commonDirectories {
            let candidate = directory + "/" + tool.rawValue
            if isExecutable(candidate) { return candidate }
        }
        // 3. Ask a login shell, which picks up .zprofile / .zshrc / fish config.
        return askLoginShell(for: tool)
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// `$SHELL -l -c 'command -v <tool>'`. Slow (tens of milliseconds) and can
    /// hang on a pathological profile, so it is the last resort and is given a
    /// deadline.
    private static func askLoginShell(for tool: Tool) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard isExecutable(shell) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v \(tool.rawValue)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }

        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let output = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty, isExecutable(output)
        else { return nil }
        return output
    }

    /// The environment child processes get: the app's, with `PATH` widened so
    /// that tools which shell out to each other (`gh` calling `git`, `claude`
    /// calling anything) also find what they need.
    func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var directories = Self.commonDirectories
        for path in paths.values {
            let directory = (path as NSString).deletingLastPathComponent
            if !directories.contains(directory) { directories.insert(directory, at: 0) }
        }
        let inherited = (environment["PATH"] ?? "").components(separatedBy: ":")
        environment["PATH"] = (directories + inherited)
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { unique, dir in
                if !unique.contains(dir) { unique.append(dir) }
            }
            .joined(separator: ":")

        // Keep child output parseable and non-interactive.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["PAGER"] = "cat"
        environment["CLICOLOR"] = "0"
        environment["NO_COLOR"] = "1"
        return environment
    }
}
