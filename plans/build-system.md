# Build system

No Xcode project, no `xcodebuild`, no XcodeGen. `swift build` compiles; a shell
script bundles and signs; `make` orchestrates. Xcode is only a toolchain
provider (`swift`, `codesign`, `notarytool`, `stapler`).

## The pieces

- **`Package.swift`** — one `executableTarget` (`CCwiki`) + one `testTarget`.
  Swift 6 language mode. Zero third-party dependencies.
- **`build.sh`** — stamp the Info.plist for `CHANNEL` (see "Two channels"
  below) → `swift build` → assemble `build/CCwiki Dev.app`, or
  `build/CCwiki.app` for the release channel (the stamped
  Info.plist, `PkgInfo`, any dependency `*.bundle`s copied into
  `Contents/Resources`, the icon) → codesign. Falls back to ad-hoc signing
  (`-`) when no real identity is available, so `make run` always works on a
  bare machine.
- **`scripts/stamp-info-plist.sh`** — `<channel> <version> <build> <src>
  <dst>`: fills in the Info.plist's placeholders for one channel, refuses a
  release version that is not `X.Y.Z`, and fails if any `__PLACEHOLDER__`
  survives. Plain bash and sed, so it also runs on Linux.
- **`Makefile`** — the front door. `make help` lists everything.
- **`Resources/Info.plist`** — bundle metadata. The identity (`__BUNDLE_ID__`,
  `__BUNDLE_NAME__`, `__URL_NAME__`, `__URL_SCHEME__`) and the version strings
  (`__SHORT_VERSION__`, `__BUILD_VERSION__`) are placeholders filled at build
  time; `BuildIdentityTests` fails if one goes missing.
- **`CCwiki/CCwiki.entitlements`** — App Sandbox **off**, deliberately. See
  "The app is not sandboxed" below; the template's default was on, and CCwiki
  cannot use it.

## Permissions & capabilities

OS capabilities work in this no-Xcode, ad-hoc-signed bundle — you just have to
add the keys by hand, because there's no Xcode "Signing & Capabilities" tab
doing it for you:

- **Usage prompts** need the matching `NS…UsageDescription` string in
  `Resources/Info.plist`. CoreLocation, for example, prompts and returns a fix
  with `NSLocationUsageDescription` (+ `NSLocationWhenInUseUsageDescription`)
  present — ad-hoc signing and the hand-assembled `.app` are not a barrier.
- **The sandbox decides the entitlement.** With the App Sandbox **off**, a
  usage-description string is enough. With it **on**, also add the matching
  `com.apple.security.*` entitlement (e.g.
  `com.apple.security.personal-information.location`).
- **Always design the denied path.** A permission the user declines should
  route to a sensible default, not a dead feature — e.g. a one-shot location
  request that yields `nil` falls back to a configured location.

## Everyday targets

| Target        | What it does                                              |
|---------------|----------------------------------------------------------|
| `make check`  | `swift build` only — fast compile gate for CI/agents      |
| `make test`   | `swift test` (swift-testing)                              |
| `make run`    | build the `.app`, ad-hoc sign, `open` it                 |
| `make` / build| `build/CCwiki Dev.app` (debug)                          |
| `make install`| build, copy to `/Applications/CCwiki Dev.app`, `lsregister -f` it |
| `make uninstall` / `register` | remove, or re-register, that installed copy |
| `make icon`   | regenerate `build/AppIcon.icns`                          |
| `make clean`  | remove `build/ .build/ dist/`                            |

Every app these build is CCwiki Dev. `make install CHANNEL=release` (and
`uninstall`, `register`) act on `/Applications/CCwiki.app` instead; that
build needs an `X.Y.Z` version, so an exact tag or `VERSION=`.

## Versioning

`make` resolves the version in this order: a `VERSION=` override → an exact
`vX.Y.Z` git tag at HEAD → the latest tag (or the `VERSION` file) plus `-dev`.
`make print-version` shows what resolved and from where, the channel, what
that builds and where `make install` would put it.

## Two channels: CCwiki and CCwiki Dev

A build's identity is chosen by `CHANNEL`, never by its version string: a
`make` at an exact tag stamps a bare `0.1.3`, which looks like a release. The
default is `dev`. See [update-integrity.md](update-integrity.md) §2.1 for
why: an old local build that called itself the release, shared its bundle
id and kept coming back is what made CCwiki seem to revert to 0.1.0.

