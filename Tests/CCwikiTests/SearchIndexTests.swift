import Foundation
import Testing
@testable import CCwiki

/// What goes into the FTS body column decides what a snippet looks like.
struct IndexableBodyTests {

    @Test("markdown markers do not survive into snippets")
    func markersStripped() {
        let body = """
            ## Syntax

            A **pseudorandom function** is a family $F$ such that:

            - the *key* is secret
            1. and the `output` looks random
            > as Goldreich, Goldwasser and Micali put it
            """
        let text = SearchIndex.indexableBody(body)
        #expect(!text.contains("##"))
        #expect(!text.contains("**"))
        #expect(!text.contains("- the"))
        #expect(!text.contains("1. and"))
        #expect(!text.contains("> as"))
        #expect(!text.contains("`"))
        #expect(text.contains("Syntax"))
        #expect(text.contains("pseudorandom function"))
        #expect(text.contains("the key is secret"))
        #expect(text.contains("as Goldreich"))
    }

    @Test("underscores inside identifiers are left alone")
    func identifiers() {
        let text = SearchIndex.indexableBody("set `cryptobib_key` and _emphasis_ here")
        #expect(text.contains("cryptobib_key"))
        #expect(text.contains(" emphasis here"))
    }

    @Test("wikilinks index their target and their label")
    func wikilinks() {
        let text = SearchIndex.indexableBody("see [[pseudorandom-function|PRFs]] and [[Primitives]]")
        #expect(text.contains("pseudorandom-function PRFs"))
        #expect(text.contains("Primitives"))
        #expect(!text.contains("[["))
    }
}
