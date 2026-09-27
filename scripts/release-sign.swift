#!/usr/bin/env swift
//
// release-sign.swift — the Ed25519 half of shipping CCwiki without a
// Developer ID. See plans/distribution.md §3, "Tier 2b".
//
//   swift scripts/release-sign.swift keygen [key-file]
//       Make a key pair. The private key is written to key-file (default
//       ~/.config/ccwiki/release-key, mode 0600, base64 of the raw 32 bytes);
//       the public key is printed for Sources/CCwiki/App/ReleaseKey.swift.
//       `make release-keys` runs this and patches that file for you.
//
//   swift scripts/release-sign.swift sign <zip> [key-file]
//       Sign the zip's bytes. Writes <zip>.sig: base64 of the 64-byte
//       signature. The key file can also be named by $CCWIKI_RELEASE_KEY.
//
//   swift scripts/release-sign.swift verify <zip> <public-key-base64>
//       Check <zip>.sig against the public key — what the app does before
//       it installs anything. Exit 0 on success.
//
// Pure CryptoKit; no dependencies; runs under plain `swift`, like make-icon.

import CryptoKit
import Foundation

let arguments = CommandLine.arguments.dropFirst()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func defaultKeyPath() -> String {
    if let env = ProcessInfo.processInfo.environment["CCWIKI_RELEASE_KEY"], !env.isEmpty {
        return env
    }
    return NSHomeDirectory() + "/.config/ccwiki/release-key"
}

func readPrivateKey(at path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("no private key at \(path). Run `keygen` first, or set CCWIKI_RELEASE_KEY.")
    }
    guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("\(path) does not hold a base64 Ed25519 private key.") }
    return key
}

func readFile(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return data
}

switch arguments.first {
case "keygen":
    let path = arguments.dropFirst().first ?? defaultKeyPath()
    if FileManager.default.fileExists(atPath: path) {
        fail("\(path) already exists. Delete it first if you really mean to replace the key — "
            + "every app already installed trusts the old public key.")
    }
    let key = Curve25519.Signing.PrivateKey()
    let directory = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    let encoded = key.rawRepresentation.base64EncodedString() + "\n"
    guard FileManager.default.createFile(
        atPath: path, contents: Data(encoded.utf8),
        attributes: [.posixPermissions: 0o600])
    else { fail("could not write \(path)") }
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    print("private key: \(path)  (keep it; back it up; never commit it)")
    print("public key:  \(publicKey)")
    print("")
    print("Put the public key in Sources/CCwiki/App/ReleaseKey.swift, or run")
    print("`make release-keys`, which does both steps.")
    // The last line is machine-readable for the Makefile.
    print("PUBLIC_KEY=\(publicKey)")

case "sign":
    guard let zip = arguments.dropFirst().first else { fail("usage: sign <zip> [key-file]") }
    let keyPath = arguments.dropFirst(2).first ?? defaultKeyPath()
    let key = readPrivateKey(at: keyPath)
    let data = readFile(zip)
    guard let signature = try? key.signature(for: data) else { fail("signing failed") }
    let out = zip + ".sig"
    guard FileManager.default.createFile(
        atPath: out, contents: Data((signature.base64EncodedString() + "\n").utf8))
    else { fail("could not write \(out)") }
    print("✓ wrote \(out) (\(signature.count)-byte Ed25519 signature over \(data.count) bytes)")

case "verify":
    guard let zip = arguments.dropFirst().first,
          let publicText = arguments.dropFirst(2).first
    else { fail("usage: verify <zip> <public-key-base64>") }
    guard let publicRaw = Data(base64Encoded: publicText),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicRaw)
    else { fail("not a base64 Ed25519 public key") }
    let signatureText = String(decoding: readFile(zip + ".sig"), as: UTF8.self)
    guard let signature = Data(
        base64Encoded: signatureText.trimmingCharacters(in: .whitespacesAndNewlines))
    else { fail("\(zip).sig is not base64") }
    if publicKey.isValidSignature(signature, for: readFile(zip)) {
        print("✓ \(zip).sig verifies")
    } else {
        fail("\(zip).sig does NOT verify against the public key")
    }

default:
    fail("usage: release-sign.swift keygen [key-file] | sign <zip> [key-file] | verify <zip> <public-key>")
}
