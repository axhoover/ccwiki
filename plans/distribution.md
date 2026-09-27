# Distribution: a download that works, and updates that do not need a pipeline

How CCwiki gets from `make dist` on one Mac to "download, double-click, read",
and how a reader finds out there is a newer one. Written 2026-09-26 against
`d62b2b7`. The build system it extends is described in
[build-system.md](build-system.md); this document does not repeat it.

The state of play, verified: the repo has **no releases, no tags, no
`.github/` directory, no CI**, and `make dist` has never run. The release
half of the Makefile is the starter template's, with the template author's
signing identity still in it. `VERSION` says `0.1.0`.

---

## 1. Signing and notarization are not optional any more

Since macOS 15 the right-click → Open bypass for unsigned software is gone;
an un-notarized app downloaded in a browser can only be run by going to
System Settings → Privacy & Security and clicking "Open Anyway", and the
dialog that sends you there says the app "could not be verified". A
non-developer stops there. So for a public download the chain is:

```
Developer ID certificate  →  hardened runtime  →  notarize  →  staple  →  zip
```

which `make dist` already implements (`Makefile:225-292`). What it needs:

1. **An Apple Developer Program membership** (US$99/year) for the
   Developer ID Application certificate. There is no free path to a
   notarized app. If that is not wanted, the fallback is §5.
2. **Fix the template placeholders.** `CERT_NAME` defaulted to another
   developer's identity and `NOTARY_PROFILE` to `starter-notary`; this
   branch changes them to derive from `DEVELOPER_NAME` and to `ccwiki-notary`.
   The certificate's common name must match what Apple issues, exactly, so
   check it with `security find-identity -v -p codesigning` before the first
   `make dist`.
3. **Drop both hardened-runtime exceptions.** `CCwiki/CCwiki.entitlements`
   grants `disable-library-validation` and `allow-jit` on the reasoning that
   the app spawns `git`, `gh` and `claude` and that `claude` is a Node
   program. Neither follows: library validation governs dylibs loaded into
   *this* process, JIT applies to *this* process, and a child process gets
   its own code signature and entitlements. WKWebView's JavaScript runs in a
   separate WebContent process. Both entitlements weaken the hardened runtime
   for nothing and are the kind of thing notarization reviewers flag. Remove
   them, build a notarized copy, and run one ingestion job end to end to
   confirm; the review that produced this document could not run anything.
4. **Build universal.** **Done 2026-09-26:** `build.sh` passes
   `--arch arm64 --arch x86_64` for the release configuration and prints
   `lipo -info`. CI runs `make release` on every push and uploads the
   ad-hoc-signed `.app` as a workflow artifact, which is a build to try, not
   a build to ship.
5. **Tag before `dist`.** `check-version` refuses to run without an exact
   `vX.Y.Z` tag at HEAD (`Makefile:209-221`). The first release is
   `git tag v0.1.0 && make dist && make github-release`.

Keep `make run` ad-hoc signed; that is for the machine that built it.

## 2. A release workflow, so releases are not one person's laptop

A `.github/workflows/release.yml` triggered by a `v*` tag, on a `macos-15`
runner (Xcode is preinstalled):

1. Check out; `Resources/web/vendor` is committed (37 files), so no network
   step is needed for the render pipeline. Run `scripts/vendor-web.sh --check`
   anyway.
2. `make check` (compile plus the 101 unit tests). This is also the
   `pull_request` workflow; today no CI runs the suite.
3. Import the Developer ID certificate from a base64 `.p12` secret into a
   temporary keychain (the standard `security create-keychain` /
   `security import` / `security set-key-partition-list` sequence).
4. Notarize with an **App Store Connect API key** rather than the keychain
   profile: `xcrun notarytool submit --key --key-id --issuer`. The Makefile's
   `notarize` target hardcodes `--keychain-profile` (`Makefile:262-269`), so
   it needs a branch on `NOTARY_KEY` being set. `make notary-setup` stays
   for the laptop path.
5. `make dist` then `make github-release`, with `NOTES_FILE` generated from
   the commits since the previous tag.
6. Upload `build/shots/` from `make shots` as a workflow artifact? No: the
   runner has no Screen Recording grant and the in-app fallback capture is
   what it would produce. Leave the visual gate on a real Mac.

Secrets: `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_KEY`,
`NOTARY_KEY_ID`, `NOTARY_ISSUER`, `TEAM_ID`. None of them belong in the repo,
the Makefile, or a plan; that is why this list is names only.

## 3. Updates: three tiers, pick how far to go

