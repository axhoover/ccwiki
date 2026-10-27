# Design system

Driven through the **macos-design** skill before and after writing the views, as
`CLAUDE.md` requires.

> Two skills that `CLAUDE.md` also names — **swiftui-pro** and
> **typography-designer** — are not installed in this environment. Their ground
> is covered by `SWIFTUI-RULES.md` (which the code cites inline) and by §1 below.
> If they get installed, run the UI through them.

---

## 1. Two type systems, deliberately different

This is the one typographic decision everything else follows from.

**The app chrome is macOS UI type.** Semantic SwiftUI text styles only, never
hardcoded point sizes, so Dynamic Type and future OS metric changes keep
working. On macOS that lands on the 13 pt system font for body — noticeably
smaller than web or iOS, and correct. Everything lives in `Theme.Fonts`; when
you type the same number a third time it belongs there as a named metric.

**The page inside the web view is document type.** `ui-serif` (New York on
macOS) at 16 px / 1.65, capped at a 42 rem measure so lines stay near the
60–75-character ideal regardless of window width. It is the closest offline
stand-in for the site's Source Serif 4, and setting a cryptography paper in 13 pt
UI sans would make the wiki look like a settings panel.

Headings inside the document use the *sans* system face against the serif body —
the same contrast the website uses (Inter over Source Serif), and it keeps the
structure legible at a glance in a document that is mostly dense prose and math.

**Emphasis is weight; de-emphasis is colour** (`.secondary`, `.tertiary`), never
a lighter font weight. That rule holds in both systems.

## 2. Light and dark are designed, not inverted

`app.css` defines the full light palette on `:root` and redefines only the tokens
under `@media (prefers-color-scheme: dark)`. Dark mode pulls the background
levels further apart (`#16141a` / `#201d27` / `#2a2632`) and lifts the accent
(`#5a1f8a` → `#c39af0`), because there is no ambient light doing that work.
Direct inversion produces either harsh contrast or mud.

The palette echoes the website's own purple rather than the system accent, so a
page looks like the same page. The *chrome* uses system colours throughout,
because chrome should look like the OS.

The web view follows `NSAppearance` automatically. The single line that makes it
not flash white on every navigation is
`webView.underPageBackgroundColor = .textBackgroundColor`.

## 3. Layout

The standard macOS document-browser shape: `NavigationSplitView` with a sidebar,
a reader, and an `.inspector`. Mail, Notes and Xcode all look like this, and it
brings sidebar vibrancy, the unified title bar, column resizing and keyboard
navigation for free.

- **Sidebar** (220–380 pt, ideal 268): the repo's directory tree, folders before
  root pages, pages sorted by *title* rather than filename. A status dot per
  page; a page count per folder. Opening a page from anywhere expands its folder
  and scrolls the row into view, so the sidebar never silently disagrees with
  the reader. **References are not in the tree** — see §3a. A **Saved**
  section above it lists the pages and sections saved with ⌘D and Save
  Section, a section as its page's title over "§ Heading"
  ([efficiency.md](efficiency.md) §3.3).
- **Reader**: a document-info strip (folder · status · last change, plus the
  reference byline) and then the page. The strip deliberately does **not**
  repeat the title — the window title bar already carries it, and printing it
  twice a centimetre apart is exactly the chrome that makes an app feel like a
  web page in a frame. The wiki's own `**Authors:** …` byline paragraph is
  hidden in the rendered page for the same reason: the strip carries it and
  stays visible while you scroll.
