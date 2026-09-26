import Darwin
import Foundation

/// Which of a child's two output streams a line came from.
enum OutputStream: String, Sendable {
    case stdout, stderr
}

/// One line of child output.
struct ProcessLine: Sendable {
    let stream: OutputStream
    let text: String
    /// The chunk ended with `\r` rather than `\n` — a progress update that
    /// should *replace* the previous line rather than pile up beneath it.
    let isProgress: Bool

    /// Streams end with a synthetic line carrying the exit status.
    var exitStatus: Int32? {
        guard text.hasPrefix(Subprocess.exitMarker) else { return nil }
        return Int32(text.dropFirst(Subprocess.exitMarker.count)) ?? -1
    }
}

/// Splits a byte stream into lines on **both** `\n` and `\r`.
///
/// `git --progress` terminates each progress update with `\r`; a splitter that
/// only knows `\n` buffers the whole clone into one multi-megabyte "line" and
/// the UI shows nothing until it finishes.
///
/// `@unchecked Sendable` with a lock is the one manual audit in this file: the
/// readability handler runs on a private Dispatch queue.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func feed(_ data: Data) -> [(text: String, isProgress: Bool)] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)

        var lines: [(String, Bool)] = []
        while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let isCarriageReturn = buffer[index] == 0x0D
            let text = String(decoding: buffer[buffer.startIndex..<index], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...index)
            // Swallow the `\n` of a CRLF pair.
            if isCarriageReturn, buffer.first == 0x0A { buffer.removeFirst() }
            if !text.isEmpty || !isCarriageReturn { lines.append((text, isCarriageReturn)) }
        }
        return lines
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// Running child processes and streaming their output.
///
/// Everything the app shells out to — `git`, `gh`, `claude`, `node` — goes
/// through here, because all of it is long-running and all of it has to show
/// its work in a log pane while it runs.
enum Subprocess {

    static let exitMarker = "\u{1}exit "

    /// The pids of every child still running, so a quit can stop them all.
    /// `Process` is not Sendable; a pid is.
    private static let running = RunningProcesses()

    final class RunningProcesses: @unchecked Sendable {
        private let lock = NSLock()
        private var pids: Set<pid_t> = []

        func insert(_ pid: pid_t) {
            lock.lock()
            pids.insert(pid)
            lock.unlock()
        }

        func remove(_ pid: pid_t) {
            lock.lock()
            pids.remove(pid)
            lock.unlock()
        }

        func drain() -> Set<pid_t> {
            lock.lock()
            let copy = pids
            pids.removeAll()
            lock.unlock()
            return copy
        }
    }

    /// `SIGTERM` to every child still running. The app is quitting; nothing
    /// that outlives it has anyone to report to.
    static func terminateAll() {
        for pid in running.drain() { deliver(SIGTERM, to: pid) }
    }

    /// Signal the child's process group, which reaches `git`'s helpers and
    /// `claude`'s node children. If the child has no group of its own, signal
    /// the child alone. Either way the group id is the child's pid, never
    /// CCwiki's, so this cannot reach the app itself.
    private static func deliver(_ sig: Int32, to pid: pid_t) {
        guard pid > 0 else { return }
        if kill(-pid, sig) != 0 { kill(pid, sig) }
    }

    struct Result: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String

        var succeeded: Bool { status == 0 }
        /// stdout when the command worked, stderr when it did not — the string
        /// you actually want in an error message.
        var output: String { succeeded ? stdout : (stderr.isEmpty ? stdout : stderr) }
    }

    enum Failure: LocalizedError {
        case notExecutable(String)
        case launchFailed(String, underlying: String)

        var errorDescription: String? {
            switch self {
            case .notExecutable(let path):
                "\(path) is not an executable file."
            case .launchFailed(let path, let underlying):
                "Could not run \(path): \(underlying)"
            }
        }
    }

    /// Stream a child's output line by line.
    ///
    /// Cancelling the consuming task sends `SIGTERM` to the child's whole
    /// process group — Foundation already gives the child its own group, so
    /// this reaches `git`'s helper processes and `claude`'s node subprocesses
    /// without any chance of signalling CCwiki itself.
    static func lines(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]
    ) -> AsyncStream<ProcessLine> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8192)) { continuation in
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                continuation.yield(ProcessLine(
                    stream: .stderr, text: "not executable: \(executable)", isProgress: false))
                continuation.yield(ProcessLine(
                    stream: .stdout, text: exitMarker + "127", isProgress: false))
                continuation.finish()
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory
            process.environment = environment
            // Never inherit stdin. If git or ssh decides to prompt, it must
            // fail fast on EOF rather than hang a GUI app on an invisible
            // password prompt.
            process.standardInput = FileHandle.nullDevice

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Both pipes must reach EOF before the exit status is reported, or
            // the tail of the output is lost.
            let drained = DispatchGroup()
            drained.enter()
            drained.enter()

            func drain(_ pipe: Pipe, _ which: OutputStream) {
                let splitter = LineSplitter()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil  // must clear or the queue spins
                        if let tail = splitter.flush() {
                            continuation.yield(
                                ProcessLine(stream: which, text: tail, isProgress: false))
                        }
                        drained.leave()
                        return
                    }
                    for line in splitter.feed(data) {
                        continuation.yield(ProcessLine(
                            stream: which, text: line.text, isProgress: line.isProgress))
                    }
                }
            }
            drain(outPipe, .stdout)
            drain(errPipe, .stderr)

            process.terminationHandler = { finished in
                running.remove(finished.processIdentifier)
                drained.notify(queue: .global()) {
                    continuation.yield(ProcessLine(
                        stream: .stdout,
                        text: exitMarker + String(finished.terminationStatus),
                        isProgress: false))
                    continuation.finish()
                }
            }

            continuation.onTermination = { reason in
                guard case .cancelled = reason, process.isRunning else { return }
                deliver(SIGTERM, to: process.processIdentifier)
                // Escalate if it ignores the polite request.
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning { deliver(SIGKILL, to: process.processIdentifier) }
                }
            }

            do {
                try process.run()
                running.insert(process.processIdentifier)
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                continuation.yield(ProcessLine(
                    stream: .stderr,
                    text: "launch failed: \(error.localizedDescription)",
                    isProgress: false))
                continuation.yield(ProcessLine(
                    stream: .stdout, text: exitMarker + "127", isProgress: false))
                continuation.finish()
            }
        }
    }

    /// Run to completion and collect the output. For short commands —
    /// `git rev-parse`, `gh pr create` — where there is nothing to stream.
    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]
    ) async -> Result {
        var out: [String] = []
        var err: [String] = []
        var status: Int32 = -1

        for await line in lines(
            executable: executable, arguments: arguments,
            currentDirectory: currentDirectory, environment: environment
        ) {
            if let exit = line.exitStatus { status = exit; continue }
            switch line.stream {
            case .stdout: out.append(line.text)
            case .stderr: err.append(line.text)
            }
        }
        return Result(
            status: status,
            stdout: out.joined(separator: "\n"),
            stderr: err.joined(separator: "\n"))
    }
}
