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

## 0.1.5 — unreleased

**Reopen a tab you closed.** Edit → Undo Close Tab (⌘Z) brings back the
tab or window you closed last, as a tab of the window in front, with its
page, its Back and Forward, and the place you were reading. Press it again
for the one before, up to ten. While you are typing in a field, ⌘Z still
undoes your typing.

**Find on Page counts.** The find bar now says "3 of 17" as you step
through the matches with Return, ⌘G and ⇧⌘G, or "No matches". Where a
match is inside a formula, it gives the number of matches alone.

## 0.1.4 — 2026-10-20

**Correct a page from the reader.** Three ways, from the Wiki menu, the
toolbar's pencil button, or a right-click on the page or a passage selected
on it:

- **Edit Page… (⌥⌘E)** opens the page's Markdown in a window of its own, at
  the lines you selected, with a live preview drawn the way the reader draws
  pages.
- **Describe a Correction…** takes a sentence about what is wrong, and an
  agent drafts the edit to that one page. Settings → Jobs chooses its model;
  Sonnet is the default.
- **Open an Issue About This Page…** fills in a GitHub issue with the page,
  the section and the passage, and shows the exact text before it is sent.

**Nothing reaches GitHub until you approve it.** Every job now stops under
Awaiting Review in the Jobs window, paper ingestion included. The review
shows the changes as rendered pages, marks what the wiki does not allow,
such as a hand edit to a generated "Participates in" section or a file
outside `content/`, and lets you edit the pull request's title and body.
Open Draft PR commits, pushes and opens a draft pull request; Discard…
throws the work away. Agent jobs run without GitHub credentials, and CCwiki
checks after each one that nothing was pushed that it did not push itself.

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

**Backlinks that take you to the line.** The Backlinks tab (⌥⌘2) groups the
pages that link here: Mentioned in, then Reductions and Barriers, then
References, each with its count, opened or closed with a click. A page that
mentions this one on several lines says how many and lists every line.
Click a line to open that page scrolled to it, outlined for a moment;
⌘-click opens it in a new tab, which lands there too.

**Links to a section.** Right-click under a heading, or a heading in the
Outline, to copy a link to that section: on cryptology.city, as a
`[[wikilink]]` for the wiki, or as a CCwiki link that opens CCwiki at the
section from Notes or any other app. A heading in the Outline also opens
its section in a new tab or window.

**Saved pages.** Wiki → Save Page (⌘D) keeps the page you are reading in a
Saved section at the top of the sidebar, the same in every window and
kept between launches, and Wiki → Saved Pages lists them. Save Section,
next to the section links, keeps a section. Drag a saved page to reorder
the list, or use Move Up and Move Down in its right-click menu. If a sync
renames a saved page, CCwiki finds it by its title. One that is gone stays
in the list, dimmed, and a click searches the wiki for it.

**Quicker syncs.** After a sync, the search index updates only the pages that
changed, and an open tab renders again only if its page did. A sync that
changes nothing reloads nothing.

**Less waiting.** Opening CCwiki and syncing the wiki take less time, and
the page you are reading appears without waiting for the search index to
be brought up to date; a search typed meanwhile answers once it is. A page
full of formulas draws again sooner when you go Back to it, in the
editor's live preview, and after a sync or a change in Settings, because
each tab and each preview keeps the math it has already typeset. The
review in the Jobs window draws only the parts of a change it shows, so
it opens and refreshes sooner. A running job's elapsed time keeps ticking
while the agent works quietly, instead of stopping and then jumping.

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
since changed a quoted passage, CCwiki says so. Some steps now need more
than before, and the answer says so. GPSW06 needs decisional BDH, and the
PRP-to-PRF conversions need a superpolynomial domain. Kilian's OT-to-MPC
step gives static malicious MPC with abort. The direction of ISIS/SIS
whose parameters the wiki does not state is held back.

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

**Fixes.**

- A page saved with Windows line endings rendered blank and was missing from
  search and backlinks.
- On a page with a notice, such as a broken link with maintenance notices on,
  pseudocode lost the wiki's macros, and so did Copy LaTeX (no macros) and
  link previews.
- A link to an asset can no longer open a file outside the wiki's content.
- Back and Forward between two places on one page now move, and Open Link in
  the right-click menu opens web and mail links.
- Heading anchors match the site for superscripts, fractions, emphasis and
  math in headings. `[[index]]` links to the front page, a YAML list written
  flush left under its key is read, and an alias ending in `.md` links as
  the site links it.
- ⌘S, ⇧⌘R and ⇧⌘F show results for a query typed while the wiki was
  loading, and Return opens a result for the text you typed rather than the
  text before it. Opening an ⇧⌘F hit finds a capitalised term in its own
  case.
- Cancelling a paper ingestion while it was checking brought it back.
- Tools you install while CCwiki is open are found when you come back to it.
  A copy left open checks for updates every day, not only at launch, and
  Settings no longer says "Up to date" after a relaunch when an update was
  found.
- In the Relations Explorer, a step whose requirement another recorded
  reduction meets is no longer refused, relation names in plain text keep
  `\gets`, `\pmod` and the like, and Copy Statement on a derived row says
  what it assumes.
- Pages read more as they do on the site. An aliased wikilink in a table no
  longer splits its row, and one in rows that only look like a table is no
  longer broken. Quotes curl, `--` and `---` become dashes and `->` an
  arrow, as the site types them, in link text too. `%% comments %%` are
  hidden. A callout written over several lines is recognised, and its title
  reads as the site's. `[[page#Heading]]` shows the heading, and
  `IND$-CPA` no longer shows its backslash. Games in pseudocode are grouped
  as the site groups them, and a `../` link opens its page.
- Folder pages list their pages in the site's order.
- The line under a reduction's or barrier's title no longer shows a YAML
  comment, or drops part of a value written over several lines or as a
  list with its `]` on a line of its own.
- Paper ingestion no longer says "Not signed in" because of another GitHub
  host's expired token or a GitHub outage: offline, Settings and the
  ingest sheet say so. A gh signed in only to another host no longer counts
  as signed in to github.com. A gh that has moved no longer breaks the push
  at the end of a job, and a credential helper you set in CCwiki's copy of
  the wiki is kept.
- ⇧⌘N works when the Jobs window is in front. An ingestion asked for there
  with no reader open no longer takes the next PDF you open from the
  Finder. The Sync Log no longer says no sync has run over the sync that
  just ran.

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