- **Inspector** (240–400 pt, ideal 280): outline, backlinks or relations,
  switched by a segmented control. None earns a permanent column. Backlinks show
  the *line* that mentions the page, reduced to prose — a backlinks pane that
  shows `[[markup]]` is unreadable, and the point of the pane is why another
  page links here. They group by the linking page's kind, Mentioned in
  first, under headers that open and close with a count each; a page that
  mentions this one on several lines lists every line, and a click lands
  on the line ([efficiency.md](efficiency.md) §3.1). Relations show the
  typed hypergraph from `relations.json`; see [relations.md](relations.md)
  §9 and §3b below. An outline heading's menu opens its section elsewhere,
  copies a link to it and saves it (efficiency.md §3.2, §3.3).

  The switch is **text-only**. Two segments fitted comfortably with icons and
  titles; three do not, and a truncated word is worse than a missing glyph when
  the names are the whole affordance. The minimum column width went 220 → 240
  at the same time so nothing truncates even at the narrowest drag.
- **Status bar**: sync state, the current revision, and a warnings menu. Quiet,
  26 pt, and it never interrupts reading.

### Windows and tabs

Every reader window, and every tab of one, is that whole shape again, with a
page of its own ([reader-comforts.md](reader-comforts.md) §1.6). Tabs are
macOS's own window tabs, so the tab bar, Show All Tabs, Merge All Windows,
Move Tab to New Window, ⌃Tab and ⌘W all come from the system and look as they
do in Finder and Safari.

- **What is the window's own:** its page, Back and Forward, scroll position
  and find bar; the inspector's visibility and tab, and the outline,
  backlinks and relations of its own page; the sidebar's selection and open
  folders, so opening a page reveals it in its own window's sidebar only; its
  palettes and sheets; and a render error in its status bar. Its title is
  its page's display title, which is what its tab and the Window menu show.
- **What every window shares:** the wiki, the tree and its counts, Hide
  stubs, the search index, jobs, sync state, warnings, settings, text size,
  recent pages, the saved pages and whether the sidebar's Saved section is
  open, and the palettes' queries, so ⌘S in any tab reopens on the last
  search.
- **A new window starts as the last one was left.** Its inspector and open
  folders are those of the window changed most recently, and it opens Home.
  Only the first window of a launch, or the first after every reader window
  has closed (the Dock icon, ⌘N), opens the page read last.
- **The ingest sheet stays on its window.** It is pinned to the window that
  asked for it, and a click on another reader window never moves it or its
  link, notes and PDF.
- **Readers tab only with readers.** Papers tab with papers when the system
  prefers tabs; Jobs and the explorer never tab.
- **Restoration is the system's.** When macOS restores windows, each reader
  window and tab comes back with its page, reading position, history,
  inspector and folders. After a plain Quit, with "Close windows when
  quitting an application" on, as macOS ships, one window opens on the page
  read last.

## 4. Keyboard

Every primary action has a shortcut and every shortcut is in a menu, so it is
discoverable rather than folklore.

| | |
|---|---|
| ⌘N | New window, at Home |
| ⌘T | New tab of the reader window in front, at Home; a window when no reader is in front |
| ⌘Z | Undo Close Tab (Edit menu, after Redo): the tab closed last, back in its window at its place, as in Safari; a window closed whole comes back as a window, a tab per ⌘Z. Text keeps ⌘Z for its own Undo while it has the keyboard |
| ⌘O | Quick switcher |
| ⌘F / ⌘G / ⇧⌘G | Find on page, next, previous |
| ⌘S | Search the wiki |
| ⇧⌘R | Search references |
| ⇧⌘F | Find in all pages |
| ⌘R | Sync with GitHub |
| ⌘[ / ⌘] | Back / forward |
| ⌥⌘I | Toggle inspector |
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 | Outline / Backlinks / Relations |
| ⌘P | Print, or Save as PDF from the print panel |
| ⌘D | Save Page, or Remove from Saved; Wiki ▸ Saved Pages lists them |
| ⌥⌘P | Show Paper, on a reference page |
| ⌥⌘E | Edit Page: the page being read, in an editor window, at the passage selected |
| ⌘↩ | Review Changes, in an editor window: save, and review the job in Jobs |
| ⌘+ / ⌘− / ⌘0 | Text bigger / smaller / actual size, in every tab; in a paper window, Zoom In / Zoom Out / Zoom to Fit |
| ⇧⌘H | Go home |
| ⌥⌘C / ⌥⇧⌘C | Copy proof as LaTeX / as wiki Markdown (Relations Explorer) |
| Esc | Dismiss any sheet or the find bar |

