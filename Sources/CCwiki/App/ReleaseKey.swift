import CryptoKit
import Foundation

/// The public half of the key that signs CCwiki releases.
///
/// The updater refuses to install anything whose `.sig` does not verify
/// against this key, so a release can only come from whoever holds the
/// private half — whatever happens to the GitHub account in between. The
/// key is made once with `make release-keys`, which writes the private key
/// to `~/.config/ccwiki/release-key` and fills the string below in.
///
/// Empty means "no key configured": the app still *reports* updates and
/// opens the release page, but never installs one. That is the state of a
/// checkout before the maintainer has run `make release-keys`.
enum ReleaseKey {

    /// Base64 of the raw 32-byte Ed25519 public key. Filled in by `make release-keys`.
    static let publicKeyBase64 = "KZSDkcGTSAxklgzh6zUEVGRElL5uu51X3IdxKKERhyY="

    static var publicKey: Curve25519.Signing.PublicKey? {
        guard let raw = Data(base64Encoded: publicKeyBase64), raw.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    static var isConfigured: Bool { publicKey != nil }
}
