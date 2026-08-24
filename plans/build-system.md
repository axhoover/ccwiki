# Build system

No Xcode project, no `xcodebuild`, no XcodeGen. `swift build` compiles; a shell
script bundles and signs; `make` orchestrates. Xcode is only a toolchain
provider (`swift`, `codesign`, `notarytool`, `stapler`).

## The pieces

- **`Package.swift`** — one `executableTarget` (`CCwiki`) + one `testTarget`.
  Swift 6 language mode. Zero third-party dependencies.
- **`build.sh`** — `swift build` → assemble `build/CCwiki.app` (Info.plist
  with `__SHORT_VERSION__`/`__BUILD_VERSION__` substituted, `PkgInfo`, any
  dependency `*.bundle`s copied into `Contents/Resources`, the icon) → codesign.
  Falls back to ad-hoc signing (`-`) when no real identity is available, so
  `make run` always works on a bare machine.
- **`Makefile`** — the front door. `make help` lists everything.
- **`Resources/Info.plist`** — bundle metadata. Version strings are
  placeholders filled at build time.
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
| `make` / build| `build/CCwiki.app` (debug)                              |
| `make icon`   | regenerate `build/AppIcon.icns`                          |
| `make clean`  | remove `build/ .build/ dist/`                            |

## Versioning

`make` resolves the version in this order: a `VERSION=` override → an exact
`vX.Y.Z` git tag at HEAD → the `VERSION` file. `make print-version` shows what
resolved and from where.

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

## CI gate

The minimum a change must pass: `make check && make test`. The minimum a *UI*
change must pass: also `make run` and look at it — see `SWIFTUI-RULES.md` §9.


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
