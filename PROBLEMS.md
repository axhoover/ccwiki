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

## `gh auth login` does not imply `git push` works

`gh auth status` reported a healthy login, and `git ls-remote` over HTTPS
succeeded — but `git push` failed with `could not read Username for
'https://github.com'`. The account's configured `git_protocol` is **ssh**, so
`gh` had never installed an HTTPS credential helper, and the global
`credential.helper = store` had no GitHub entry.

The bad part is *when* it surfaces: at the very end of a long ingestion job,
after the agent has fetched the paper, written the page, run the lint and the
build, and has nothing left to do but push.

**Fix, two halves.** `GitService.configureCredentialHelper` sets
`credential.https://github.com.helper` to `!gh auth git-credential` on
CityDesk's **own clone**, using `--local` — the clone is the app's artifact, and
reaching into the user's global git config to solve our problem would be rude.
`Preflight` then refuses to start a job when neither a helper nor an SSH remote
is configured, so the failure lands in ten seconds instead of ten minutes.

**Rule:** any credential a job needs at the *end* gets checked at the
*beginning*.

## An agent turn budget has to match the *workflow*, not a remembered number

The first real ingestion job was launched with `--max-turns 60`, copied in
spirit from the wiki's own GitHub workflow, which uses 40. It spent **54 turns
before writing a single file** — reading the five contract documents, fetching
the paper, modelling its output on a recent reference page, and checking the
lint's macro and bullet rules.

That is not the agent being wasteful. CityDesk's prompt deliberately adds what
the server pipeline lacks: `npm ci`, `node scripts/lint.mjs`, `npx quartz
build`, and `npm run sync-cryptobib`, each with a fix cycle behind it. A budget
copied from a workflow that runs none of those is a budget for a different job.

The cap is now 200, overridable with `CITYDESK_MAX_TURNS`. **The real bound on a
runaway job is the user's Cancel button and the live cost readout**, both of
which the jobs panel already has — not a number chosen in advance by someone who
has not watched the job run.

## The worktree path contains a space, and that costs agent turns

`~/Library/Application Support/CityDesk/worktrees/<id>` is the conventionally
correct place for it, and CityDesk's own subprocess calls are safe — arguments
go through `Process.arguments`, never a shell. But an *agent* composing its own
shell commands has to quote it every time, and the first real ingestion job lost
turns to `ENOENT: no such file or directory, scandir
'/Users/…/Application%20Support/…/content'` — a percent-encoded path handed to
node.

`prompts/ingest.md` now says so explicitly and tells the agent to run from the
worktree rather than pass absolute paths around. Moving the directory somewhere
space-free was considered and rejected: Application Support is where this
belongs, and a warning is cheaper than a non-standard location.

