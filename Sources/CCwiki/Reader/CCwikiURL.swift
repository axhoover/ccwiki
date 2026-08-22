import Foundation

/// The `ccwiki://wiki/…` URL space.
///
/// One custom scheme serves the reader from two roots — the vendored pipeline
/// inside the app bundle and the wiki clone in Application Support — which is
/// the thing `loadFileURL(_:allowingReadAccessTo:)` cannot do, since it grants
/// exactly one directory per load and those two have no useful common
/// ancestor.
///
/// ```
/// ccwiki://wiki/_/index.html                     the shell + vendored JS/CSS
/// ccwiki://wiki/asset/Files/Minicrypt.png        a file from the clone
/// ccwiki://wiki/page/Primitives%2Fprf.md#syntax  a page (never actually loaded;
///                                                  the click handler intercepts it)
/// ccwiki://wiki/folder/Primitives                a synthetic folder listing
/// ```
enum CCwikiURL {

    static let scheme = "ccwiki"
    static let host = "wiki"
    static let base = "\(scheme)://\(host)"

    static let shell = URL(string: "\(base)/_/index.html")!

    /// Characters that may appear unescaped in a path segment. Deliberately
    /// narrow: reference filenames contain `&`, `?`, `#`, `!`, `'` and commas,
    /// every one of which changes what a URL means.
    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func page(path: String, anchor: String? = nil) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? path
        return "\(base)/page/\(encoded)" + (anchor.map { "#\($0)" } ?? "")
    }

    static func folder(slug: String) -> String {
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? slug
        return "\(base)/folder/\(encoded)"
    }

    static func asset(path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? path
        return "\(base)/asset/\(encoded)"
    }

    /// What a `ccwiki://` URL points at, for the click handler to act on.
    enum Destination: Equatable, Sendable {
        case page(path: String, anchor: String?)
        case folder(slug: String)
        case asset(path: String)
        case shell
    }

    static func destination(of string: String) -> Destination? {
        guard let url = URL(string: string), url.scheme == scheme else { return nil }

        let anchor = url.fragment(percentEncoded: false).flatMap { $0.isEmpty ? nil : $0 }
        var components = url.path(percentEncoded: false)
            .components(separatedBy: "/")
            .filter { !$0.isEmpty }
        guard let kind = components.first else { return nil }
        components.removeFirst()
        let rest = components.joined(separator: "/")

        switch kind {
        case "page": return .page(path: rest, anchor: anchor)
        case "folder": return .folder(slug: rest)
        case "asset": return .asset(path: rest)
        case "_": return .shell
        default: return nil
        }
    }
}
