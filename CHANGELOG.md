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

## 0.3.0 — unreleased

**Tabs and windows.** File → New Tab (⌘T) and New Window (⌘N). Each tab
keeps its own page and its own Back and Forward. ⌘-click a link, or click it
with the middle button, to open it in a new tab; ⌥⌘-click opens it in a new
window. A link's right-click menu has Open in New Tab, Open in New Window and
Open Link on cryptology.city, which is what ⌘-click used to do. When you
reopen CCwiki, your windows and tabs come back as macOS's "Close windows when
quitting" setting says.

**A reference's paper, beside it.** On a reference page, Show Paper (⌥⌘P)
downloads the paper's PDF from the reference's own ePrint, arXiv or PDF link,
keeps it in CCwiki's library, and opens it in a window of its own. Where
there is nothing to download, such as a DOI alone, Choose PDF… takes a copy
you already have.

**Quicker syncs.** After a sync, the search index updates only the pages that
changed, and an open tab renders again only if its page did. A sync that
changes nothing reloads nothing.

**Copy a proof into a paper or a page.** In the Relations Explorer, Edit →
Copy Proof As gives the proof on screen as LaTeX (⌥⌘C) or as wiki Markdown
(⌥⇧⌘C). The LaTeX is an `enumerate`, one cited step per item, with
CryptoBib keys where the reference has one; the Markdown links each step to
its reduction's page. Copy BibTeX of Cited Works gives entries for the
references CryptoBib doesn't have. The inspector's derived rows have the
same submenu.

**The explorer quotes the wiki for its adjustments.** relations.json leaves
out some things the wiki's pages say: that a step needs sub-exponential
hardness, that an assumption is broken, which direction of an equivalence a
class covers. Where CCwiki takes one of these into account, the answer now
ends with Adjustments, each with the passage of the wiki it rests on and a
link to that section, and a refused step quotes its reason. If the wiki has
since changed a quoted passage, CCwiki says so.

## 0.2.0 — unreleased

**Ask whether one thing implies another.** Wiki → Relations Explorer (⇧⌘E)
takes one or more assumptions, which together form a conjunction, and an
optional target. It answers with a proof: a tree of the wiki's own
reductions, each step opening its page. A one-step answer is the wiki's
claim and says so; a longer chain is labelled "derived by CCwiki from N
recorded reductions". When nothing connects them it says "No derivation
found", never "impossible". It shows the barriers the wiki records, what
other assumption would make the target derivable, and a reminder that the
record is incomplete. Leave the target empty to see everything the
assumptions give; leave the assumptions empty to see everything that gives
the target.

Chains use standard, quantum and CRS reductions by default. "Include
idealised models" adds the random oracle, generic group and algebraic group
models, tagged on every result, and never lets an idealised step lead into a
reduction whose class doesn't survive it. CCwiki also knows where a
reduction needs more than its page says, for example sub-exponential
hardness, a large modulus, or malicious rather than semi-honest OT, and
where an assumption is known to be broken, and it won't chain past those.
Each such correction cites the wiki's own statement.

**Every primitive's Relations tab shows what it reaches.** Below the
recorded relations, "Derived: implies" and "Derived: implied by" list what
follows in two or more steps, marked as derived, with the number of steps.
Click one to see its proof in the explorer. Right-click a row or a page for
Explore From Here.

**Hover a link to preview it.** After a moment, a link shows its page's
title and opening paragraph, math included; a link to a reduction shows the
full statement with its class, model and sources. Turn it off in Settings →
Reading.

**Updates no longer leave an old copy behind.** CCwiki now swaps the new
version in, in one step where the disk allows, and deletes the old one
instead of moving it to the Trash. It also tells macOS about the new
version, so the Finder and Spotlight see it at once. It won't install a
release your Mac can't run, and it says why before downloading anything
when it can't replace itself, for example when it's running from the
Trash or straight from the folder it was unzipped in.

**CCwiki notices other copies of itself.** An old copy elsewhere on your
Mac, in Downloads or left in Applications, can be what the Dock or
Spotlight opens instead of the current one. CCwiki now looks at launch and
says so. If a newer copy is on your Mac, it offers to open that one. If
this copy isn't in Applications and an older one is, it offers to put this
one there in its place. Other copies it offers to move to the Trash.
Settings → About shows where the copy you're running lives.

**For people who build CCwiki from source:** a build from source is now
CCwiki Dev, with its own settings, wiki copy and search index. It runs
beside the released app without touching it, and never updates itself.

## 0.1.3 — 2026-10-10

**Copy LaTeX the way the website lets you.** Hover any algorithm for Copy
LaTeX (macros) and Copy LaTeX (no macros), as on cryptology.city. Select text
with formulas in it and press ⌘C, and the formulas come out as their LaTeX
source, `$…$` and `$$…$$`, instead of a jumble of glyphs. Right-click a
formula, in prose or in an algorithm, for Copy LaTeX; right-click an
algorithm for Copy Algorithm as LaTeX (hold Option to expand the macros). The
LaTeX macros page has its Copy LaTeX preamble and Copy KaTeX/MathJax JSON
buttons.

**Comments in algorithms sit on the right**, as on the website. A comment too
long to share its line gets a line of its own beneath it rather than drifting
next to the following step. Games with their oracles beside them keep the
game wide enough to read, and no longer collapse in a narrow window.

**Reductions and barriers say what kind of result they are.** Under the
title of every reduction and barrier page, the line the website shows: the
reduction class, the model, the sources and the security loss, or for a
barrier its strength, what it rules out and what it assumes.

**The Relations inspector reads the wiki's final-form reductions.**

- A page's own record comes first: kind, class, model, sources, loss, and
  the wiki's one-sentence reason for each class and model (hover to read it).
  A barrier shows its consequences and whether they are believed or open.
- Heuristic candidates, such as NTRU ⇒ PKE, are marked as candidates with a
  dashed arrow, never shown as theorems.
- A barrier that a later result works around says so, wherever it appears.
- Sections of a page are named with their page, "Hash function § Preimage
  resistance (one-wayness)", so two "CPA Security" sections can no longer be
  confused, and IND$-CPA keeps its dollar sign.

**Links written in the wiki's newer link style work.** About 35 links that
did nothing when clicked now open their page, and they count as backlinks.

## 0.1.2 — 2026-09-28

**⌘S finds the page you mean.** Search now puts the page named for what you
typed first: `LWE` opens Learning with errors, not a reduction that mentions
it forty times. Primitives and assumptions come before complexity classes,
and those before reductions. Type a section's name, such as `Ring-LWE`, and
the page opens at that section. Papers are no longer mixed in; they have a
search of their own. A typo no longer finds nothing: when no page matches,
⌘S corrects the misspelled word and says so. And words run together or
split apart still match, so `ArthurMerlin`, `multiparty computation` and
`zeroknowledge` find their pages.

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
