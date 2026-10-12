import Foundation
import JavaScriptCore
@testable import CCwiki

/// `Resources/web/ccwiki-markdown.js` in JavaScriptCore, without a web view
/// (plans/corrections.md §3.2, §12.1): the vendored markdown-it, its
/// footnote and mark plugins and GithubSlugger, as `index.html` loads them,
/// a stub `katex` whose `renderToString` returns its input, then the file.
///
/// If JavaScriptCore cannot load a bundle, `load()` throws and says which:
/// that is the risk corrections §13 names, and the tests fail loudly on it.
struct MarkdownScript {

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The source tree's web root, found from this file.
    static let webRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CCwikiTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // the package
        .appending(path: "Resources/web")

    /// Loaded in this order, as `index.html` loads them.
    static let scripts = [
        "vendor/markdown-it/markdown-it.umd.min.js",
        "vendor/markdown-it/markdown-it-footnote.min.js",
        "vendor/markdown-it/markdown-it-mark.min.js",
        "vendor/markdown-it/github-slugger.umd.js",
        "ccwiki-markdown.js",
    ]

    /// markdown-it decodes its entity tables with `atob`, which a web view
    /// has and a bare JavaScriptCore context may not; and KaTeX, which the
    /// math renderers call, replaced by its input.
    static let prelude = """
        if (typeof atob !== "function") {
          this.atob = function (input) {
            var alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            var text = String(input).replace(/[\\s=]+/g, "");
            var out = "", buffer = 0, bits = 0;
            for (var i = 0; i < text.length; i++) {
              var value = alphabet.indexOf(text.charAt(i));
              if (value < 0) throw new Error("atob: not base64");
              buffer = ((buffer << 6) | value) & 0xffffff;
              bits += 6;
              if (bits >= 8) {
                bits -= 8;
                out += String.fromCharCode((buffer >> bits) & 0xff);
              }
            }
            return out;
          };
        }
        var katex = { renderToString: function (tex) { return tex; } };
        """

    let context: JSContext

    /// A fresh context with everything loaded, and `md`, an instance made
    /// with no macros.
    static func load() throws -> MarkdownScript {
        let context: JSContext = JSContext()
        let script = MarkdownScript(context: context)
        try script.evaluate(prelude, named: "prelude.js")
        for name in scripts {
            let url = webRoot.appending(path: name)
            let source = try String(contentsOf: url, encoding: .utf8)
            try script.evaluate(source, named: name)
        }
        try script.evaluate("var md = CCwikiMarkdown.create({});", named: "setup.js")
        return script
    }

    /// Runs `source`, and throws with the exception it raised, if any.
    @discardableResult
    func evaluate(_ source: String, named name: String = "test.js") throws -> JSValue? {
        context.exception = nil
        let value = context.evaluateScript(source, withSourceURL: URL(string: "file:///" + name))
        if let exception = context.exception {
            throw Failure(description: "\(name): \(exception.toString() ?? "an exception")")
        }
        return value
    }

    /// `expression`'s value, through `JSON.stringify`, decoded.
    func json(_ expression: String) throws -> Any {
        let value = try evaluate("JSON.stringify(\(expression));")
        guard let text = value?.toString(), let data = text.data(using: .utf8) else {
            throw Failure(description: "No JSON from \(expression)")
        }
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    /// `text` as a JavaScript string literal.
    static func literal(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: []),
              let array = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    /// An object for a script, as JSON.
    static func literal(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// `markdown` rendered as the reader renders a page, links unresolved.
    func render(_ markdown: String) throws -> String {
        guard let html = try evaluate("md.render(\(Self.literal(markdown)), { links: {} });")?.toString()
        else { throw Failure(description: "No HTML.") }
        return html
    }
}

/// One element the renderer stamped with its source lines.
struct StampedBlock: Equatable {
    let tag: String
    let className: String
    /// 0-based, half-open, in the markdown rendered.
    let lines: Range<Int>
    /// Stamped as pseudocode is, `ccwiki-lines`, for `ccwiki.js` to move.
    let isPseudocode: Bool

    private static let tagPattern = try! NSRegularExpression(pattern: "<([a-z][a-z0-9]*)(\\s[^>]*)?>")
    private static let linesPattern = try! NSRegularExpression(
        pattern: "\\s(data-source-lines|ccwiki-lines)=\"(\\d+)-(\\d+)\"")
    private static let classPattern = try! NSRegularExpression(pattern: "\\sclass=\"([^\"]*)\"")

    /// Every stamped opening tag in `html`, in order.
    static func all(in html: String) -> [StampedBlock] {
        let whole = NSRange(html.startIndex..., in: html)
        return tagPattern.matches(in: html, range: whole).compactMap { match in
            guard let tagRange = Range(match.range(at: 1), in: html),
                  let attributesRange = Range(match.range(at: 2), in: html)
            else { return nil }
            let attributes = String(html[attributesRange])
            let span = NSRange(attributes.startIndex..., in: attributes)
            guard let lines = linesPattern.firstMatch(in: attributes, range: span),
                  let kind = Range(lines.range(at: 1), in: attributes),
                  let first = Range(lines.range(at: 2), in: attributes).flatMap({ Int(attributes[$0]) }),
                  let end = Range(lines.range(at: 3), in: attributes).flatMap({ Int(attributes[$0]) })
            else { return nil }
            let className = classPattern.firstMatch(in: attributes, range: span)
                .flatMap { Range($0.range(at: 1), in: attributes) }
                .map { String(attributes[$0]) } ?? ""
            return StampedBlock(
                tag: String(html[tagRange]), className: className, lines: first..<end,
                isPseudocode: attributes[kind] == "ccwiki-lines")
        }
    }
}