**Clicks say where a page opens**, as in Safari
([reader-comforts.md](reader-comforts.md) §1.4). One table serves a link in
the page and every row that is a button (Saved, Cited by, the Reductions
and References rows, Backlinks, Relations, palette rows), though a row, which
SwiftUI draws, answers only the primary button:

| | |
|---|---|
| Click; ⇧- or ⌥-click | Here |
| ⌘-click; middle-click | A new tab, behind the one being read |
| ⇧⌘-click | A new tab, in front |
| ⌥⌘-click, with or without ⇧ | A new window |

The same choices are in the context menus: **Open in New Tab** and **Open in
New Window** come first in a row's menu, and a link in the page also offers
**Open Link on cryptology.city**, which is what ⌘-click used to do. Two kinds
of row keep their own ⌘-click: the sidebar tree's pages, which are `List`
selection, as in Finder's and Mail's sidebars, and the inspector's derived
rows, whose click shows a proof in the explorer rather than a page. Both
still offer the menu items, a derived row straight after its Open “…”. A
folder label's menu is Open Folder Page, then the same in a new tab and in a
new window.

The palettes (⌘O, ⌘S, ⇧⌘R, ⇧⌘F) are keyboard-shaped: type, arrow, Return,
with the shortcut hints rendered in the footer as keycaps (`KeyHint`). A
palette you have to reach for the mouse in is slower than the sidebar it
replaces. Return opens the highlighted hit where you are. **⌘Return** opens
it in a tab behind, and leaves the palette open with its highlight, so you
can open hit after hit; **⇧⌘Return** opens it in a tab in front and closes
the palette. The two are key equivalents on invisible buttons, so the field's
own Return never fires as well. The footer names ⌘↩ alone: ⇧ means "in
front" exactly as it does with ⌘-click, and another keycap would crowd the
hints the palette is for. Until background tabs are switched on
(`WindowTabbing.joinsInBackground`, after the by-eye check on a Mac), every
new tab opens in front and ⌘Return closes the palette too.

`.findNavigator` is macOS 26, so the find bar is hand-built over
`WKWebView.find` (macOS 11+). `WKFindResult` only reports whether anything
matched, so the page counts the matches in JavaScript after each find, and
the bar says "3 of 17", or "17 matches" where it cannot tell which one is
selected (a match in a formula), or "No matches". It says so explicitly
rather than doing nothing. The count is `Theme.Fonts.meta`, secondary, with
monospaced digits, so it does not jitter as it steps
([render-pipeline.md](render-pipeline.md), "Find on Page's count"). It
keeps its width (`SWIFTUI-RULES` §2.2), so at a narrow reader the field
gives way, not the number. VoiceOver announces each count, since the
keyboard stays in the field.

## 3a. References are not peers of the concept pages

**200 of the wiki's 293 pages were references — 68%.** A directory tree that
mirrors the repo is therefore two-thirds citation store, and following a
citation used to expand `References/` and scroll you into an alphabetical wall
of keys while the concept structure left the screen entirely. The sidebar was
worst exactly when you most needed to know where you were.

The fix rests on a structural fact: references are not peers of the concept
pages. Primitives, Assumptions, Complexity, Glossary and Folklore are *what the
wiki is about*; `References/` is the citation store those pages point into. The
wiki's own front page says as much.

So:

- **The tree is the 93 concept pages.** All five folders and both root notes fit
  on screen at once, which is what a navigable structure looks like.
  (The corpus is 712 pages now. The tree holds 167 of them — the five concept
  folders, the two root notes, and `Barriers/` — against 545 collapsed into two
  rows. The argument only got stronger; see §3b.)