| | `CHANNEL=release` | `CHANNEL=dev` (the default) |
|---|---|---|
| Made by | `make package`, `make dist` (so `release.yml`) | `./build.sh`, `make`, `make run`, `make release`, `make shots`, CI's PR zip |
| `CFBundleIdentifier` | `com.axhoover.ccwiki` | `com.axhoover.ccwiki.dev` |
| Name (`CFBundleName`, `CFBundleDisplayName`) | CCwiki | CCwiki Dev |
| URL scheme | `ccwiki` | `ccwiki-dev` |
| Version | `X.Y.Z`, refused otherwise (and `0.0.0`) | gets a `-dev` suffix if it lacks one |
| Data | `~/Library/Application Support/CCwiki`, `~/Library/Caches/CCwiki` | `…/CCwiki-Dev` in both |
| Updates | checks, installs | never checks, never installs |
| `make install` puts it at | `/Applications/CCwiki.app` | `/Applications/CCwiki Dev.app` |

The bundle is named for the channel too: `build/CCwiki Dev.app` for dev,
`build/CCwiki.app` for the release. Finder, the Dock and ⌘-Tab show the file
name, and a dev build named `CCwiki.app` could be dragged over the release
in /Applications. `build.sh` removes a CCwiki Dev bundle left at
`build/CCwiki.app` by a build from before the rename. The release steps of
`make package` and `make dist` run as sub-makes with `CHANNEL=release`, so
each finds `build/CCwiki.app`.

The separate bundle id keeps UserDefaults, saved window state, WebKit's data,
URL caches and LaunchServices apart on its own: a dev build cannot win
`ccwiki://` links, Open With or `open -b com.axhoover.ccwiki` from the
release. The data folders are the app's business:
`BuildIdentity.dataFolderName(for:)`, read by `AppPaths.standard()`. The dev
one has no space because ingestion worktrees live under Caches, where a `%20`
breaks the wiki's node tooling.

So a dev build **downloads its own copy of the wiki on first launch**, into
`Application Support/CCwiki-Dev/repo`, and builds its own search index. It
never reads or writes the release's clone, index, jobs or settings, and the
release never sees the dev build's. Only the release inherits a CityDesk
folder from before the rename.

In the app, `BuildIdentity.isRelease` gates the updater: the daily check, the
automatic install and `canInstallUpdates` all require it, whatever the
version says. Check for Updates… on CCwiki Dev explains that it does not
update itself; Settings → About calls it a development build and disables
the update switches. CCwiki Dev answers to `ccwiki-dev://wiki/page/…` links
and reads them as the reader's own `ccwiki://`, which is the same on both
channels.

`CFBundleVersion` is the build time in UTC (`date -u +%Y%m%d%H%M`), so local
and CI build numbers compare.

`make test-corpus` reads the release's clone,
`~/Library/Application Support/CCwiki/repo`, by default. The tests only read
it, so that is safe while CCwiki runs; point `WIKI=` at
`…/CCwiki-Dev/repo` to test against CCwiki Dev's copy instead. It stops
with an error when `WIKI` has no `content/` folder: the corpus suites skip
themselves without a clone, so on a Mac with only CCwiki Dev the default
would otherwise pass having tested nothing.

