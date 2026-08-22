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
  root pages, pages sorted by *title* rather than filename — which matters most
  in `References/`, where the filename starts with a citation key. A status dot
  per page; a page count per folder. Opening a page from anywhere expands its
  folder and scrolls the row into view, so the sidebar never silently disagrees
  with the reader.
- **Reader**: a document-info strip (folder · status · last change, plus the
  reference byline) and then the page. The strip deliberately does **not**
  repeat the title — the window title bar already carries it, and printing it
  twice a centimetre apart is exactly the chrome that makes an app feel like a
  web page in a frame. The wiki's own `**Authors:** …` byline paragraph is
  hidden in the rendered page for the same reason: the strip carries it and
  stays visible while you scroll.
- **Inspector**: outline or backlinks, switched by a segmented control. Both
  answer "where am I in this, and what points here?"; neither earns a permanent
  column. Backlinks show the *line* that mentions the page, reduced to prose —
  a backlinks pane that shows `[[markup]]` is unreadable, and the point of the
  pane is why another page links here.
- **Status bar**: sync state, the current revision, and a warnings menu. Quiet,
  26 pt, and it never interrupts reading.

## 4. Keyboard

Every primary action has a shortcut and every shortcut is in a menu, so it is
discoverable rather than folklore.

| | |
|---|---|
| ⌘O | Quick switcher |
| ⌘F / ⌘G / ⇧⌘G | Find on page, next, previous |
| ⇧⌘F | Search all pages |
| ⌘R | Sync with GitHub |
| ⌘[ / ⌘] | Back / forward |
| ⌥⌘I | Toggle inspector |
| ⌘0 | Go home |
| Esc | Dismiss any sheet or the find bar |

Both palettes are keyboard-shaped: type, arrow, Return, with the shortcut hints
rendered in the footer. A palette you have to reach for the mouse in is slower
than the sidebar it replaces.

`.findNavigator` is macOS 26, so the find bar is hand-built over
`WKWebView.find` (macOS 11+). `WKFindResult` only reports whether anything
matched — there is no "3 of 17" without counting in JavaScript — so the bar says
found or not found, and says it explicitly rather than doing nothing.

## 5. The visual gate

SwiftUI's compile guarantees are weak; a passing build is not a passing app
(`SWIFTUI-RULES.md` §9.3). `make shots` drives the **real** app through a plan
of views and captures each one:

```sh
make shots
make shots PLAN='page:Primitives/pseudorandom-function.md,dark'
```

`ScreenshotRunner` (compiled in, inert unless `CITYDESK_SHOTS` is set) applies
each step, waits for it to settle, writes a `.ready-N` marker and blocks;
`scripts/shots.sh` captures the window with `screencapture -l` and answers with
`.go-N`. Plan steps: `home`, `page:<path>`, `folder:<slug>`, `switcher:<query>`,
`search:<query>`, `outline`, `backlinks`, `light`, `dark`.

The capture needs the **Screen Recording** permission (System Settings → Privacy
& Security). Without it the script falls back to an in-app composite —
`cacheDisplay` plus `WKWebView.takeSnapshot` — which needs no permission and
renders everything *except* `NSVisualEffectView` backdrops, because their blur
happens in the window server. Sidebars come out flat. Good enough to check the
reader, not the chrome.

This gate has already earned itself: it is how the quick switcher's stale-rows
bug was found, and the bug was invisible to the unit tests because the *model*
was correct.