- **References collapse to one row** with a count and a chevron. Clicking it
  opens the synthetic folder page in the *reading pane* — a 200-item sorted list
  belongs in a 42 rem column, not a 268 pt one, and there it gets each paper's
  real title next to its key.
- **A "Cited by" section appears above the tree while you are reading a
  reference**, listing the concept pages that link to it. That is the question
  you actually have on arriving at a citation: what brought me here, and what
  else uses this. On a concept page it is hidden, so the sidebar stays quiet
  when the tree already answers the question.

Nothing is lost: ⌘O fuzzy-matches every reference by key, alias or paper title,
⌘S searches their full text, and every citation in the wiki is a link. The
sidebar was never the fast way to reach one.

### The folder listing earns its keep

Since that page is now the only way to browse a folder, it does two things the
site's version does not:

- **Alphabetical dividers that stick** to the top of the viewport while you
  scroll their group. In a 200-row list, knowing you are in the B's without
  scrolling back is the whole game. The rows are in the site's order (the
  lower-cased title under ICU collation, `localeCompare`, not code points),
  and the letter comes from the same title Quartz groups by — the citation
  key in References, the title everywhere else. As on the site, anything not
  starting with a letter A–Z (`#P`, a digit, `$k$`, `Φ`) files under `#`
  rather than inventing a divider of its own, and each group sits where its
  first row sorts.
- **A "Hide stubs" checkbox**, in the info strip and mirrored in Settings.
  The ratio is lopsided and uneven: **19 of 38 Primitives are stubs**, against
  4 of 200 References. Someone reading wants the pages with something on them;
  someone looking for work to do wants exactly the opposite. That is a toggle,
  not a default. It applies to the sidebar too — the counts change with it —
  and the listing says how many it is hiding rather than quietly showing a
  shorter list than the repo has.

*Considered and rejected:* a two-mode sidebar with a filterable references list
(a mode you have to remember you are in, for a list ⌘O already beats), and
grouping references by year (structure the repo does not have, and not how
anyone looks for a paper).

## 3b. Reductions get the same treatment; Barriers does not

The reductions migration added **343 `Reductions/` pages and 37 `Barriers/`
pages** in one commit — more than the rest of the wiki put together. The §3a
argument applies to `Reductions/` twice over:

- 343 rows would bury the 93 concept pages exactly the way References did.
- **A reduction page is not somewhere you browse to.** You arrive at one from
  the relation it states, on the page of one of its endpoints — which is what
  the Relations inspector now provides. The tree was never the route.

So `Reductions/` collapses to one row with a count and a chevron, next to
References, both drawn by the same function. `Barriers/` stays an ordinary
folder: 37 rows is a folder, not a wall.

A third filter now applies alongside "hide stubs": the manifest marks 30 objects
`unlisted`, and those leave the tree, the folder listings and the quick
switcher. They are still real nodes — they appear in relation rows and in ⌘S —
which is precisely what `unlisted` means. See [relations.md](relations.md) §7.

## 4a. The jobs window

Jobs live in a **separate window** (⇧⌘J), not a fourth pane. Two reasons: the
thing you actually want is to watch a job run *while reading the page it is
going to edit*, and a queue plus a live log has no honest home in a three-column
reader without displacing the page.

The main window keeps a compact affordance — a spinner and a count in the status
bar, which opens the window — so a running job is never invisible.

Inside, the same two-column shape as the reader: the queue on the left with a
state glyph per job, the transcript on the right under an outcome banner. Three
details that make the log readable rather than merely present:

- `stream-json` means each row is a *step*, so a tool call renders as a small
  labelled chip plus its command, and its result is indented beneath it. A raw
  text stream would be a wall.
- The transcript follows the tail by default, with a checkbox to stop — because
  the moment you want to read something is the moment it scrolls away.
- The scroll target is a zero-height anchor at the bottom, not the last row: the
  last row changes identity as events arrive, and scrolling to a moving target
  stutters.

