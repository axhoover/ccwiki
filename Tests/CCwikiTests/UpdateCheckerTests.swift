import Foundation
import Testing
@testable import CCwiki

/// The update check has no network in the tests; what it does with an answer
/// is what matters.
struct UpdateCheckerTests {

    @Test("versions compare component-wise, not as strings")
    func comparison() {
        #expect(UpdateChecker.isNewer("0.2.0", than: "0.1.0"))
        #expect(UpdateChecker.isNewer("1.10.0", than: "1.9.0"))
        #expect(UpdateChecker.isNewer("v1.0.1", than: "1.0.0"))
        #expect(UpdateChecker.isNewer("1.0.0.1", than: "1.0.0"))
        #expect(!UpdateChecker.isNewer("1.2", than: "1.2.0"))
        #expect(!UpdateChecker.isNewer("1.2.0", than: "1.2"))
        #expect(!UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
        #expect(!UpdateChecker.isNewer("0.1.0", than: "0.2.0"))
        // A pre-release suffix is ignored rather than mis-parsed.
        #expect(UpdateChecker.isNewer("0.2.0-rc1", than: "0.1.0"))
        #expect(UpdateChecker.components("garbage") == [0])
    }

    @Test("a development build is recognized and never compared")
    func development() {
        #expect(UpdateChecker.isDevelopmentVersion("0.0.0"))
        #expect(UpdateChecker.isDevelopmentVersion("0.0"))
        #expect(!UpdateChecker.isDevelopmentVersion("0.1.0"))
    }

    @Test("the release payload yields a version and a page")
    func parse() throws {
        let json = """
            {"tag_name": "v0.2.0", "name": "CCwiki 0.2.0",
             "html_url": "https://github.com/axhoover/ccwiki/releases/tag/v0.2.0",
             "draft": false, "prerelease": false, "assets": []}
            """
        let release = try UpdateChecker.parse(Data(json.utf8))
        #expect(release?.version == "0.2.0")
        #expect(release?.url.absoluteString == "https://github.com/axhoover/ccwiki/releases/tag/v0.2.0")
    }

    @Test("a pre-release or draft is never offered")
    func prerelease() throws {
        let json = """
            {"tag_name": "v0.3.0-beta", "html_url": "https://example.com", "prerelease": true}
            """
        #expect(try UpdateChecker.parse(Data(json.utf8)) == nil)
    }

    @Test("a malformed payload is an error, not a spurious update")
    func malformed() {
        #expect(throws: UpdateChecker.Failure.badPayload) {
            try UpdateChecker.parse(Data("not json".utf8))
        }
        #expect(throws: UpdateChecker.Failure.badPayload) {
            try UpdateChecker.parse(Data(#"{"tag_name": "v1"}"#.utf8))
        }
    }
}
