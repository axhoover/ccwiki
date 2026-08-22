import Foundation
import Testing
@testable import CityDesk

/// Being offline is not a fault: the reader works entirely from the clone, so
/// it earns a quiet note rather than a warning triangle. That distinction is
/// only as good as this classifier.
struct SyncOutcomeTests {

    @Test("git's ways of saying there is no network are all recognized")
    func networkFailures() {
        let messages = [
            "fatal: unable to access 'https://github.com/axhoover/cryptology.city/': "
                + "Could not resolve host: github.com",
            "ssh: connect to host github.com port 22: Operation timed out",
            "fatal: unable to access '…': Failed to connect to github.com port 443",
            "fatal: unable to access '…': Connection refused",
            "ssh: connect to host github.com port 22: Network is unreachable",
            "ssh: connect to host github.com port 22: No route to host",
            "fatal: unable to access '…': Could not resolve proxy: proxy.corp",
            "Temporary failure in name resolution",
        ]
        for message in messages {
            #expect(GitService.isNetworkFailure(message), "should be offline: \(message)")
        }
    }

    @Test("a real problem is not mistaken for an outage")
    func realFailures() {
        let messages = [
            "fatal: Authentication failed for 'https://github.com/axhoover/cryptology.city/'",
            "error: Your local changes to the following files would be overwritten by merge",
            "fatal: Not possible to fast-forward, aborting.",
            "remote: Permission to axhoover/cryptology.city.git denied",
            "fatal: destination path 'repo' already exists and is not an empty directory.",
            "",
        ]
        for message in messages {
            #expect(!GitService.isNetworkFailure(message), "should not be offline: \(message)")
        }
    }

    @Test("only offline reports itself as offline")
    func offlineState() {
        #expect(AppModel.SyncState.failed("Offline — reading from the last pull.").isOffline)
        #expect(!AppModel.SyncState.failed("git fetch failed (exit 128).").isOffline)
        #expect(!AppModel.SyncState.succeeded("Already up to date.").isOffline)
        #expect(!AppModel.SyncState.idle.isOffline)
    }

    @Test("only a completed sync counts as a success")
    func successClassification() {
        #expect(GitService.SyncOutcome.cloned.isSuccess)
        #expect(GitService.SyncOutcome.updated(from: "aaa", to: "bbb").isSuccess)
        #expect(GitService.SyncOutcome.alreadyCurrent(at: "aaa").isSuccess)
        #expect(!GitService.SyncOutcome.offline.isSuccess)
        #expect(!GitService.SyncOutcome.failed("boom").isSuccess)
        #expect(GitService.SyncOutcome.offline.summary.hasPrefix("Offline"))
    }
}

struct SettingsTests {

    @Test("a tool override round-trips and can be cleared")
    func toolOverrides() {
        // UserDefaults is process-wide; use a tool and clean up after.
        defer { CityDeskSettings.setToolOverride(nil, for: .node) }

        CityDeskSettings.setToolOverride("/opt/custom/bin/node", for: .node)
        #expect(CityDeskSettings.toolOverrides()[.node] == "/opt/custom/bin/node")

        CityDeskSettings.setToolOverride(nil, for: .node)
        #expect(CityDeskSettings.toolOverrides()[.node] == nil)
    }

    @Test("an override wins over discovery, and a bad one is ignored")
    func overridePrecedence() {
        // A real executable everyone has.
        #expect(ToolLocator.locate(.git, override: "/bin/sh") == "/bin/sh")
        // A path that is not executable falls back to the normal search.
        let resolved = ToolLocator.locate(.git, override: "/nonexistent/git")
        #expect(resolved != "/nonexistent/git")
    }

    @Test("the child environment widens PATH without losing what we inherited")
    func childEnvironment() {
        var locator = ToolLocator()
        locator.locateAll()
        let path = locator.childEnvironment()["PATH"] ?? ""
        let entries = path.components(separatedBy: ":")

        #expect(entries.contains("/usr/bin"))
        #expect(entries.contains { $0.hasSuffix("/.local/bin") },
                "claude installs there and a Finder-launched app never inherits it")
        #expect(Set(entries).count == entries.count, "no duplicates")
        // Non-interactive children must not try to prompt.
        #expect(locator.childEnvironment()["GIT_TERMINAL_PROMPT"] == "0")
    }
}
