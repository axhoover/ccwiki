---
title: Welcome to CCwiki
---

# Welcome to CCwiki

CCwiki is a reader for [cryptology.city](https://cryptology.city), the wiki of
cryptographic primitives, assumptions and the relationships between them. It
keeps its own copy of the wiki on your Mac, so once it has downloaded, reading
needs no network at all.

## Where to start

The sidebar lists the wiki by section. A good first stop is
[[Primitives]], or [[Assumptions]] if you would rather start from what the
primitives are built on. Every page links onward, and the inspector on the
right shows what links back.

## Getting around

| | |
|---|---|
| ⌘N and ⌘T | A new window, or a new tab, at the wiki's front page. |
| ⌘O | Jump to a page by name. With nothing typed, recent pages come first. |
| ⌘S | Search the wiki. The page named for what you typed comes first. |
| ⇧⌘R | Search the references by citation key, author, title or topic. Add a year to narrow it. |
| ⇧⌘F | Find exact text on every page, with the lines it is on. |
| ⌘F | Find on the page you are reading. |
| ⌘[ and ⌘] | Back and forward. |
| ⇧⌘H | The wiki's front page. |
| ⌥⌘I | Show or hide the inspector. |
| ⌥⌘P | On a reference, the paper behind it, in a window of its own. |
| ⌘+ and ⌘− | Larger or smaller text. ⌘0 goes back to the usual size. |
| ⌘R | Check for a newer copy of the wiki now. |

The inspector has three views of the page you are reading: its **outline**,
its **backlinks** (every page that links to it, and why), and its
**relations** — for a primitive or assumption, what it implies, what implies
it, and the barriers known between them.

Select text with formulas and press ⌘C to copy them as LaTeX, or right-click a
formula for Copy LaTeX. Hover an algorithm to copy its LaTeX source, as on the
website. Right-click anywhere on a page to open it on cryptology.city or copy a
link to it.

⌘-click a link to open it in a new tab, or ⌥⌘-click for a new window. To
open a linked page on cryptology.city, right-click the link and choose Open
Link on cryptology.city.

## Staying current

CCwiki checks for a newer copy of the wiki each time it opens, and the status
bar at the bottom says how current your copy is. It also checks once a day
for a new version of the app itself, installs it, and asks before
relaunching. You can change both in Settings (⌘,). (A copy built from
source, CCwiki Dev, never looks for a new version of the app; build it again
for a newer one.)

## Contributing to the wiki

If you have push access to the wiki, CCwiki can draft a page from a paper:
drop a PDF on the window, or choose File → Ingest a Paper and paste a link.
It runs an agent that opens a **draft** pull request for a person to review.
It needs a few developer tools, and Settings → Ingestion says which are
missing.

This page is always in the Help menu, next to What's New.
