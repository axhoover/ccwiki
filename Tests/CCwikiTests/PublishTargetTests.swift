import Testing
@testable import CCwiki

/// Where pull requests and issues go, per build (plans/corrections.md §10,
/// §12.1).
struct PublishTargetTests {

    static let wiki = "axhoover/cryptology.city"
    static let fork = "someone/cryptology.city"

    @Test("the release targets the wiki and ignores CCWIKI_TARGET_REPO")
    func releaseIgnoresTheVariable() {
        let target = PublishTarget.resolve(
            channel: .release, environment: ["CCWIKI_TARGET_REPO": Self.fork])
        #expect(target == PublishTarget(
            repository: Self.wiki, pushURL: "origin", isDevBuild: false, isOverridden: false))
    }

    @Test("Dev targets the same wiki, and says it is Dev")
    func devDefault() {
        let target = PublishTarget.resolve(channel: .dev, environment: [:])
        #expect(target == PublishTarget(
            repository: Self.wiki, pushURL: "origin", isDevBuild: true, isOverridden: false))
    }

    @Test("Dev honours a valid owner/name, pushing to its GitHub URL")
    func devHonoursAFork() {
        let target = PublishTarget.resolve(
            channel: .dev, environment: ["CCWIKI_TARGET_REPO": Self.fork])
        #expect(target.repository == Self.fork)
        #expect(target.pushURL == "https://github.com/someone/cryptology.city.git")
        #expect(target.isDevBuild && target.isOverridden)
    }

    @Test("Dev ignores a value that is not owner/name")
    func devIgnoresInvalid() {
        for value in ["", "nonsense", "a/b/c", "/name", "owner/", "own er/name", "owner/name\n"] {
            let target = PublishTarget.resolve(channel: .dev, environment: ["CCWIKI_TARGET_REPO": value])
            #expect(target.repository == Self.wiki, "\(value)")
            #expect(target.pushURL == "origin")
            #expect(!target.isOverridden)
            #expect(!PublishTarget.isRepositorySlug(value), "\(value)")
        }
    }

    @Test("naming the wiki itself overrides nothing, and pushes to the clone's own remote")
    func devNamingTheWiki() {
        let target = PublishTarget.resolve(
            channel: .dev, environment: ["CCWIKI_TARGET_REPO": "AXHoover/Cryptology.City"])
        #expect(target.repository == Self.wiki)
        #expect(target.pushURL == "origin")
        #expect(!target.isOverridden)
    }
}