`make shots` drives `build/CCwiki Dev.app`, which is CCwiki Dev: its first run
downloads the wiki into `CCwiki-Dev` (run `make run` once first if the
harness's wait runs out). It finds the window to capture by the pid of the
process it started, so a release open beside it is never captured.

CI checks both sides. On every push, a step that builds nothing stamps the
release channel into a temp file and asserts `com.axhoover.ccwiki`, the
version and the `ccwiki` scheme, and that `0.1.3-dev` and `0.0.0` are
refused. Where CI builds the app (pull requests, `main`, manual runs), it
asserts the result is `com.axhoover.ccwiki.dev`, a `-dev` version and
`ccwiki-dev`. The zip it uploads unpacks as `CCwiki Dev.app`, the name
`make install` uses, so dragging it into `/Applications` never offers to
replace the release.

## Release pipeline (`make dist`)

Requires an exact `vX.Y.Z` tag at HEAD and a Developer ID signing identity.
The chain is deliberately ordered:

```
clean → release → sign → zip-notary → notarize → staple → zip-release → checksum → verify-release
```

The two-zip dance is intentional: Apple's notary service takes a zip; stapling
writes the ticket back into the `.app`; the zip you actually ship must be made
**after** stapling. One-time credential setup:

```sh
make notary-setup TEAM_ID=XXXXXXXXXX APPLE_ID=you@example.com
```

`make github-release` uploads the release zip + `.sha256` to a GitHub release.

`make dist` and `make package` build with `CHANNEL=release` whatever
`CHANNEL` says on the command line. Their last step, `make verify-package`,
reads `CCwiki.app/Contents/Info.plist` out of the zip itself and refuses the
package unless its `CFBundleIdentifier` is `com.axhoover.ccwiki` and its
`CFBundleShortVersionString` is the tag's version, so a CCwiki Dev build can
never be published as the release.

## CI gate

The minimum a change must pass: `make check && make test`. The minimum a *UI*
change must pass: also `make run` and look at it — see `SWIFTUI-RULES.md` §9.

`.github/workflows/ci.yml` runs `make check` on a `macos-15` runner for every
push and pull request, after `scripts/vendor-web.sh --check`. That is the
compile-and-unit-test half of the gate; `make shots` and `make test-corpus`
need a real Mac with a display and a clone, and stay manual.


---

# CCwiki additions

The sections above are the template's build system, and they still describe it
accurately. Four things are specific to this app.

## Vendored web resources are plain files, not a SwiftPM bundle

`build.sh` copies `Resources/web/` into `Contents/Resources/web`. It is
deliberately **not** a SwiftPM `resources:` declaration, and this is not a style
preference:

SwiftPM's generated accessor resolves `Bundle.module` against
`Bundle.main.bundleURL`, which for an app is `CCwiki.app` — the bundle
**root**, not `Contents/Resources`. So `Bundle.module` looks for
`CCwiki.app/CCwiki_CCwiki.bundle`. It appears to work on the machine that
built it only because the accessor falls back to a hardcoded absolute `.build`
path; ship that to anyone else's Mac and the app hard-crashes on first resource
access. Putting the bundle at the `.app` root does fix the lookup, and then
`codesign --verify --strict` fails with "unsealed contents present in the bundle
root", which breaks `make dist` and notarization.

Plain files in `Contents/Resources` are the only strictly-valid home.
`Bundle.main.resourceURL` finds them, and `codesign --verify --strict` passes.

`./scripts/vendor-web.sh` fetches them; `--check` verifies an installed tree.
Run it after a fresh clone of this repo — the app will not render without it,
and `build.sh` prints a warning if the directory is missing.

## The app is not sandboxed

`CCwiki/CCwiki.entitlements` has no `com.apple.security.app-sandbox` key at
all. The app's whole job is to drive developer tooling that lives outside any
container — `git` against a clone in Application Support, and `claude` and `gh`
inside git worktrees — and a sandboxed process cannot spawn arbitrary helper
executables. CCwiki therefore ships outside the Mac App Store.

The two hardened-runtime exceptions (`disable-library-validation`, `allow-jit`)
are no-ops for the ad-hoc `make run` build and are what a Developer ID +
notarized build needs to keep working.

**Keep double hyphens out of the comments in that file.** AMFI parses
entitlements with a strict XML parser that rejects `--` inside a comment, and
the failure surfaces during `codesign` as an unhelpful
`AMFIUnserializeXML: syntax error near line N`.

## No SPM dependencies, including for SQLite

`Package.swift` stays at zero configuration. `import SQLite3` compiles and
auto-links `/usr/lib/libsqlite3.dylib` because the SDK's module map carries
`link "sqlite3"`. No `systemLibrary` target, no `linkerSettings`, no shim. See
[search.md](search.md).

## Make targets specific to this app

```
make check         compile + 101 unit tests — the gate after every change
make test-corpus   …and validate against the real cloned wiki
make shots         drive the app and capture screenshots (the visual gate)
```

`make check` runs the tests because a compile-only gate on a SwiftUI app tells
you almost nothing. `make shots` is documented in
[design-system.md](design-system.md).
