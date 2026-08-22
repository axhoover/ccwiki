# Problems — things that bit us

One entry per hard-won pattern lesson (`SWIFTUI-RULES.md` §10.2). Keep these
separate from commit messages, where they get lost. The big SwiftUI catalogue
lives in `SWIFTUI-RULES.md`; this file is for issues specific to *this* app.

The template starts with none of its own. The note below is a standing
gotcha for anyone forking it.

---

## Renaming has to keep four names in agreement

The SwiftPM target name, the `.app` name in `build.sh` (`APP_NAME`), the
`CFBundleExecutable` in `Info.plist`, and the entitlements path
(`<Name>/<Name>.entitlements`) must all be the same string, or the build
assembles an `.app` whose executable name doesn't match the bundle and macOS
refuses to launch it. The template's `scripts/rename.sh` handled that coupling
in one pass and has been deleted now that the rename is done; if you ever rename
again, change all four together.

---

## `ForEach(Array(collection.enumerated()))` breaks row updates

Both command palettes rendered with
`ForEach(Array(results.enumerated()), id: \.element.id)` and tracked selection
by index. On a new query the footer count updated but **the rows kept showing
the previous query's results**: the tuple elements carry no identity of their
own, so SwiftUI had nothing to diff, and `LazyVStack` held on to the old views.

The model was correct the whole time, so no unit test could have caught it —
`make shots` did, on its first run.

**Rule:** iterate the `Identifiable` collection directly, and hold selection as
an `id`, deriving the index only when you need to move. Both palettes now do.
See `plans/search.md` §5.

## A directory URL's path ends in a slash, and path containment must allow for it

`CityDeskSchemeHandler` refused every resource with `not found: index.html`,
while the file was demonstrably there. `Bundle.main.resourceURL.appending(path:
"web")` yields a path ending in `/`, so the containment check
`file.hasPrefix(root + "/")` was testing for `…/web//index.html`.

**Rule:** normalize *both* sides before comparing paths — trim trailing slashes,
then test `==` or `hasPrefix(root + "/")`. `CityDeskSchemeHandler.isContained`
does exactly this and is the only place that comparison lives.

## Double hyphens in an entitlements comment break codesign

`codesign` failed with `AMFIUnserializeXML: syntax error near line 16`, pointing
at a `<!-- ... -->` comment that mentioned `--options runtime`. AMFI parses
entitlements with a strict XML parser, and `--` inside a comment is illegal XML.
`plutil -lint` accepts the file, so it does not catch this.

**Rule:** no double hyphens anywhere in `CityDesk.entitlements`, comments
included. The file says so at the top.

## A "nearly matches optional requirement" warning is an error here

Writing `WKNavigationDelegate`'s decision handler as the obvious
`@escaping (WKNavigationActionPolicy) -> Void` compiles with only a warning —
and the method is then **never called**, so every link interception silently
does nothing. The required spelling is
`@escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void`.

**Rule:** treat that warning as an error in this codebase.