An **aborted** job gets an orange banner saying so is a good outcome, not a red
one. The prompt asks the agent to abort rather than guess; punishing that
visually would be teaching the wrong lesson.

### The review

Every route that changes the wiki ends in this window, ingestion included,
and nothing leaves for GitHub from anywhere else
([corrections.md](corrections.md) §6.6).

- **The queue** puts **Awaiting Review** above **Jobs**. A row's glyph is
  its kind (a paper, a described correction, an edit), tinted by its state
  and a spinner while a process runs; its subtitle is the passage, then the
  status. An edit nobody has touched yet reads "Editing" and waits under
  Jobs. **Clear Finished** and **Ingest a Paper** sit over the queue, as
  Mail puts New Message over its list.
- **A job under review** has a segmented **Changes | Transcript** in the
  toolbar's centre, then **Edit…** (a pull-down when several files
  changed), **Discard…**, and last **Open Draft PR**, the one prominent
  button. Its header is the state row and an accent banner that says what
  is already on GitHub; the job's last notice and the GitHub line sit under
  it, and the pre-flight findings move to the Transcript.
- **Changes** is a `VSplitView`: DiffGuard's findings and the diff above,
  the pull request below, never shorter than 150 pt, so the form never
  covers the diff. The findings take about a third of their pane at most and
  scroll past it, so the diff keeps the larger share however many there
  are. A finding's glyph says its severity as well as its colour (an
  octagon blocks, a triangle warns, an `i` informs); a click scrolls the
  diff to it.
- **Rendered or Source.** Rendered is the reader's own pipeline drawing
  only the changed blocks, Before and After labelled in the gutter so they
  differ by more than colour. Source is the lines, both line numbers in the
  gutter, `−` and `+` rows tinted, and in a changed pair the changed words
  set in **bold** on a stronger tint, so a one-letter fix is findable. A job
  whose diff adds raw HTML opens in Source.
- **Open Draft PR** is disabled, with its reason as its help, by a blocking
  finding, a local path in the title or body, GitHub not ready, or an
  editor of the job whose file changed on disk and still asks which
  version to keep. With warnings, or in a Dev build, it asks first, naming
  the repository. The line under the body names where it goes before
  anything is sent: "Opens a draft pull request on
  axhoover/cryptology.city · from CCwiki Dev".
  No shortcut: Review Changes brings this window forward, and a key pressed
  twice from the editor would publish.

### The editor

A file of a job is a window of its own, as a document is: titled by its
file name, with the page and the passage as the subtitle, and tabbed only
with other editors. The source (an `NSTextView`, monospaced, with smart
quotes, dashes, replacement, correction and detectors off) sits beside a
preview rendered by the reader's pipeline, which follows the caret's line.
The preview hides by width, never leaving the split view.

Under the toolbar, on the bar, a strip carries what came from the reader: the
quoted passage in two lines at most, with Show to select it again, and,
when they apply, why the file is read-only, what a generated passage or a
line built from the frontmatter is, the GitHub line and a failed save.
Saving is automatic, so there is no Save; the status line says "Saved to the
job's worktree" or "Saving…", then the line and column, then "CCwiki Dev" in
a Dev build. Text an editor could not save when it or the app closes, such
as a conflict nobody settled, is kept in the worktree's `.ccwiki/` and the
job's log says where. **Review Changes** (⌘↩) saves, takes the review again
and opens Jobs on the job. Revert File… waits in the toolbar's More menu,
behind a confirmation.

## 4b. Error states

Every failure the app can hit has a designed resting state, because the
alternative is a spinner that never stops.

- **Offline.** A network outage is *not a fault*: the reader works entirely from
  the clone. It gets a `wifi.slash` glyph in tertiary grey and the words
  "Offline — reading from the last pull", not a warning triangle. `GitService`
  classifies it by matching git's own vocabulary ("could not resolve host",
  "failed to connect", …) rather than by exit code, because git reports all of
  them as 128.
