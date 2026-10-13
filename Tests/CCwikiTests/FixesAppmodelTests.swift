import Foundation
import Testing
@testable import CCwiki

/// The app model's fixes from the October audit: the update check across a
/// relaunch and across days of running, tools installed while the app
/// runs, the staged web copy losing its files, and a snapshot store
/// mistaken for a clone.
@Suite
struct FixesAppmodelTests {

    private static let hour: TimeInterval = 60 * 60

    // MARK: The update check

    @Test("a release found is asked for again at the next launch; nothing newer holds it off a day")
    func persistedUpdateCheck() throws {
        let now = Date()
        let page = try #require(URL(string: "https://github.com/axhoover/ccwiki/releases/tag/v0.3.1"))
        let found = UpdateChecker.Outcome.available(ReleaseInfo(version: "0.3.1", url: page))

        #expect(AppModel.persistedUpdateCheck(now, after: found) == nil)
        #expect(AppModel.persistedUpdateCheck(now, after: .upToDate) == now)
        #expect(AppModel.persistedUpdateCheck(now, after: .noReleases) == now)

        // Relaunched two hours after the check that found 0.3.1: the launch
        // asks again rather than say "Up to date".
        let relaunch = now.addingTimeInterval(2 * Self.hour)
        #expect(AppModel.isUpdateCheckDue(
            lastCheck: AppModel.persistedUpdateCheck(now, after: found), now: relaunch))
        #expect(!AppModel.isUpdateCheckDue(
            lastCheck: AppModel.persistedUpdateCheck(now, after: .upToDate), now: relaunch))
    }

    @Test("a copy left open asks GitHub once a day, from its hourly chores")
    func dailyWhileRunning() {
        let last = Date()
        #expect(AppModel.isUpdateCheckDue(lastCheck: nil, now: last))
        #expect(!AppModel.isUpdateCheckDue(lastCheck: last, now: last.addingTimeInterval(Self.hour)))
        #expect(!AppModel.isUpdateCheckDue(lastCheck: last, now: last.addingTimeInterval(23 * Self.hour)))
        #expect(AppModel.isUpdateCheckDue(
            lastCheck: last, now: last.addingTimeInterval(AppModel.updateInterval)))
        #expect(AppModel.choresInterval < .seconds(AppModel.updateInterval),
                "the chores come round more often than the check falls due")
    }

    // MARK: Tools installed while the app runs

    @Test("a tool installed since the last look is found by a stat; Apple's git stub is no news")
    func toolArrival() throws {
        let bin = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bin) }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let directory = bin.path(percentEncoded: false)

        #expect(!AppModel.toolArrived([.gh], stubbedGit: false, in: [directory]))
        try Self.makeFile(bin.appending(path: "gh"), executable: true)
        #expect(AppModel.toolArrived([.gh], stubbedGit: false, in: [directory]))
        #expect(AppModel.toolArrived([.claude, .gh], stubbedGit: false, in: [directory]))
        #expect(!AppModel.toolArrived([.claude], stubbedGit: false, in: [directory]))

        // A file that cannot be run is not the tool.
        try Self.makeFile(bin.appending(path: "node"), executable: false)
        #expect(!AppModel.toolArrived([.node], stubbedGit: false, in: [directory]))

        // While git is only the stub, finding the stub again changes nothing;
        // a real git found before it does.
        #expect(!AppModel.toolArrived([.git], stubbedGit: true, in: ["/usr/bin"]))
        try Self.makeFile(bin.appending(path: "git"), executable: true)
        #expect(AppModel.toolArrived([.git], stubbedGit: true, in: [directory, "/usr/bin"]))
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/git") {
            #expect(!AppModel.toolArrived([.git], stubbedGit: true, in: ["/usr/bin", directory]),
                    "discovery takes the stub first, as this order does")
        }
    }

    // MARK: The staged web copy

    @Test("a staged web copy still there is marked in use")
    func webCopyKept() throws {
        let scene = try WebCopyScene()
        defer { scene.remove() }
        let monthAgo = Date().addingTimeInterval(-30 * 24 * Self.hour)
        try FileManager.default.setAttributes(
            [.modificationDate: monthAgo], ofItemAtPath: scene.staged.path(percentEncoded: false))

        let kept = scene.paths.keepStagedWebRoot(
            scene.staged, bundleBuild: "a-newer-build", from: scene.bundle)
        #expect(kept)
        let touched = try #require(try Self.modificationDate(of: scene.staged))
        #expect(touched > Date().addingTimeInterval(-Self.hour), "another build's prune leaves it")
    }

    @Test("a staged web copy deleted while the app runs is staged again from the same build")
    func webCopyRestaged() throws {
        let scene = try WebCopyScene()
        defer { scene.remove() }
        try FileManager.default.removeItem(at: scene.staged)

        let kept = scene.paths.keepStagedWebRoot(
            scene.staged, bundleBuild: AppPaths.stagedWebBuild, from: scene.bundle)
        #expect(kept)
        #expect(FileManager.default.fileExists(
            atPath: scene.staged.appending(path: "index.html").path(percentEncoded: false)))
    }

    @Test("an updated bundle is never staged as this build's copy")
    func webCopyNotFromAnotherBuild() throws {
        let scene = try WebCopyScene()
        defer { scene.remove() }
        try FileManager.default.removeItem(at: scene.staged)

        let kept = scene.paths.keepStagedWebRoot(
            scene.staged, bundleBuild: "a-newer-build", from: scene.bundle)
        #expect(!kept)
        #expect(!FileManager.default.fileExists(atPath: scene.staged.path(percentEncoded: false)))
    }

    @Test("a launch served from the bundle leaves the bundle alone")
    func bundleServedAsIs() throws {
        let scene = try WebCopyScene()
        defer { scene.remove() }
        let monthAgo = Date().addingTimeInterval(-30 * 24 * Self.hour)
        try FileManager.default.setAttributes(
            [.modificationDate: monthAgo], ofItemAtPath: scene.bundle.path(percentEncoded: false))

        let kept = scene.paths.keepStagedWebRoot(scene.bundle, bundleBuild: nil, from: scene.bundle)
        #expect(kept)
        let date = try #require(try Self.modificationDate(of: scene.bundle))
        #expect(abs(date.timeIntervalSince(monthAgo)) < 1)
    }

    // MARK: A snapshot is not a clone

    @Test("a snapshot blocks an ingestion, in place of the clone's push blocker")
    func snapshotBlocksIngestion() {
        func blockers(
            _ store: AppPaths.WikiStore?, missing: [ToolLocator.Tool] = [],
            stubbedGit: Bool = false, gh: Bool = true, canPush: Bool = false
        ) -> [String] {
            AppModel.ingestionBlockers(
                store: store, missing: missing, needsDeveloperTools: stubbedGit,
                ghPresent: gh, isGitHubAuthenticated: gh, canPushToRemote: canPush)
        }

        #expect(blockers(.snapshot) == [CorrectionBlockers.snapshot])
        #expect(blockers(.snapshot, canPush: true) == [CorrectionBlockers.snapshot])
        #expect(blockers(.git, canPush: true).isEmpty)
        let clone = blockers(.git)
        #expect(clone.count == 1)
        #expect(clone.first?.hasPrefix("CCwiki's clone cannot authenticate a push") == true)
        #expect(blockers(nil).first == "The wiki has not been cloned yet. Sync first (⌘R).")

        // Without the Command Line Tools: install them, then sync.
        let stubbed = blockers(.snapshot, missing: [.git], stubbedGit: true, gh: false)
        #expect(stubbed.count == 2)
        #expect(stubbed.first?.hasPrefix("git needs Apple's Command Line Tools") == true)
        #expect(stubbed.last == CorrectionBlockers.snapshot)
    }

    // MARK: Helpers

    private static func makeFile(_ url: URL, executable: Bool) throws {
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path(percentEncoded: false))
    }

    private static func modificationDate(of url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false))[.modificationDate] as? Date
    }
}

/// A bundle's `web` folder and this build's staged copy of it, in a
/// scratch tree.
private struct WebCopyScene {
    let root: URL
    let paths: AppPaths
    let bundle: URL
    let staged: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-web-keep-\(UUID().uuidString)")
        paths = AppPaths(support: root.appending(path: "support"))
        bundle = root.appending(path: "bundle-web")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("<!doctype html>".utf8).write(to: bundle.appending(path: "index.html"))
        staged = paths.stagedWebRoot(from: bundle)
        try #require(staged != bundle, "the copy was made")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