The worry in the request was that updates "might require too complicated a
pipeline". Tier 1 is an afternoon and covers most of the value. Tier 3 is the
complicated pipeline, and it is optional.

### Tier 1: the app knows when it is out of date

**Built 2026-09-26** (`UpdateChecker`, Check for Updates… in the app menu,
Settings > About). It is inert until there is a release to find, and on a
`0.0.0` development build it does nothing at all.

One `URLSession` call to
`https://api.github.com/repos/axhoover/ccwiki/releases/latest`, at most
once a day, compare `tag_name` (minus the `v`) numerically against
`CFBundleShortVersionString`, and if newer:

- a line in Settings → About: "CCwiki 0.2.0 is available" with a button that
  opens the release page;
- one entry in the existing status-bar warnings channel (made dismissable,
  see [audit-2026-09.md](audit-2026-09.md) §2.10);
- an app-menu item "Check for Updates…" via `CommandGroup(after: .appInfo)`
  in `CCwikiApp.swift`.

Rules: silent when offline (the same posture as sync), a preference to turn
it off, no download and no install. The unauthenticated GitHub API allows 60
requests an hour per address, which a daily check does not approach. Zero
dependencies, no signing keys, no feed to maintain: the GitHub release *is*
the feed. Note the version is only real on tagged builds; `make install`
stamps `0.0.0` (`build.sh:25`), which should be treated as "development, do
not check".

### Tier 2: Homebrew does the updating

A cask in a personal tap (`axhoover/homebrew-tap`, file `Casks/ccwiki.rb`):

```ruby
cask "ccwiki" do
  version "0.1.0"
  sha256 "<from CCwiki-0.1.0-macos.zip.sha256>"
  url "https://github.com/axhoover/ccwiki/releases/download/v#{version}/CCwiki-#{version}-macos.zip"
  name "CCwiki"
  desc "Offline reader for the cryptology.city wiki"
  homepage "https://github.com/axhoover/ccwiki"
  depends_on macos: ">= :sonoma"
  app "CCwiki.app"
  zap trash: [
    "~/Library/Application Support/CCwiki",
    "~/Library/Caches/CCwiki",
  ]
end
```

Then `brew install axhoover/tap/ccwiki` installs and `brew upgrade` updates.
For this audience, which mostly has Homebrew already, this *is* the update
mechanism, and it needs no code in the app. The release workflow in §2 can
bump `version` and `sha256` in the tap with one `sed` and a push. The app
still needs to be notarized: Homebrew applies the quarantine attribute on
install, and Gatekeeper then checks it like any download.

### Tier 3: Sparkle, in-app download and relaunch