- **A clone that will not fast-forward.** This one *is* alarming, because
  CCwiki never writes to that checkout — so something else did. The message
  says exactly that and offers the two real options: fix it by hand, or delete
  the clone and let CCwiki re-clone.
- **Missing tooling.** The reader needs only `git`; ingestion needs `gh`,
  `claude` and `node`. Missing ones are listed in the status bar's warnings menu
  and in Settings, each with what it is for and a **Locate…** button.
- **`gh` not authenticated, or no push credentials.** Both are checked *before*
  a job starts, not at the end after twenty minutes of work, and both are shown
  in Settings with their current state.
- **Macros that would not parse.** A banner above the page saying so, plus the
  warnings menu. Math still renders; site-specific commands show as KaTeX
  errors. The page is degraded, never blank.
- **A worktree left behind by a crash.** Found at launch, surfaced in the
  warnings menu and as a "Left Behind" section in the jobs window with a
  **Prune** button — cheaper than making someone learn `git worktree prune`.

The pattern throughout: say what happened, say what it means for what you were
doing, and offer the action. A status bar that only ever shows a spinner and a
red triangle is not error handling.

## 4c. The app icon

A lowercase **λ** on the website's purple, standing among three blocks on a
ground line.

λ is the wiki's own `\secpar` — the security parameter, and the most common
symbol on the site. It means something precise to the one audience this app has,
it is unlike anything else in a Dock, and it survives being shrunk to 16 pt,
which a page-of-math glyph does not. The blocks are the "city" half of the name
and read as a desk at small sizes; below 32 pt they are dropped entirely,
because three pixels of skyline is grit.

Drawn in `scripts/make-icon.swift` with pure CoreGraphics — two stroked paths
for the λ, no font dependency, and the weight increased at small sizes so the
mark keeps its colour when it is only a few pixels wide.

## 5. The visual gate

SwiftUI's compile guarantees are weak; a passing build is not a passing app
(`SWIFTUI-RULES.md` §9.3). `make shots` drives the **real** app through a plan
of views and captures each one:

```sh
make shots
make shots PLAN='page:Primitives/pseudorandom-function.md,dark'
```

`ScreenshotRunner` (compiled in, inert unless `CCWIKI_SHOTS` is set) applies
each step, waits for it to settle, writes a `.ready-N` marker and blocks;
`scripts/shots.sh` captures the window with `screencapture -l` and answers with
`.go-N`. Plan steps: `home`, `page:<path>`, `folder:<slug>`, `switcher:<query>`,
`search:<query>`, `outline`, `backlinks`, `light`, `dark`, and for windows and
tabs `window:<path>` (a second reader window), `tab:<path>` (a new tab in
front) and `bgtab:<path>` (a new tab behind, once background tabs are on),
and `paper:<path>` (a reference's paper window, served from
`CCWIKI_PAPER_FIXTURES`; Offline for a paper without a fixture). For
corrections there are `edit:<path>` (an edit of the page, begun past the
blockers, in its editor), `review:<path>` (a scripted one-word edit of the
page, reviewed in Jobs), `source` (that review's changes in Source), and
`describe:<path>` and `issue:<path>` (the Describe a Correction and Open an
Issue sheets over the page). The jobs that `edit:` and `review:` begin are
discarded when the plan ends, so no run leaves a worktree behind
([corrections.md](corrections.md) §12.3). Each step drives the reader window
or tab that was key most recently.

The capture needs the **Screen Recording** permission (System Settings → Privacy
& Security). Without it the script falls back to an in-app composite —
`cacheDisplay` plus `WKWebView.takeSnapshot` — which needs no permission and
renders everything *except* `NSVisualEffectView` backdrops, because their blur
happens in the window server. Sidebars come out flat. Good enough to check the
reader, not the chrome.

This gate has already earned itself: it is how the quick switcher's stale-rows
bug was found, and the bug was invisible to the unit tests because the *model*
was correct.
