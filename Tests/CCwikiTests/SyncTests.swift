import Foundation
import Testing
@testable import CCwiki

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
            // git puts "unable to access" in front of every HTTP failure; none
            // of these is an outage.
            "fatal: unable to access 'https://github.com/axhoover/cryptology.city/': "
                + "The requested URL returned error: 403",
            "fatal: unable to access 'https://github.com/axhoover/cryptology.city/': "
                + "SSL certificate problem: unable to get local issuer certificate",
            "fatal: unable to access 'https://github.com/axhoover/cryptology.city/': "
                + "Received HTTP code 407 from proxy after CONNECT",
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

/// A page's address on the published site is its simplified Quartz slug.
struct SiteURLTests {

    @Test("pages, folders, the root and anchors map onto cryptology.city")
    func siteURLs() {
        #expect(AppModel.siteURL(slug: "Primitives/pseudorandom-function")?.absoluteString
            == "https://cryptology.city/Primitives/pseudorandom-function")
        #expect(AppModel.siteURL(slug: "index")?.absoluteString == "https://cryptology.city/")
        #expect(AppModel.siteURL(slug: "Primitives/")?.absoluteString
            == "https://cryptology.city/Primitives/")
        #expect(AppModel.siteURL(slug: "Primitives/index")?.absoluteString
            == "https://cryptology.city/Primitives/")
        #expect(AppModel.siteURL(slug: "Assumptions/learning-with-errors", anchor: "syntax")?
            .absoluteString == "https://cryptology.city/Assumptions/learning-with-errors#syntax")
    }
}

/// Opening a search hit finds the query on the page: the phrase first, then
/// its words, longest first, since full-text search matches words anywhere.
struct FindCandidateTests {

    @Test("phrase first, then distinct words of three letters or more, longest first")
    func candidates() {
        #expect(AppModel.findCandidates(for: "  oblivious transfer ")
            == ["oblivious transfer", "oblivious", "transfer"])
        #expect(AppModel.findCandidates(for: "LWE") == ["LWE"])
        #expect(AppModel.findCandidates(for: "a PRF, of LWE") == ["a PRF, of LWE", "PRF", "LWE"])
        #expect(AppModel.findCandidates(for: "prf PRF") == ["prf PRF", "prf"])
        #expect(AppModel.findCandidates(for: "   ").isEmpty)
    }
}

struct SettingsTests {

    @Test("a tool override round-trips and can be cleared")
    func toolOverrides() {
        // UserDefaults is process-wide; use a tool and clean up after.
        defer { CCwikiSettings.setToolOverride(nil, for: .node) }

        CCwikiSettings.setToolOverride("/opt/custom/bin/node", for: .node)
        #expect(CCwikiSettings.toolOverrides()[.node] == "/opt/custom/bin/node")

        CCwikiSettings.setToolOverride(nil, for: .node)
        #expect(CCwikiSettings.toolOverrides()[.node] == nil)
    }

    @Test("an override wins over discovery, and a bad one is ignored")
    func overridePrecedence() {
        // A real executable everyone has.
        #expect(ToolLocator.locate(.git, override: "/bin/sh") == "/bin/sh")
        // A path that is not executable falls back to the normal search.
        let resolved = ToolLocator.locate(.git, override: "/nonexistent/git")
        #expect(resolved != "/nonexistent/git")
    }

    @Test("only /usr/bin tools can be Apple's install-the-tools stubs")
    func appleStub() {
        #expect(ToolLocator.isAppleStub("/usr/bin/git"))
        #expect(!ToolLocator.isAppleStub("/opt/homebrew/bin/git"))
        #expect(!ToolLocator.isAppleStub("/usr/local/bin/git"))
        #expect(!ToolLocator.isAppleStub(NSHomeDirectory() + "/.local/bin/claude"))
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
