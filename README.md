# CCwiki

A native macOS reader for the [cryptology.city](https://cryptology.city) wiki,
and a launcher for headless agent jobs that ingest papers and open pull requests
against it.

CCwiki is a **client** of `axhoover/cryptology.city`. The GitHub repo is the
only canonical store; the app owns no content and never merges anything.

- **Read offline.** A pull-only git clone, rendered in a `WKWebView` with a
  vendored Markdown + KaTeX + pseudocode.js pipeline. No network at read time.
- **Links that behave like the website's.** `[[wikilinks]]` resolve through a
  line-by-line port of Quartz's own slug rules, tested against the wiki's test
  suite and against all ~673 links in the live corpus.
- **Find things.** ⌘O fuzzy quick-switcher over titles, aliases and paper
  titles; ⌘S full-text search over everything, backed by SQLite FTS5.
- **Ingest papers.** Drop a PDF on the reader, or paste an ePrint, arXiv, DOI or
  ECCC link (⇧⌘N). CCwiki runs `claude` in a throwaway git worktree, streams
  the transcript into a jobs window (⇧⌘J), and ends at a **draft** PR — it never
  merges, and never marks one ready for review. See
  [plans/ingestion.md](plans/ingestion.md).

## Requirements

To read: macOS 14 or newer, and nothing else. Without `git` the wiki arrives
as a tarball snapshot; with it, as a pull-only clone that fast-forwards.

To build from source: a Swift 6 toolchain (Xcode, or the swift.org installer).

To run ingestion jobs: `git` (a real one — Apple's Command Line Tools, or
Homebrew's), `node` ≥ 20, `gh`, and the `claude` CLI.

A Finder-launched app inherits launchd's `PATH`, which is
`/usr/bin:/bin:/usr/sbin:/sbin` — enough for `/usr/bin/git` and nothing else.
CCwiki searches Homebrew's directories and `~/.local/bin` as well, and falls
back to asking a login shell, so a normal Homebrew or npm install is found
automatically.

## Installing a release

Download `CCwiki-<version>-macos.zip` from the
[releases page](https://github.com/axhoover/ccwiki/releases), unzip it, and
drag `CCwiki.app` to Applications. The app is not notarized (there is no
Apple Developer ID behind it), so the **first** launch needs one extra step:
open it, let macOS refuse, then go to System Settings → Privacy & Security
and click **Open Anyway**. Once.

Or, from Terminal, which skips that dialog because `curl` does not mark
downloads for Gatekeeper:

```sh
curl -L -o /tmp/CCwiki.zip "https://github.com/axhoover/ccwiki/releases/latest/download/CCwiki-<version>-macos.zip"
ditto -x -k /tmp/CCwiki.zip /Applications
```

After that, CCwiki keeps itself current: once a day it checks for a newer
release, verifies its Ed25519 signature against a key built into the app,
installs it in place, and asks before relaunching. Settings → About has the
switches. See [plans/distribution.md](plans/distribution.md) for how that
works without a Developer ID.

## Building from source

```sh
git clone <this repo> ccwiki && cd ccwiki

./scripts/vendor-web.sh    # fetch the offline render pipeline (once, needs network)
make check                 # compile + unit tests
make run                   # build the .app and launch it
```

`scripts/vendor-web.sh` downloads pinned, checksum-verified copies of
markdown-it, KaTeX and the wiki's patched pseudocode.js into `Resources/web/`.
The app never touches the network for rendering; this is the one step that does.
Re-verify an existing tree with `./scripts/vendor-web.sh --check`.

### First launch

CCwiki downloads the wiki (~35 MB) into
`~/Library/Application Support/CCwiki/repo` — a git clone if `git` is there,
a snapshot otherwise — and builds a search index. After that, reading needs no
network. It checks for a newer wiki at each launch (Settings → Reading to turn
that off), and ⌘R does the same at any time.

```
~/Library/Application Support/CCwiki/
├── repo/          the pull-only clone: the reader's copy, never written to
├── library/       PDFs you drop on the app (deliberately outside the repo)
├── index/         search.sqlite3 — derived, safe to delete at any time
└── logs/          per-job transcripts

~/Library/Caches/CCwiki/
└── worktrees/     one git worktree per ingestion job
```

Worktrees live under `Caches` on purpose: `Application Support` has a space in
it, and a worktree is where `npm`, `npx` and the wiki's own node scripts run —
several of which read `import.meta.url.pathname` without percent-decoding it and
fail on `%20`. A worktree is disposable by construction, so `Caches` is also the
honest semantics.

Delete `index/` any time you like; it rebuilds in about a tenth of a second.
Delete `repo/` and CCwiki re-clones on the next sync.

### For ingestion jobs

```sh
gh auth login                       # needs `repo` scope to open a PR
claude --version                    # https://claude.com/claude-code
node --version                      # the wiki's lint is a node script
```

`gh` must be authenticated as an account that can push a branch to
`axhoover/cryptology.city`.

Note that `gh auth login` alone does not always make `git push` work: if your
`git_protocol` is `ssh`, `gh` installs no HTTPS credential helper, and the push
fails at the very end of a job. CCwiki configures one on **its own clone**
(local config only — your global git config is untouched) and refuses to start
a job that could not push.

## Keyboard

| | |
|---|---|
| ⌘O | Quick switcher |
| ⌘F / ⌘G / ⇧⌘G | Find on page / next / previous |
| ⌘S (or ⌘S) | Search all pages |
| ⌘R | Sync with GitHub |
| ⌘[ / ⌘] | Back / forward |
| ⌥⌘I | Toggle inspector |
| ⌘+ / ⌘− / ⌘0 | Text bigger / smaller / actual size |
| ⇧⌘H | Go home |
| ⇧⌘N | Ingest a paper |
| ⇧⌘J | Show the jobs window |
| ⌘, | Settings |

## Make targets

```
make check         compile + unit tests — the gate after every change
make run           build and launch
make shots         drive the app and capture screenshots (the visual gate)
make test-corpus   validate the resolver against the real cloned wiki
make release-keys  once: the Ed25519 key that signs releases
make package       universal, ad-hoc-signed, Ed25519-signed release zip
make dist          the same with a Developer ID + notarization
make help          everything else
```

`make shots` needs the **Screen Recording** permission (System Settings →
Privacy & Security → Screen & System Audio Recording) for the process running
it. Without it, it falls back to an in-app capture that renders everything
except vibrancy backdrops.

`make run` ad-hoc signs, so it works on a bare machine with no certificates.

Every push runs `make check` on a macOS runner (`.github/workflows/ci.yml`).

## Where to read next

[PLAN.md](PLAN.md) is the index to everything: architecture, the Quartz slug
port, the render pipeline, search, ingestion, and the design system.

## Licence

MIT — see [LICENSE](LICENSE).

The vendored assets under `Resources/web/vendor/` keep their own licences, all
included alongside them: markdown-it, markdown-it-footnote, markdown-it-mark,
github-slugger, KaTeX and pseudocode.js are MIT; markdown-it-anchor is
Unlicense. `pseudocode.js` is the patched fork from the wiki repo, pinned by
sha256 in `scripts/vendor-web.sh` — see
[plans/render-pipeline.md](plans/render-pipeline.md) §2.