[Sparkle 2](https://sparkle-project.org) is the standard and is available as
a SwiftPM package. It costs, in this codebase specifically:

- the zero-dependency policy in `Package.swift` (recorded in
  [build-system.md](build-system.md));
- `build.sh` copies `*.bundle` but no frameworks (`build.sh:59-66`): it would
  need to copy `Sparkle.framework` into `Contents/Frameworks`, set the rpath,
  and sign the framework before the app (both `build.sh` and `make sign`
  sign once, not inside-out);
- an EdDSA key pair, `SUFeedURL` and `SUPublicEDKey` in `Info.plist`, and
  `generate_appcast` run against `dist/` in `make dist`, with the appcast
  published somewhere stable (GitHub Pages from the repo is the usual answer);
- a Sparkle-specific line in the cask (`auto_updates true`) so `brew upgrade`
  does not fight it.

Because the app is not sandboxed, Sparkle needs no XPC services, which
removes the worst of the setup. Do it only if Tier 1 plus Tier 2 leaves
people on old versions; there is no evidence of that until there are users.

### Tier 2b: automatic updates with no Developer ID at all

**Built 2026-09-27.** Written the day before, after the question "do we
really have to pay for this?" The answer is no, with one honest limit.

What exists: `scripts/release-sign.swift` (keygen, sign, verify; pure
CryptoKit), `Sources/CCwiki/App/ReleaseKey.swift` (the embedded public key),
`UpdateInstaller` (download, verify, unpack, check, swap, relaunch),
`make package` and `make github-release`, and
`.github/workflows/release.yml`, which does both on a `vX.Y.Z` tag.

**The maintainer's one-time setup, on a Mac:**

```sh
make release-keys          # writes ~/.config/ccwiki/release-key (0600), embeds the
                           # public key in ReleaseKey.swift — commit that change
```

Then either release from the laptop (`git tag v0.2.0 && make package &&
make github-release`) or let the workflow do it: put the contents of
`~/.config/ccwiki/release-key` in the repository secret
`CCWIKI_RELEASE_KEY` and push the tag. Back the key file up somewhere
private. Losing it does not break installed apps; it means the next release
has to be installed by hand once, carrying a new public key.

**What an installed app does.** Once a day it asks GitHub for the latest
release. If there is a newer one with a signed zip attached, and "Install
them automatically" is on (the default), it downloads the zip and its
`.sig`, verifies the signature against the embedded key, unpacks with
`ditto`, checks the bundle identifier, the version and the code signature,
moves the running bundle aside, moves the new one in, and puts the old one
in the Trash. It then says so in the status bar and waits: CCwiki > Relaunch
to Update. It never relaunches on its own, never installs while a job is
running, and never installs anything whose signature does not verify.

Gatekeeper assesses only files carrying the quarantine attribute, which
browsers add to what they download. A zip the app fetches itself with
`URLSession` is not quarantined (the app does not opt in to
`LSFileQuarantineEnabled`), the bundle extracted from it is not quarantined,
and a non-quarantined ad-hoc-signed app launches without a prompt on Intel
and Apple silicon alike. That is why `make install` works today. So:

1. **The first install carries friction, once.** On macOS 15 an
   un-notarized download can be opened only through System Settings →
   Privacy & Security → Open Anyway, or by installing from Terminal, since
   `curl` does not quarantine:

   ```sh
   curl -L -o /tmp/CCwiki.zip https://github.com/axhoover/ccwiki/releases/latest/download/CCwiki-macos.zip
   ditto -x -k /tmp/CCwiki.zip /Applications
   ```

   Acceptable for an audience that lives in a terminal; not for a general
   one. That is the whole of what the membership buys.
2. **Every later update is automatic and silent.** Tier 1's check finds the
   release; an installer step downloads the zip to a temporary directory,
   verifies it, extracts it with `ditto -x -k`, swaps the bundle in place
   (a running bundle can be moved; its mapped files stay valid), and
   relaunches with `NSWorkspace.OpenConfiguration.createsNewApplicationInstance`
   before terminating. No dialogs, because nothing is quarantined.

**Verification, done properly and for free.** Sign each release zip with an
Ed25519 key kept by the maintainer; embed the public key in the app; refuse
any update whose signature does not verify. `CryptoKit`'s
`Curve25519.Signing` does this with no dependency. TLS to github.com protects
the transport; the signature protects against a compromised GitHub account,
which the `.sha256` beside the zip does not. Key custody is the one decision
only the maintainer can make: the private key lives on one Mac (or as a CI
secret if the release workflow signs), and losing it means shipping a new
public key by hand once. A `scripts/release-keys.swift` generates the pair
and a `scripts/sign-release.swift` signs a zip; both are plain `swift`
scripts, like `make-icon.swift`.

Caveats: Homebrew fits worse without notarization (`brew install --cask`
quarantines, so users would need `--no-quarantine`); ad-hoc signatures change
per build, so a TCC grant tied to the app (Screen Recording for `make shots`)
resets after an update; and if the membership is ever bought, none of this
is wasted, since the same updater runs and the first-launch friction simply
disappears. Sparkle would also work without a Developer ID, by the same
EdDSA idea, at the framework-embedding cost in tier 3.

## 4. Two `Info.plist` additions that make the download feel like an app

- **`CFBundleDocumentTypes` for PDF** with `LSHandlerRank Alternate`, plus
  `onOpenURL` / `application(_:open:)` handling. Dropping a paper on the Dock
  icon then opens the ingest sheet; today only the reader window is a drop
  target (`RootView.swift:44`). Also puts CCwiki in Finder's "Open With".
- **`CFBundleURLTypes` for `ccwiki://`.** The scheme is already the reader's
  internal one (`Reader/CCwikiURL.swift`), so an OS-level registration plus
  `onOpenURL` gives deep links for free: `ccwiki://page/Primitives/prf` from
  a note, a mail, or a future "Open in CCwiki" link on the website.

## 5. If there is no Developer ID

Then the honest options are: distribute only through Homebrew with
instructions to run `xattr -dr com.apple.quarantine /Applications/CCwiki.app`
(developers will, nobody else will), or distribute source and `make install`
(the status quo). Neither is a download for a stranger. The membership is
the cheapest part of this whole plan.

## 6. Order

1. Membership, certificate, placeholders, entitlements, universal build,
   `v0.1.0`, `make dist` by hand once. Confirm Gatekeeper accepts the zip on
   a Mac that did not build it.
2. `release.yml` and a `pull_request` workflow running `make check`.
3. Tier 1 update check in the app.
4. The tap, bumped by the workflow.
5. The two `Info.plist` additions.
6. Sparkle, if ever.
