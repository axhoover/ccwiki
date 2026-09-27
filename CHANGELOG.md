# What's new in CCwiki

<!--
  This file is read by people, twice: the app shows the sections newer than
  the version you last ran as its What's New page, and each section becomes
  the notes of its GitHub release (`make release-notes`).

  One section per release, newest first, headed `## <version> — <date>`.
  Write the next release's section as you go, headed with the version it
  will ship as; `make package` refuses to publish a version without one.
  Say what changed for someone reading the wiki, not what changed in the
  code. Commit messages are for the code.
-->

## 0.1.2 — unreleased

**⌘S finds the page you mean.** Search now puts the page named for what you
typed first: `LWE` opens Learning with errors, not a reduction that mentions
it forty times. Primitives and assumptions come before complexity classes,
and those before reductions. Type a section's name, such as `Ring-LWE`, and
the page opens at that section. Papers are no longer mixed in; they have a
search of their own.

**⇧⌘R searches the references.** Find a paper by its citation key (`GGM86`),
an author (accents optional: `Dottling` finds Döttling), words of its title,
or a topic: `oblivious transfer` finds the papers with it in their title,
then the papers the Oblivious transfer page cites, then those whose abstract
mentions it. Add a year to narrow it: `regev 2005`.

**⇧⌘F finds text on every page.** Find in All Pages lists every page with
the exact text on it, references included, with the lines it's on, in page
order and nothing hidden. Case matters only if you type a capital, and TeX
is searched as written, so `\classNP` finds every use of the macro. (⇧⌘F
used to open the same search as ⌘S.)

**⌘O remembers where you've been.** Open the quick switcher without typing
and the pages you visited most recently come first. The page you're on is
left out, so ⌘O then Return takes you back to the one before it.

**Copy a formula's TeX.** Right-click any formula and choose Copy TeX. Every
page's right-click menu can also open the page on cryptology.city or copy a
link to it.

**A welcome page, and this page.** CCwiki greets you on first launch, and
after an update it shows what changed. Both are in the Help menu.

**Back and Forward remember where you were** on each page, as a browser
does. And opening a result from ⌘S search now finds your search term on the
page, so you land on the match rather than at the top.

**Print a page, or save it as a PDF.** File → Print (⌘P) prints the page
you're reading on white, even in dark mode. Choose Save as PDF from the print
panel's PDF menu to keep a copy.

**Smaller things.**

- The inspector comes back as you left it, and ⌥⌘1, ⌥⌘2 and ⌥⌘3 jump to its
  Outline, Backlinks and Relations.
- Wiki → Random Page, for wandering. Wiki → Copy Wikilink copies the
  `[[link]]` to the page you're reading.
- Links to a section now find it when the section's heading is written
  `## Title ##` or indented, and a page's comma-separated aliases are all
  found by ⌘O, matching the website.
- After an update, the status bar says how many pages changed.
- Settings opens on Reading. The command-line tools, which only ingestion
  jobs need, moved to their own Ingestion tab.
- Install and Relaunch no longer asks a second time.
- Settings → About shows the build number, and says when a copy was built
  from source rather than downloaded as a release.
- The app stays responsive while an ingestion job streams its transcript.

## 0.1.1 — 2026-09-27

**⌘S searches the whole wiki.** Search All Pages, which finds every page that
mentions something, now has the easiest shortcut to reach. ⇧⌘F still works.

## 0.1.0 — 2026-09-27

The first release.

**Read offline.** CCwiki keeps its own copy of the wiki and renders it with
the site's own math and pseudocode, with no network needed after the first
download. It checks for a newer wiki each time it opens.

**Nothing to install.** Reading needs nothing but the app. If git is on your
Mac, CCwiki uses it; if not, it downloads the wiki directly.

**Find your way.** ⌘O jumps to a page by name, ⌘S searches every page's text,
and the inspector shows a page's outline, what links to it, and the
relationships it takes part in.

**Keeps itself current.** Once a day CCwiki checks for a new release,
verifies its signature, and installs it. It asks before relaunching.
