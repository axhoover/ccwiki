# Reader comforts: tabs and windows, reference PDFs, incremental indexing

**Spec, 2026-10-12, revised after review the same day (§9). Built the same
day on `claude/reader-comforts`: Phase 0, A1–A6, B1–B3, C1–C6 and D1–D5.
Not built: D6, which waits for a release-build measurement on a Mac (§3.2).
Background tabs ship off (`WindowTabbing.joinsInBackground = false`) until
§5's checks on a Mac.** Three features that change no
fact the app shows, only how comfortable it is to read: more than one page
open at once, the paper behind a reference page, and a sync that does only
the work its pull calls for.

Everything below was read from the code at `640842b` and from the wiki at
`ab81f02`: 877 pages, 1.40 MB of markdown, 3,664 wikilinks, 430 references,
and a 343 KB `relations.json`. The corpus numbers were counted with throwaway
scripts. Nothing was compiled or run: this machine has no Swift, and CI on
macOS 15 is the only compiler. The timings in §3.1 were estimates; D1's
numbers from CI now stand beside them, measured on a debug build, so they
cannot decide D6 (§3.2).

> `CLAUDE.md` asks for the **swiftui-pro**, **typography-designer** and
> **macos-design** skills before and after deciding on code. None is
> installed in this session, the same gap [design-system.md](design-system.md)
> and [relations-explorer.md](relations-explorer.md) record. This spec
> follows `SWIFTUI-RULES.md`, cited by section, and design-system §1 for type:
> it adds no type style, and every new label uses an existing `Theme.Fonts`
> role. Each implementation track runs whichever of the three skills is
> installed by then, before and after its code.

---

## 0. Decisions

Each is decided here, with its reason. The ones marked **(maintainer)** are
recommendations that need a yes; §8 lists them as questions.

1. **One library, one session per window.** `AppModel` keeps its name and
   becomes the app-wide model: the wiki, the search index, jobs, sync,
   updates, settings. A new `ReaderSession` holds what a window shows: its
   location, history, web view, sidebar selection, inspector and sheets.
   Renaming `AppModel` would touch every file and change no behaviour.
2. **A reader window is `WindowGroup(for: ReaderWindow.self)`.** The value
   carries the window's identity and where it opens. Its changing state is
   kept in `@SceneStorage`. Tabs are macOS's own window tabs; a new tab is
   joined to its window with AppKit's `addTabbedWindow(_:ordered:)`, the one
   step SwiftUI has no API for.
3. **⌘-click opens a link in a new tab behind the current one**, ⇧⌘-click in
   a new tab in front, ⌥⌘-click in a new window, and a middle-click in a
   background tab. That is Safari's default. Today ⌘-click opens the linked
   page on cryptology.city; the link's context menu gains **Open Link on
   cryptology.city** for that. **(maintainer)**
4. **⌘N is New Window and ⌘T is New Tab; both open Home.** Only the first
   window of a launch, or the first after every reader window has closed,
   opens the page read last (§1.7).
5. **Search queries are app-wide; the sheets are per window.** ⌘S in any
   tab reopens on the last search. In a palette, Return opens the highlighted
   hit where you are; ⌘Return opens it in a background tab and leaves the
   palette open, so you can open hit after hit; ⇧⌘Return opens it in a front
   tab and closes the palette.
6. **Restoration follows macOS.** When the system restores windows, every
   reader window and tab comes back with its page, history and inspector.
   After a plain Quit, macOS closes windows by default and restores nothing,
   so one window opens at the last page, as today. CCwiki keeps no session
   list of its own. **(maintainer)**
7. **Text size stays one preference**, applied to every tab.
8. **A paper opens in a window of its own**, one per paper, at the trailing
   edge of the screen. It is not a split pane and not the inspector (§2.2).
   **(maintainer)**
9. **A paper is fetched only when asked, from the reference's own link**:
   ePrint, arXiv or ECCC full text, a direct PDF, or a landing page's
   `citation_pdf_url`. It is kept in `library/papers/`. There is no
   third-party lookup and no publisher-specific scraping. When CCwiki cannot
   fetch the paper, you can drop in your own copy. **(maintainer)**
10. **Show Paper is ⌥⌘P**, in the Wiki menu and on the reference bar.
    **(maintainer)**
11. **Change is detected by content fingerprints**: a SHA-256 of every file,
    for clones and snapshots alike. That departs from the brief, which named
    git's changed-file list for clones. Fingerprints cost about as much as one
    `git diff` (§3.3), need no previous commit, catch a clone edited by hand,
    and are one code path that tests can drive without git. Git is still
    used, for per-file dates over the pulled range only.
12. **The full build stays the definition.** Every incremental result must
    equal it, tests prove that on fixtures and on the real corpus, and any
    doubt falls back to it.
13. **A sync that changes nothing reloads nothing.** Today every launch
    reloads twice: once from disk, then again when the launch sync answers
    "already up to date".
14. **The search index keeps a digest per row and the build that wrote it.**
    A launch whose index already matches writes nothing.

---

## 1. Tabs and windows

### 1.1 What a reader gets

- **File ▸ New Window** (⌘N) and **File ▸ New Tab** (⌘T), each at Home.
  They are the File menu's only New items:
  `CommandGroup(replacing: .newItem) { New Window ⌘N; New Tab ⌘T; Divider;
  Quick Switcher… ⌘O; Ingest a Paper… ⇧⌘N }`.
- **Links.** ⌘-click opens a background tab, ⇧⌘-click a front tab, ⌥⌘-click a
  new window, a middle-click a background tab. A plain click, or ⇧ or ⌥
  alone, opens the link where you are.
- **The link context menu** gains **Open Link in New Tab**, **Open Link in
  New Window** and **Open Link on cryptology.city**, for links to wiki pages,
  in place of WebKit's own new-window item, which the reader already removes.
- **Rows that are buttons** (Cited by, the collapsed Reductions and
  References rows, backlinks, relations, palette rows) open a background tab
  on ⌘-click, through `LinkDisposition.current`, and get **Open in New Tab**
  and **Open in New Window** first in their context menu. The inspector's
  derived rows are the exception: a click on one shows its proof in the
  explorer, not a page, so ⌘-click keeps that meaning, and the two items go
  directly after the row's Open “…” item. relations-followups adds Copy
  Proof As to the same menu; §10 has the whole menu.
- **The sidebar tree's page rows** are `List` selection, not buttons, so
  ⌘-click keeps `List`'s own meaning, as in Finder's and Mail's sidebars.
  Their context menu starts with Open in New Tab, Open in New Window and a
  divider, then today's Open on cryptology.city, Copy Link, Copy Wikilink and
  Reveal in Finder. A folder label's menu becomes Open Folder Page, Open
  Folder Page in New Tab, Open Folder Page in New Window.
- **The palettes** (⌘O, ⌘S, ⇧⌘R, ⇧⌘F): Return opens in place, ⌘Return in a
  background tab with the palette left open and its highlight kept, ⇧⌘Return
  in a front tab, closing the palette. Until background tabs are on (§1.4),
  ⌘Return opens a front tab and closes the palette too. Both are key
  equivalents on
  zero-size, `opacity(0)` buttons (`.keyboardShortcut(.return, modifiers:
  .command)` and `[.command, .shift]`), as IngestSheet's Start Job is, so the
  field's `onSubmit` never fires as well. The Quick Switcher footer reads
  "↑↓ Move · ↩ Open · ⌘↩ New Tab · esc Cancel". `SearchPalette` keeps its
  count and Done and gains one "⌘↩ New Tab" hint before the `Spacer`, in the
  same keycap style, extracted from QuickSwitcherView's `hint(_:_:)` into a
  shared `KeyHint` view (`SWIFTUI-RULES` §8.6).
- **Each tab has** its own page, Back and Forward, scroll position, find bar,
  inspector visibility and tab, sidebar selection and expanded folders, and
  web view.
- **All tabs share** the wiki, the search index, jobs, settings, sync state,
  warnings, text size, recent pages and the search queries.
- **macOS supplies the rest**: View ▸ Show Tab Bar and Show All Tabs, Window
  ▸ Merge All Windows, Move Tab to New Window, ⌃Tab and ⌃⇧Tab, ⌘W to close a
  tab, and the tab bar itself.

### 1.2 One library, one session per window

```
CCwikiApp
 ├─ WindowGroup(id: "ccwiki.main", for: ReaderWindow)    one per reader window or tab
 │    └─ ReaderWindowView ─ ReaderSession ─ WebController ─ WKWebView
 │         └─ RootView: sidebar · reader · inspector · sheets · status bar
 ├─ WindowGroup("Paper", id: "ccwiki.paper", for: String)   one per paper (§2)
 ├─ Window("Jobs"), Window("Relations Explorer"), Settings
 └─ @State AppModel: library, search, jobs, sync, updates, papers, the sessions
```

What stays and what moves:

| `AppModel` keeps (app-wide) | `ReaderSession` gets (per window) |
|---|---|
| Configuration, tools, every preference (`hidesStubs`, `showsLinkPreviews`, `showsMaintenanceNotices`, updates), and `pageZoom`, moved here from `WebController` | `webController`, one per session |
| The library: `index`, `macros`, `backlinks`, `relations`, `relationLabels`, `linkPreviews`, `derivation`, `unlistedPaths`, `modifiedDates`, `headRevision`, `headDate`, `libraryGeneration` | `history`, `location`, `canGoBack`, `canGoForward`, `pendingFind` |
| `pageTree`, the counts, `isBrowsable`, `title(forPath:)` | `sidebarSelection` |
| Sync state and log, warnings, jobs, updates, the installation check | `expandedFolders`, `inspectorTab`, `showInspector`: seeded from `CCwikiSettings` and written back, so a new window starts as the last one was left |
| Search: every query, its results and its debounce task; the quick switcher's query, results and `quickSwitcherExcludedPath`; `recentPages` | `quickSwitcherPresented`, `searchPresented`, `referenceSearchPresented`, `grepPresented`, `syncLogPresented` |
| The explorer's question, recents and window requests; `derivedSectionsExpanded` | The page on screen: `currentPage`, `currentBacklinks`, `currentRelations`, `currentDerivations`, `citingPages`, `currentSiteURL`, `currentTitle`, `currentPageExplorerQuery`, `canExploreCurrentPage` |
| `ingestSheetTarget` and `pendingDroppedPDF`: the ingest sheet, pinned to one window (§1.3) | Navigation: `open`, `openPage`, `navigate`, `goBack`, `goForward`, `openHome`, `openRandomPage`, the `open…Result` trio, `openRelationObject`, `showWelcome`, `showWhatsNew`, `presentQuickSwitcher`, `printCurrentPage`, `renderCurrent` |
| `changelog`, `whatsNewSince`, `documentRequest(_:)` | |
| New: the session registry, the active session, tabbing requests, `launchIfNeeded`, the launch document, the cold start | `openInReader`, set by its window's view (§1.4) |

**Three rules hold the split together:**

- **A view inside a reader window reads its own window's session**, from
  `@Environment(ReaderSession.self)`. It never reads "the active one": two
  windows side by side show different pages, and each inspector must follow
  its own.
- **A window that is not a reader never reads a session.** The explorer,
  Jobs, the paper window and Settings use a small "active reader" API on
  `AppModel` (§1.8), or `@Environment(ReaderSession.self) var session:
  ReaderSession?` where a view is shared. A non-optional environment object
  that is missing crashes.
- **`AppModel` never renders.** It tells sessions that the library or a
  preference changed (`libraryDidLoad`, `preferencesDidChange`), and each
  session decides what to re-render (§3.6).

### 1.3 Scenes, and how a window gets its session

```swift
WindowGroup(id: CCwikiApp.mainWindowID, for: ReaderWindow.self) { $window in
    ReaderWindowView(window: $window)
        .environment(model)
        .frame(minWidth: Theme.windowMinWidth, minHeight: Theme.windowMinHeight)
        .onAppear { appDelegate.model = model }
} defaultValue: {
    ReaderWindow()
}
.defaultSize(width: Theme.windowDefaultWidth, height: Theme.windowDefaultHeight)
.windowResizability(.contentMinSize)
.commands { CCwikiCommands() }
```

**`ReaderWindow` is the window's identity and its opening request**: a UUID,
and optionally the location and the text to find when it opens (§4.6). Every
value is unique, so `openWindow(id:value:)` always opens a new window.
`WindowGroup(for:)` brings an existing window forward when given a value it
already shows, and a fresh UUID never matches. ⌘N, `openWindow(id:)` without
a value and the tab bar's + button all get `defaultValue`.

**`ReaderWindowView`** is new, and it is the only place a session meets a
window. It does six things:

1. **Claims the session once it has a window.** Until its `WindowReader`
   reports the `NSWindow`, it shows a plain background, so no web view is
   mounted. Then `model.claimSession(for: window.id, windowNumber:)` returns
   the session for that id, created once and kept in the view's `@State`;
   nothing is created while `body` is evaluated. It returns nil when the id
   is attached to another live window (a restoration oddity) or was closed
   earlier in this process (`closedIDs`). The view then writes a fresh UUID
   to its binding and claims again. So one `WKWebView` is never in two
   windows, and a closed id never comes back. On the same first report, when
   `model.takeTabbing(for: window.id)` returns a request, it calls
   `WindowTabbing.join(_:to:inBackground:)` (§1.4).
2. **Installs it**:
   - `.environment(session)`;
   - `.focusedSceneValue(\.readerSession, session)` and
     `.focusedSceneValue(\.appModel, model)`, the latter moved here from
     `RootView`;
   - `session.openInReader`, built from this view's `openWindow` (§1.4);
   - `.handlesExternalEvents(preferring: ["*"], allowing: ["*"])`, so a
     `ccwiki://` link or a PDF from Finder goes to an open window. SwiftUI
     otherwise opens a new window for each external event;
   - `nsWindow.tabbingIdentifier = "ccwiki.reader"`, so readers tab only
     with readers whatever the "Prefer tabs" setting.
3. **Restores and saves** through two `@SceneStorage` keys, both ignored
   under the screenshot harness (`ScreenshotRunner.directory != nil`):
   - `ccwiki.reader.state` holds `ReaderSessionState` as JSON: the history,
     the inspector and the expanded folders. It is written on every change of
     `session.restorationState`.
   - `ccwiki.reader.anchor` holds the heading being read, written when
     `webController.activeHeadingID` changes. It is kept apart so scrolling
     does not re-encode the history.
4. **Tracks the key window.** Its `WindowReader` observes
   `NSWindow.didBecomeKeyNotification` for its own window and calls
   `model.sessionBecameKey(id)`. `controlActiveState` would also work, but the
   macOS 15 SDK deprecates it in favour of `appearsActive`, which macOS 14
   lacks.
5. **Ties the session's life to the window's.** It observes
   `NSWindow.willCloseNotification` for its own window and calls
   `model.sessionDidClose(id)`, which drops the session and its web view and
   adds the id to `closedIDs`. `onAppear` and `onDisappear` are not used:
   SwiftUI may call `onDisappear` when a window is only ordered out, as a
   deselected tab or a minimised window can be. `mainWindowCount` is the
   number of live sessions.
6. **Starts it.** Once claimed, `.task` runs `session.start(_:)` with a
   `SessionStartPlan` (§1.7; a second call does nothing), then
   `await model.launchIfNeeded()`, then the screenshot runner once. The
   explorer-request hook moves here from `ReaderWindowHooks`.

`RootView` keeps the split view, the toolbar, the sheets (now bound to the
session's flags), the drop target, the status bar, `onOpenURL` (now
`session.handleOpenURL(url)`, so the window SwiftUI chose and brought forward
is the one that navigates) and the Jobs and Settings request hooks. Several
windows answering the same Jobs or Settings request is harmless:
`openWindow` on a single `Window` scene and `openSettings()` only bring that
window forward.

**The ingest sheet is pinned to one window.** `model.requestIngestSheet(in:)`
fixes `ingestSheetTarget` when the sheet is asked for: to the window a PDF
was dropped on, or whose menu or `onOpenURL` asked, else the active reader.
With no reader open the request waits, and the next session to appear claims
it. Each window binds
`.sheet(isPresented: Binding(get: { model.ingestSheetTarget == session.id },
set: { if !$0 { model.dismissIngestSheet() } }))`. A change of key window
never moves it, so the sheet's link, notes and dropped PDF survive a click on
another window. A request from outside a reader (the Jobs window's New
Ingestion Job…, which corrections renames Ingest a Paper) brings the target
window forward with
`makeKeyAndOrderFront`. While the sheet is up, a second request only brings
its window forward, and the other windows' drop targets refuse PDFs, as does
`onOpenURL` for a PDF from Finder: the sheet up reads none, so one staged for
it would wait and join the next ingestion. The
bookkeeping is the pure `IngestSheetTarget` (§4.6).

### 1.4 Opening a page elsewhere

`LinkDisposition` (§4.6) is what a click means:

| Gesture | Disposition |
|---|---|
| click; ⇧-click; ⌥-click; Return in a palette | `.here` |
| ⌘-click; middle-click; Open in New Tab; ⌘Return in a palette | `.newTab(inBackground: true)` |
| ⇧⌘-click; ⇧⌘Return in a palette | `.newTab(inBackground: false)` |
| ⌥⌘-click; ⌥⇧⌘-click; Open in New Window | `.newWindow` |
| Open Link on cryptology.city; until B1, any ⌘- or ⇧-click, as today | `.onSite` |

**Two routes in, one way out.** Each route ends in
`openWindow(id: mainWindowID, value: ReaderWindow(opening:find:))` together
with a `ReaderWindowRequest` that names the window to join as a tab:

- **Inside a reader window**, SwiftUI views and AppKit alike end in the
  session. Views call `session.open(_:_:find:)`. A link in the web view or
  the page's context menu goes through
  `WebController.onNavigate(destination, disposition)` to
  `session.navigate(to:disposition:)`. For `.here` the session opens the
  location itself, and for `.onSite` the page on cryptology.city. Otherwise
  it registers the tabbing with
  `model.expectReaderWindow(_:)` and calls `session.openInReader`, an
  `@ObservationIgnored` `OpenInReaderAction` whose closure ReaderWindowView
  built from its own `openWindow`. No queue is needed: every session has its
  view.
- **Menu commands** call `openWindow` directly, after `expectReaderWindow`
  when a reader window is key (⌘T).

**Joining the tab group.** `WindowTabbing.join(window, to: source,
inBackground:)` runs when the new window's `WindowReader` first reports its
`NSWindow`:

1. Set the window's `alphaValue` to 0, so it never flashes as a window of
   its own.
2. `source.addTabbedWindow(window, ordered: .above)`.
3. In the background, `source.makeKeyAndOrderFront(nil)`, which selects the
   source tab again. In front, `window.makeKeyAndOrderFront(nil)`.
4. Set `alphaValue` back to 1.

If the source window is gone (closed in between), the new window stays a
window of its own. Background placement is behind
`WindowTabbing.joinsInBackground`, which ships `false`: every new tab opens in
front until the maintainer has checked §5's tab items on a Mac and flipped
it. Until then ⌘Return closes the palette, as ⇧⌘Return does
(`LinkDisposition.keepsPaletteOpen`). If a live run shows flicker or a
misplaced tab that cannot be fixed, the next fallback is a plain window.
Either keeps every feature but the placement.

**A palette stays open over a background tab.** If AppKit refuses to add a
tab to a window with a sheet attached (a §5 check), ⌘Return closes the
palette first, as ⇧⌘Return does.

**A new tab with `find`** (⌘Return on a ⌘S hit that matched body text)
renders its page and then runs the same `findFirst(of:)` a search hit runs
today, so it lands on the match.

### 1.5 Routing commands to the frontmost window

`CCwikiCommands` reads `@FocusedValue(\.readerSession)` for everything about
a page. It keeps `@FocusedValue(\.appModel)` for app-wide items, so those
stay enabled exactly when they are today: when a reader window is key.

| Command | Keys | Goes to | Enabled when |
|---|---|---|---|
| New Window | ⌘N | `openWindow(id:value:)` | always |
| New Tab | ⌘T | the same, as a tab of the key reader window | always; with no reader key, a window |
| Quick Switcher… | ⌘O | `session.presentQuickSwitcher()` | a reader is key |
| Ingest a Paper… | ⇧⌘N | `model.requestIngestSheet(in: session.id)` | a reader is key (today) |
| Find on Page, Next, Previous | ⌘F ⌘G ⇧⌘G | `\.findAction`, from that window's `ReaderView` | as today |
| Find in All Pages… | ⇧⌘F | `session.grepPresented` | a reader is key |
| Search the Wiki… | ⌘S | `\.searchAction`, `session.searchPresented` | as today |
| Search References… | ⇧⌘R | `session.referenceSearchPresented` | a reader is key |
| Print… | ⌘P | `session.printCurrentPage()` | `session.location != .empty` |
| Bigger, Smaller, Actual Size | ⌘+ ⌘− ⌘0 | `model.pageZoom`, every tab | a reader is key; Actual Size when `pageZoom != 1` |
| Zoom In, Zoom Out, Zoom to Fit (the same items, retitled for a PDF; Actual Size would mean 100%, as in Preview) | ⌘+ ⌘− ⌘0 | `\.paperZoom`, the key paper window's `PDFView`; Zoom to Fit turns `autoScales` back on | a paper window is key |
| Toggle Inspector; Outline, Backlinks, Relations | ⌥⌘I; ⌥⌘1–3 | session | a reader is key |
| Back, Forward | ⌘[ ⌘] | session | `canGoBack`, `canGoForward` |
| Check for Updates…, Relaunch to Update | | model | as today |
| Sync with GitHub | ⌘R | `model.sync()` | as today |
| Go Home, Random Page | ⇧⌘H | session | as today |
| Show Sync Log… | | `session.syncLogPresented` | a reader is key |
| Relations Explorer | ⇧⌘E | `openWindow` | always |
| Explore From This Page | ⌥⇧⌘E | `session.currentPageExplorerQuery`, then `model.explore` | `session.canExploreCurrentPage` |
| Show Paper | ⌥⌘P | `ShowPaperCommand.perform` (§2.6) | `session.currentPage` is a reference |
| Open on cryptology.city, Copy Link, Copy Wikilink, Reveal Page in Finder | | session | as today |
| Reveal Clone in Finder | | model | as today |
| Show Jobs | ⇧⌘J | `openWindow` | always |
| Welcome, What's New | | session | a reader is key |

**Shortcuts checked against the map in relations-explorer §2.11.** ⌘N and
⌘T are free: ⌘N is not Ingest (⇧⌘N), and CCwiki has no Format menu, so ⌘T is
not Show Fonts. ⌥⌘P is free: ⌘P is Print, and ⇧⌘P is Page Setup by
convention, so it is avoided. The system owns ⌃Tab, ⌃⇧Tab, ⌘W, ⇧⌘\ (Show
All Tabs) and ⇧⌘T (View ▸ Show Tab Bar, which AppKit adds with tabbing on);
none collides with CCwiki's ⌘[ and ⌘].

**In a paper window** Print… and Find on Page stay disabled: Preview does
them, one click away (§7).

### 1.6 Per-window chrome

- **Inspector.** Visibility and tab are per window. A new window starts as
  the most recently changed one was left. The outline, backlinks and
  relations are the window's own page's.
- **Sidebar.** The selection and the expanded folders are per window. Opening
  a page reveals it in its own window's sidebar only. The tree, the counts
  and Hide stubs are app-wide.
- **Palettes.** Each is a sheet on the window that opened it (§1.3). The
  query is app-wide. The quick switcher leaves out the page on screen in the
  window that presented it: `session.presentQuickSwitcher()` sets
  `model.quickSwitcherExcludedPath`, which `refreshQuickSwitcher()` reads on
  every keystroke.
- **Status bar.** The sync state, warnings, job count and update progress are
  the same in every window. `lastRenderError` is the window's own.
- **Find.** The find bar's text and state are `@State` in `ReaderView`,
  which is already per window, so they are per tab with no change.
- **Text size.** One `AppModel.pageZoom`, persisted as today. Setting it
  applies to every session's web view.
- **Titles.** Each window's title is its page's display title, which is what
  its tab and the Window menu show. The reference subtitle stays.

### 1.7 Launch and restoration

**The launch runs once per process.** Today `RootView.task` is the launch
sequence, and with several windows it would run once per window. It becomes
`AppModel.launchIfNeeded()`. The first caller runs it, and later callers
await the same `Task`:

1. `discoverTools()`
2. `loadJobHistory()`, until corrections lands: its `JobCenter.init` loads
   the history before any window exists, and its integrator deletes this
   step (corrections §4.3, §17)
3. `loadLibrary(reason: .launch)`
4. `checkInstallation()`, still before the launch sync, for the reason
   [update-integrity.md](update-integrity.md) §2.3 gives
5. the launch sync, under the same conditions as today
6. the daily update check, not under the screenshot harness

Reader windows and paper windows both call it (§2.6), so a paper window that
macOS restores alone still loads the wiki. Once corrections lands, its
editor windows and the Jobs window call it too, for the same reason: a
review restored without a reader still needs git (§10).

**How a session starts is one pure decision**, `SessionStartPlan.plan(…)`
(§4.6), so the riskiest rule of Part 1 is tested without a window. Its
inputs: the restored state, the window value's `opening`,
`model.takePendingReaderLocation()`, `model.takeLaunchDocument()`,
`model.takeColdStart()` (true for the first session of the process, and
again for the first after every reader window has closed) and
`CCwikiSettings.lastPage` (nil under the screenshot harness). The rules:

1. **A restored state wins.** It seeds the history, and the window value's
   `opening` and `find` are ignored: macOS restores the value too, and a tab
   first opened by ⌘-click must not reopen its first page over its history.
2. **The launch document shows at once.** `takeLaunchDocument()` returns
   Welcome or What's New once per process, so only the first window shows
   it. A restored page goes onto Back behind it.
3. **Once the wiki is loaded** (`libraryDidLoad`, or at once if it is
   already loaded), a restored history drops pages the wiki no longer has
   (`NavigationHistory.pruned(keeping:)`) and renders at its saved reading
   anchor. A pending location then opens in any session. A session with no
   restored state opens its opening, over the launch document if it shows
   one, as a paper window's Show Reference Page asks with no reader open.
   One with neither a restored page nor the launch document opens the last
   page if this is the cold start, else Home.

So a cold launch opens the last page, and while a reader is open, ⌘N, ⌘T
and the tab bar's + button open Home. A last page the wiki no longer has
falls back to Home. Closing every reader window hands out the cold start
again, so the next reader to open, from the Dock icon, ⌘N or ⌘T, is on the
page read last, as after a relaunch.

**A link that arrives before the wiki loads is kept.** While the wiki is not
loaded, `session.open(.page…)` replaces the session's pending location
instead of returning (today `open` drops it at `index == nil`), and the
session opens it in `libraryDidLoad`. A `ccwiki://` link that launches the
app then lands.

**What comes back when:**

| Situation | What opens |
|---|---|
| macOS restores windows: "Close windows when quitting an application" is off, or after a logout with Reopen windows | Every reader window and tab, each with its page, reading position, Back and Forward, inspector and expanded folders. Paper windows reopen on their papers. The explorer and Jobs as today |
| Quit and Keep Windows (⌥⌘Q, or Option held on the app menu's Quit) | The same, as when the setting is off |
| A plain Quit with that setting on, which is the macOS default | One window: the launch document, else the last page, else Home. This is today's behaviour |
| A relaunch CCwiki starts itself (Relaunch to Update, Replace and Relaunch, "Open CCwiki x.y") | As a plain Quit. Keeping tabs across it is in §7 |
| Every reader window closed, then the Dock icon, ⌘N or ⌘T | As a plain Quit: one window at the last page, else Home. A page the explorer asked for meanwhile wins, and a paper window's Show Reference Page opens its own page |
| A ccwiki:// link or a PDF from Finder | The reader window SwiftUI hands it to, which it brings forward; a reader window first if none is open |

**Tab groups** are restored by AppKit's window restoration. That is expected
but unproven for SwiftUI-managed windows (§6). If it fails, restored tabs come
back as separate windows, and Window ▸ Merge All Windows rejoins them.

**`lastPage` and recents** are written by whichever session navigates, so the
cold start after a Quit opens the page read last in any window.

### 1.8 The explorer, Jobs and paper windows

None of them is a reader, so none has a session. `AppModel` keeps a small API
for them that targets the **active reader**: the most recently key reader
window, tracked by `SessionOrder` (§4.6). Unlike the session registry,
`SessionOrder` is observed, so the explorer's Explore From This Page button
follows the key reader.

- **`model.open(_:)`, `openPage(_:anchor:)`, `openRelationObject(_:)` and
  `navigate(to:)`** render in the active reader without activating it, so the
  explorer stays key as relations-explorer §2.1 requires. With no reader
  open, they keep the location as `pendingReaderLocation`, which the next
  session to start takes. The explorer already opens a reader window when
  `mainWindowCount == 0`. Its two `openWindow(id: CCwikiApp.mainWindowID)`
  calls gain `value: ReaderWindow()`.
- **`model.currentPageExplorerQuery` and `canExploreCurrentPage`** forward to
  the active session, for the explorer's own Explore From This Page button.
- **`mainWindowCount`** keeps its name and meaning: reader windows on screen,
  counted by the registry, one per tab.
- **Jobs.** New Ingestion Job… calls `model.requestIngestSheet(in: nil)`.
  The sheet appears on the active reader window, which comes forward. With
  no reader open it waits for the next one, as today.
- **A paper window's Show Reference Page** is an explicit Show, so it must
  be seen. `model.revealInReader(_:)` prefers a reader tab already showing
  that page, else the active reader, opens the page there and brings that
  window forward (`NSApp.window(withWindowNumber:)?.makeKeyAndOrderFront`).
  With no reader open it returns false, and the paper window calls
  `openWindow(id: mainWindowID, value: ReaderWindow(opening:))`.
- **⌘T or ⌘N while the explorer, Jobs, a paper or an editor is key** opens
  a reader window, not a tab of that window. The tabbing identifiers are set
  explicitly rather than left to SwiftUI: readers `"ccwiki.reader"`, papers
  `"ccwiki.paper"`, corrections' editors `"ccwiki.editor"`, and Jobs and
  the explorer get `tabbingMode = .disallowed`.

### 1.9 Web views and memory

Every tab has its own `WKWebView`, and WebKit gives each its own WebContent
process: tens of megabytes with KaTeX, the fonts and a long page. Ten tabs
cost a few hundred megabytes. Three choices keep that down:

- **One `WKWebsiteDataStore.nonPersistent()` for every reader**
  (`WebController.sharedDataStore`). Today each controller would make its
  own, and with it a separate network process for each.
- **`paths.stagedWebRoot()` runs once**, in `AppModel.init`, and every
  session gets the URL. It copies the pipeline on first use. Reading
  `model.webRoot` checks the copy (`AppPaths.keepStagedWebRoot`, also on
  activation and hourly): it is marked in use, and staged again at the same
  path only if Caches lost it while the bundle on disk is still this build.
- **A closed tab releases its web view.** The session leaves the registry
  when its window posts `willCloseNotification` (§1.3). The `Bridge`,
  `onNavigate` and `onReady` closures capture `[weak self]` already.

There is no tab limit and no unloading of background tabs (§7).

### 1.10 The steps

Part 1 is the riskiest refactor in this batch, so it is split into small
steps. Each step is one commit pushed to the track's draft PR, and its gate
is green CI (`make check` and `make test-corpus`): no agent in the pipeline
has a Mac, and CI does not run `make shots`. Steps marked "nothing visible
changes" must also leave `make shots` identical, which the maintainer checks
on a Mac before the PR leaves draft (§4.7). Phase 0 (§4.1) comes first.

**Track A: sessions and windows**

- **A1, pure types.** `NavigationHistory` becomes `Codable`, with
  `init(current:back:forward:)` and `pruned(keeping:)`. Add
  `ReaderSessionState`, `SessionStartPlan`, `ReaderWindow`,
  `ReaderWindowRequest(s)`, `SessionOrder` and `IngestSheetTarget`, with
  their tests. Nothing visible changes.
- **A2, the move.** Add `ReaderSession.swift` with the members §1.2 lists,
  moved, not rewritten. `AppModel` creates one `primarySession` at the end of
  `init` and forwards every moved member under its old name, so no view
  changes. Nothing visible changes.
- **A3, the views.** Every reader view reads `@Environment(ReaderSession.self)`.
  That covers `RootView`, `ReaderView`, `SidebarView`, `InspectorView`,
  `RelationsView`, `DerivedRelationsSections`, the four palettes and
  `SyncLogView`'s presenter. `RootView` injects `model.primarySession`, and
  the commands read `\.readerSession`. The forwarders go, except the active
  reader API of §1.8, which still means `primarySession` here. Nothing
  visible changes.
  - The gate is a grep: in `UI/`, no `model.location`, `model.webController`,
    `model.currentPage`, `model.openPage` or `model.goBack` remains outside
    `RelationsExplorerView`, `JobsView` and `SettingsView`. Corrections'
    integrator runs it again after rebasing, with its `ReviewView` and
    `EditorWindow` added to the exceptions, since neither is a reader (§10).
- **A4a, the scene, one window.** `WindowGroup(for: ReaderWindow.self)`,
  `ReaderWindowView` with the claim and the `willClose` lifetime of §1.3,
  `launchIfNeeded`, and `SessionStartPlan` driving the one session. The
  explorer's two `openWindow` calls gain a value. Nothing visible changes.
- **A4b, many windows.** The registry, `SessionOrder`, the fan-out of
  `libraryDidLoad` and `preferencesDidChange`, the pinned ingest sheet,
  `revealInReader`, New Window (⌘N), and
  `ScreenshotRunner.run(model:session:openWindow:)` with a `window:` step.
  The first visible change: ⌘N.
- **A4c, restoration and links.** `@SceneStorage` restoration and
  `session.handleOpenURL`, with the pending location kept while the wiki
  loads.
- **A5, tabs and targets.** The visible change is tabs, and ⌘-click no longer
  opening the site.
  - New Tab (⌘T), `OpenInReaderAction` and `session.open(_:_:find:)` for the
    three dispositions.
  - The context-menu items of §1.1. ⌘-click through
    `LinkDisposition.current` on button rows only; the sidebar tree's page
    rows and folder labels get the menu items alone.
  - ⌘Return, ⇧⌘Return and the footer hints in the palettes.
  - `AppModel`'s `onNavigate` stops opening the site on a modified click.
  - The `tab:` and `bgtab:` shots.
- **A6, docs.** [design-system.md](design-system.md) §4 gains the new keys,
  and §3 the per-window chrome. Track A's PR description says what
  [architecture.md](architecture.md) should gain; the integrator writes it.

**Track B: tab joining and link targets**

- **B1.** The real `LinkDisposition.forClick` table, with
  `LinkDispositionTests`.
- **B2, the web view.**
  - `ccwiki.js` posts `navigate` with `command`, `shift`, `option` and
    `middleButton` in place of `modified`. WebKit may not dispatch
    `auxclick`, so the middle button is detected from `mousedown` and
    `mouseup` with `event.button === 1`. `WebController` also falls back to
    `WKNavigationAction.buttonNumber` and `modifierFlags` in
    `decidePolicyFor` and `createWebViewWith`.
  - `contextTarget` reports the link under the pointer (`link`: an internal
    href or `null`). Corrections adds `selection` to the same message, so
    its keys end up `type, tex, algorithm, algorithmExpanded, link,
    selection`. The middle-button `mousedown` and `mouseup` listeners are
    listeners of their own: they return at once for any other button and
    never call `preventDefault`, because corrections adds a capture-phase
    `mousedown` listener for the right button (corrections §3.3).
  - `WebController` parses both. `ReaderContextTarget` gains `link` and
    `linkItems`; `link` is a defaulted init parameter after
    `algorithmExpanded`, and corrections' `selection` follows it (§10).
  - `ReaderWebView.willOpenMenu` inserts the three link items after WebKit's
    "Open Link", or, if it is absent, directly after the copy items.
  - `ReaderContextMenuTests` grows to cover them.
- **B3.** The real `WindowTabbing.join`, with `joinsInBackground = false`
  (§1.4). The maintainer flips it after §5's tab checks.

---

## 2. Reference PDFs, on request

### 2.1 What the references carry

Counted over all 430 pages in `content/References`. Every page has `source:`,
a single URL, and its byline's `[Source](…)` repeats it on 426 of them. Only
two body links differ from `source`: a malformed copy of the same DOI, and a
link to a different paper. So the body is not a source of candidates. Of the
72 inline `bibtex` entries, 32 carry a `url` and one an `eprint` field.

| `source` points at | Pages | What a GET returns |
|---|---|---|
| IACR ePrint (`/YYYY/NNN`, one `.pdf`) | 205 | the full text at `/YYYY/NNN.pdf` |
| arXiv (`/abs/…`) | 31 | the full text at `/pdf/…` |
| ECCC | 1 | the full text at `/report/Y/N/download/` |
| A direct `.pdf` (core.ac.uk, ntru.org, falcon-sign.info, the IACR archive) | 4 | the PDF |
| doi.org | 114 | a redirect to a publisher's page |
| dl.acm.org | 26 | a publisher's page |
| link.springer.com | 20 | a publisher's page |
| ieeexplore.ieee.org | 10 | a publisher's page |
| epubs.siam.org | 9 | a publisher's page |
| sciencedirect.com | 3 | a publisher's page |
| cic.iacr.org (open access) | 1 | a landing page that names its PDF |
| microsoft.com research pages | 2 | a landing page |
| dblp.org searches | 2 | a search page, no PDF |
| An author's homepage; an AMS book page | 2 | no PDF |

So **241 references (56%) have a link to the full text itself**. The other
189 point at a landing page. Some name their PDF in a
`<meta name="citation_pdf_url">` tag, which most publishers emit, but that
link is usually behind a subscription or a bot check. The wiki's
`reference-fixer` bot already prefers ePrint and arXiv where a version
exists, so most of the DOI-only references are older papers without a
preprint.

`IngestSubmission.Source.parse` and `fullTextURL` already recognise ePrint,
arXiv, ECCC and DOI in every shape the wiki uses, and `SubmissionSourceTests`
covers them. The paper code reuses them rather than parsing again.

### 2.2 Where the paper shows: a window of its own

| Option | For | Against |
|---|---|---|
| **A split pane in the reader column** | Literally beside the page | Crowded. A 1280 pt window less the sidebar (268) and the inspector (280) leaves 732 pt, so a 50:50 split gives the paper about 430 pt. A US Letter page then shows at about 70%, and 10 pt type at 7 pt. Worse, the pane must either follow the reader (and disappear when you open the definition a paper relies on) or stay pinned to a reference that is no longer on screen |
| The inspector | Already there, collapsible | Its job is properties of the page, it is 240–400 pt wide, and it would push Outline, Backlinks and Relations behind a fourth segment |
| **A window of its own** (chosen) | A PDF is a document, and on the Mac a document gets a window, as in Preview, Books and BibDesk. The paper stays put while the reader moves through the wiki. It can be as large as the screen, and it tiles beside the reader | One more window to manage |

**So: one window per paper**, `WindowGroup("Paper", id: "ccwiki.paper", for:
String.self)`, keyed by the reference page's path:

- **Show Paper twice brings the same window forward**, because `WindowGroup`
  de-duplicates by value.
- **It opens at the trailing edge of the screen** (`.defaultPosition(.trailing)`)
  at 780 × 980, a page and its margins, no taller than the screen's visible
  frame: on first show its `WindowReader` clamps the frame to
  `screen.visibleFrame`, since a 13-inch MacBook Air has about 870 pt. Its
  minimum is 480 × 560. Beside a 1280 pt reader on a laptop it overlaps; the
  Mac's own tiling puts the two side by side.
- **It is restored like any window.**
- **It never handles external events**:
  `.handlesExternalEvents(matching: [])`, so a `ccwiki://` link never opens
  an empty paper window.
- **Paper windows tab with each other** when the user prefers tabs, but not
  with readers (§7).

### 2.3 Finding the PDF

`PaperSource(page:)` is pure. It builds the candidates from `source`, then
from the inline BibTeX's `eprint`, `url` and `doi` where they name a
different URL, in that order, without duplicates:

| Parsed link | Candidate |
|---|---|
| ePrint, arXiv, ECCC | `fullTextURL`, kind `.eprint`, `.arXiv` or `.eccc` |
| any URL whose path ends in `.pdf` | itself, kind `.pdf` |
| DOI, or any other http(s) URL | the URL, kind `.landingPage` |
| anything else, or no `source` | nothing |

The paper's file name is its citation key (the page's `title`: `BGI15`,
`FGJ+25`) with anything outside `[A-Za-z0-9+._-]` replaced by `-`, then
`.pdf`. Its identity is the reference's path, which the wiki promises never
to rename. Keys are unique only once someone notices a clash (the wiki's
CLAUDE.md), and APFS is case-insensitive by default, so `PaperStore.keep`
takes the first name no other reference's record holds, compared
case-insensitively (`SW25.pdf`, then `SW25-2.pdf`). It overwrites only the
file recorded for the same reference.

### 2.4 Fetching it once

`PaperFetcher` works through the candidates through a `PaperTransport`.
The real transport streams with `URLSession.bytes(from:)` on an ephemeral
session with `httpCookieAcceptPolicy = .never`, `httpShouldSetCookies =
false` and no cookie storage, so no cookie is kept or sent. It refuses a
response whose `expectedContentLength` is over `maximumBytes` before reading
a byte, stops at the cap otherwise, and writes to a temporary file, reporting
progress as it goes. Each request names CCwiki as `CCwiki/<version> (macOS;
+https://cryptology.city)` and has a 60-second timeout. Each response is
classified by `PaperResponse.classify`, which is pure:

| Response | What happens |
|---|---|
| 2xx, body starts with `%PDF-` in its first 1,024 bytes | accept |
| 2xx, HTML | look for `<meta name="citation_pdf_url" content=…>` (either attribute order), or `<link rel="alternate" type="application/pdf" href=…>`, resolved against the final URL, http(s) only. If found and not yet tried, try it next. If not, record `notAPDF(landingPage:redirectedFrom:)` and go on |
| 2xx, anything else (PostScript, `octet-stream`) | record `unexpected(host:detail:url:)`, detail "sent a <type> file, not a PDF", and go on |
| 401, 402, 403 | record `refused(status:host:page:)` and go on |
| 404, 410 | record `notFound(url:)` and go on |
| 429, 503 | record `busy(host:status:)` and go on |
| other 4xx and 5xx, 451, a 3xx with no `Location`, a redirect loop | record `unexpected(host:detail:url:)`, detail "answered 500", and go on |
| `URLError` `.notConnectedToInternet`, `.networkConnectionLost`, `.dataNotAllowed`, `.internationalRoamingOff` | stop: `offline` |
| `URLError` `.cannotFindHost`, `.cannotConnectToHost`, `.timedOut`, `.dnsLookupFailed` | record `unreachable(host:url:)` and go on: for a publisher these mean that host, not the Mac, is gone or slow |
| any other `URLError` (TLS, App Transport Security refusing an `http://` link) | record `unexpected(host:detail:url:)` with the error's description, and go on |
| over `maximumBytes` (100 MB) | record `tooLarge(bytes:host:url:)`, keep nothing, and go on |
| a PDF that CoreGraphics opens with no pages (`CGPDFDocument(url)?.numberOfPages == 0`, or no document) | `unreadable(host:)` |

`SnapshotService.isNetworkFailure` is not reused: four of its eight codes
mean "no network" only when the host is GitHub. A candidate with an
`http://` URL is made `https://`, since Info.plist declares no ATS exception
and plain HTTP would be refused.

If no candidate succeeds, the failure shown is the most useful one recorded,
in this order: `refused`, `notAPDF`, `notFound`, `busy`, `unreachable`,
`tooLarge`, `unreadable`, `unexpected`. No candidate at all is
`noLink(source:)`.

**Fetched only when asked.** Show Paper, from the reference bar or ⌥⌘P,
starts the fetch; a paper already in the library opens at once. A restored
paper window whose PDF is missing shows Paper Not Downloaded with a
**Download** button. It never fetches by itself at launch, or when the Mac
comes back online. One fetch runs per reference at a time, and
`PaperLibrary.cancel(_:)` stops it.

### 2.5 Keeping it

```
~/Library/Application Support/CCwiki/library/
├── <dropped PDFs>     ingestion inputs, as today
└── papers/
    ├── papers.json    one PaperRecord per reference, by path
    ├── BGI15.pdf
    └── AABN02.pdf
```

- **Under `library/`, outside the clone**, so the non-negotiable that PDFs
  never enter the repo holds by construction. CCwiki Dev has its own, under
  `CCwiki-Dev`.
- **`papers.json` is the index.** It is written atomically, and a record
  whose file is gone counts as not downloaded. A record says where the PDF
  came from: downloaded from a URL, or added by you. It also keeps the date
  and the size.
- **Download, verify, then move.** A fetch downloads to a temporary file,
  verifies it, then moves it into place, so a half-written file is never
  shown.
- **Adding your own.** Choose PDF… or a drop on the paper window keeps a copy,
  as `addedByYou`. A PDF you add has no size cap.
- **Removing.** Remove From Library moves the file to the Trash and drops its
  record, for both origins, since a downloaded paper may not download again.
  For one you added it asks first, with **Remove** (destructive) and
  **Cancel**: "Remove the PDF you added?", then "CCwiki keeps no other
  copy.", plus "It can't download this paper." when there is no candidate or
  the last fetch failed. If the Trash refuses the file, the paper stays, and
  an alert, "Couldn't Remove the PDF", gives the error's own words.
- **Nothing is evicted automatically.** Settings ▸ Storage's existing "PDF
  library" row reveals the folder. Track C changes the "Working files"
  footer, which today calls every PDF a job input, to: "PDFs, the ones you
  drop for ingestion and the papers you open, are kept outside the clone and
  never enter the repository."

### 2.6 The paper window

```
┌ BGI15.pdf — Function Secret Sharing ──────────── [Open in Preview] [⋯] ┐
│                                                                       │
│              PDFView: continuous, vertical, fit to width              │
│                                                                       │
├───────────────────────────────────────────────────────────────────────┤
│ Downloaded from eprint.iacr.org · 12 Oct 2026            Page 3 of 41 │
└───────────────────────────────────────────────────────────────────────┘
```

- **Launch.** `PaperWindowView` runs `.task { await model.launchIfNeeded() }`
  (idempotent, §1.7), and the Paper scene's content sets `appDelegate.model`
  on appear, as the reader's does. So a paper window that macOS restores
  alone loads the wiki. A PDF already in `papers.json` shows at once,
  without waiting for the wiki; every other state waits for it.
- **Title and subtitle.** Titled by its file, "BGI15.pdf", as Preview titles
  a PDF, with the paper's title as subtitle; the citation key until the PDF
  is there. `.navigationDocument(fileURL)` once it is ready gives the
  title-bar proxy icon: drag the PDF to Mail or Finder, ⌘-click the title
  for its path. The Window menu then tells "BGI15.pdf" apart from the reader
  tab "Function Secret Sharing".
- **Toolbar** (`.primaryAction`, no leading `Spacer`, `SWIFTUI-RULES` §6.2).
  **Open in Preview** opens the file with `NSWorkspace.shared.open(fileURL)`,
  in the reader's default PDF app, and is named after it
  (`urlForApplication(toOpen:)`): "Open in Preview" out of the box, "Open in
  Skim" for a Skim user. If the default is CCwiki itself, it opens Preview.
  It is enabled only when the PDF is ready. A `Menu` (`ellipsis.circle`)
  holds Show Reference Page (§1.8), Reveal in Finder, Copy Source Link, a
  divider, Choose Another PDF… and Remove From Library.
- **Body.** A `PDFView` in an `NSViewRepresentable`: `autoScales`,
  `.singlePageContinuous`, page breaks shown. Pages stay white in dark mode,
  as in Preview. It becomes first responder when the window appears, so
  Space and Page Down scroll at once. The view sets
  `.focusedSceneValue(\.paperZoom, …)`, so View ▸ Zoom In, Zoom Out and
  Zoom to Fit act on it (§1.5).
- **Bottom strip.** 26 pt on `.bar`, matching the reader's status bar.
  Provenance on the left, in `Theme.Fonts.meta`, `.secondary`, so a wrong
  paper is noticed: "Downloaded from eprint.iacr.org · 12 Oct 2026" or "Added
  by you · 12 Oct 2026", the date as `.formatted(date: .abbreviated, time:
  .omitted)`, with the full source URL as its tooltip. The page indicator on
  the right, from `PDFViewPageChanged`.
- **Drop.** The whole window accepts a PDF. Its overlay reuses the reader's
  mounted-and-faded pattern (`SWIFTUI-RULES` §1.1) and `doc.badge.plus`, with
  its own words, since the reader's promises an ingestion job: "Keep This PDF
  for BGI15" in `Theme.Fonts.emptyTitle` over "CCwiki keeps a copy in its
  library." in `meta`; "Replace the PDF for BGI15" when one is shown.
- **Show Paper** on the reference bar is a `.link`-style button after the
  Source link, labelled "Show Paper" with `doc.richtext`, in
  `Theme.Fonts.meta`. Its tooltip says what it will do:
  - "Download the PDF from eprint.iacr.org and keep it in CCwiki's library
    (⌥⌘P)", when the first candidate is full text or a PDF;
  - "Look for the PDF at doi.org and keep it in CCwiki's library (⌥⌘P)",
    when it is a landing page;
  - "Open the paper from CCwiki's library (⌥⌘P)";
  - "Add your own copy of this paper's PDF (⌥⌘P)", when there is no
    candidate.
- **`ShowPaperCommand.perform`** calls `model.papers.show(page)`, then
  `openWindow(id: paperWindowID, value: page.path)`.

### 2.7 Every state, in words

Each state that is not the PDF is a `ContentUnavailableView`
(`SWIFTUI-RULES` §7.1). Host names are the real ones from the URL tried, and
each "Open on <host>" button opens the URL that was tried (the landing page,
the missing file), not the host's front page, in the app's "Open on
cryptology.city" form.

| State | Symbol | Title | Description | Actions |
|---|---|---|---|---|
| Wiki not loaded, PDF not in the library | `ProgressView` | Loading the Wiki | | |
| Not downloaded | `doc.richtext` | Paper Not Downloaded | "CCwiki downloads it from eprint.iacr.org once and keeps it in its library." | **Download**, Choose PDF… |
| Downloading | a determinate `ProgressView` (indeterminate until the size is known) | Downloading the Paper | "From eprint.iacr.org." and "4.2 MB of 11 MB" in `Theme.Fonts.meta` | Cancel |
| No link | `doc.questionmark` | No Link to Download | "This reference has no link CCwiki can download from. If you have the paper, drop the PDF here." | Choose PDF… |
| Landing page, no PDF | `globe` | Web Page, Not a PDF | With a redirect: "doi.org led to a page on link.springer.com, not a PDF." Without: "dblp.org sent a web page, not a PDF." Then: "If you can get the paper in your browser, download it and drop it here." | Open on link.springer.com, Choose PDF… |
| Refused | `lock.doc` | Download Refused | "dl.acm.org answered 403. The paper may need a subscription, or the site may not accept downloads from apps. If you can get the paper in your browser, download it and drop it here." | Open on dl.acm.org, Choose PDF… |
| Not found | `doc.questionmark` | Nothing at This Link | "eprint.iacr.org has nothing at /2002/022.pdf. The reference's link may be wrong." | Open on eprint.iacr.org, Choose PDF… |
| Busy | `clock` | Site Busy | "arxiv.org asked CCwiki to wait (429)." | Try Again |
| Unreachable | `network.slash` | Couldn't Reach ntru.org | "ntru.org did not answer. The site may be down, or the link may be out of date." | Try Again, Open on ntru.org, Choose PDF… |
| Offline | `wifi.slash`, `.tertiary` | Offline | "The paper is not in the library yet. Connect to the internet and try again, or drop in a copy of the PDF." | Try Again, Choose PDF… |
| Too large | `doc` | Too Large to Keep | "The PDF from ntru.org is 240 MB. CCwiki downloads papers up to 100 MB; a PDF you add yourself can be any size." | Open on ntru.org, Choose PDF… |
| Unreadable | `doc.questionmark` | Not a Readable PDF | "The file from eprint.iacr.org does not open as a PDF." | Try Again, Choose PDF… |
| Unexpected | `exclamationmark.triangle` | Couldn't Download the Paper | "<host> <detail>.", e.g. "www.eccc.uni-trier.de sent a PostScript file, not a PDF." | Try Again, Open on <host>, Choose PDF… |
| Reference gone, PDF kept | the PDF | its file name | | |
| Reference gone, no PDF | the window closes itself (`SWIFTUI-RULES` §6.5) | | | |

Offline uses the app's offline vocabulary (design-system §4b): it is not a
fault. A paper already in the library opens offline like any page.

---

## 3. Incremental indexing

### 3.1 What a load does today

`AppModel.loadLibrary()` rebuilds everything from scratch, and `sync()` calls
it for every outcome but `.failed`, including `.alreadyCurrent`. So **every
launch does all of this twice**: once from disk, and again when the launch
sync finds nothing new. The estimates are order-of-magnitude guesses for an
Apple-silicon Mac, made by reading the code against the corpus sizes. D1
measured the in-memory phases on CI, in a debug build (below, and §3.8).

| Phase | Work | Estimate | After this spec |
|---|---|---|---|
| `WikiIndex.build` | list 880 files, read 1.40 MB, parse 877 pages | 30–80 ms | read and hash every file (≈10 ms); parse only changed pages |
| `backlinkMap()` | resolve 3,664 wikilinks and the markdown links on 877 pages | 40–150 ms | changed pages only, unless a file or an alias came or went |
| `RelationsManifest.load` | decode 343 KB of JSON | 10–30 ms | only when `relations.json` changed |
| `RelationLabels` | 262 objects | < 5 ms | always (cheap) |
| `TextGrep` | split 877 bodies into lines | 5–15 ms | changed pages only |
| `Derivation` | 468 single-object closures; 151 ms in the Python reference (derivations.md §4) | 10–40 ms | only when `relations.json` changed |
| `LinkPreviews` | 877 cards, a first-paragraph scan each | 30–100 ms | changed pages; reduction and barrier cards also when the manifest or labels changed |
| git | 11–15 processes per sync (below), one of them `git log --name-only` over the whole history | 100–600 ms, growing with history | about 9 per pull and 7 when nothing changed, all local but the fetch (§3.7) |
| FTS rebuild | delete and insert 877 rows (1.40 MB), `optimize`, WAL checkpoint, both rankers | 200–500 ms, a few MB written | rows whose digest changed; nothing at all at launch |
| re-render | the page on screen | 50–200 ms | each open tab whose page the pull affected (§3.6) |

The first seven rows change only if D6 is built, which waits for a release
build's numbers (§3.2, item 3). Until then `LoadedLibrary.update` is `build`,
and only the hashing is new.

**Measured by D1 on CI.** `IncrementalCorpusTests` in CI's `make test-corpus`,
on the 877 pages, the fastest of 5 builds, per `LoadTimings` phase. CI
measures a debug build (-Onone), run alongside the other suites, where pure
Swift can be several times slower than in the app. These are debug numbers,
**not comparable with §3.2's 300 ms threshold**, and they decide nothing:
D6 waits for a release-build measurement on a Mac (§3.2, item 3).

| Phase | What it covers | CI, debug |
|---|---|---|
| `read` | list the files, read and hash each once, parse the pages | 251.1 ms |
| `index` | `WikiIndex.assemble`: the resolution tables | 18.7 ms |
| `manifest` | decode `relations.json` | 7.7 ms |
| `labels` | `RelationLabels` | 53.8 ms |
| `backlinks` | `backlinkMap()` | 680.3 ms |
| `grep` | `TextGrep` | 32.0 ms |
| `derivation` | `Derivation` | 471.0 ms |
| `previews` | `LinkPreviews` | 1,042.8 ms |
| **total** | | **2,557.4 ms** |

**The git processes per sync today** (git store, no worktrees):

- `sync` itself: `rev-parse HEAD`, `fetch`, `merge --ff-only`, `rev-parse
  HEAD`.
- The summary: one `git diff --name-only`.
- The load: the whole-history `git log --name-only`, `rev-parse`, and `git
  log -1`.
- Push capability, which concerns jobs only: `config --get`, sometimes
  `config` to set it, `remote get-url`, `config --get-urlmatch`.
- `worktree list`, plus `worktree repair` and `worktree prune` when job
  worktrees exist.

All of it is off the main actor, so it is latency in "Indexing…", not a
freeze, as audit §3.5 says. Search waits on the actor while the index is
rebuilt.

### 3.2 Three changes, in order of payoff

1. **Skip what did not change**
   (`LibraryRefresh.needsReload(after:loadedRevision:isLoaded:)`).
   - `.alreadyCurrent(at:)` at the loaded revision reloads nothing. With no
     loaded revision, it reloads.
   - `.offline` reloads only if nothing is loaded yet. The clone is CCwiki's
     own, and nothing else writes there.
   - `.updated` and `.cloned` reload.
   - `.failed` does not, as today.
   This alone halves the work of every launch.
2. **Sync the search index by digest** (§3.4, last rows). A launch whose
   index matches writes nothing, and a small pull rewrites a few rows.
3. **Reuse the in-memory artifacts a change does not touch** (§3.4), but only
   if D1's suite shows the full build's in-memory phases (`WikiIndex.build`
   to `LinkPreviews` in §3.1) above 300 ms in total in a release build:
   `CCWIKI_WIKI=… swift test -c release -Xswiftc -enable-testing
   --no-parallel --filter IncrementalCorpusTests`, which the maintainer runs
   on a Mac. No CI job runs it. CI's `make test-corpus` report is a debug
   build run beside the other suites, so it is only indicative (§3.1). The
   estimate is 100–300 ms saved off the main actor, once per pull that
   changed something, and the launch build stays full anyway. Below the
   threshold, `SWIFTUI-RULES` §3.2's warning against self-patching caches
   wins, and `update` stays `build` plus the fingerprint difference, which
   still feeds the summary and §3.6.

**Loads are serialized.** The launch load does not run inside `syncTask`, so
⌘R during it could start a second load, and the one that finished last would
win. `loadLibrary(reason:)` now waits for a running load, then runs. Each
load reads the revision (HEAD, or the snapshot marker) before its scan and
records it as `loadedRevision` only if it is the same after the build;
otherwise it records nil, so the next sync reloads.

**The job-related git calls move out of the load.** `repairWorktrees` and
`refreshOrphanedWorktrees` run at launch, after a fresh clone or Reset Clone,
and after each job, as audit §3.5 recommends. `refreshPushCapability` runs
after every sync outcome but `.failed`, reloading or not: the ingest sheet's
push blocker says "Sync again (⌘R) to configure it", and that must stay true.
It is 2–4 local `git config` calls. `discoverIngestionTools` and Re-check
already refresh it. Phase 0 makes this change (§4.1).

### 3.3 Detecting what changed: content fingerprints

`ContentFingerprints.scan(cloneRoot:)` reads every file `WikiIndex` would
list (the same glob and ignore rules, through `WikiIndex.contentFiles`), plus
`.reductions/relations.json` and `macros.ts`. It keeps a SHA-256 of each,
first 16 bytes in hex. `LibraryChanges.between(old, new)` is the difference:
added, modified and deleted content files, and whether the manifest or the
macros changed.

**Why not git's changed-file list** (Decision 11):

- **Cost.** Reading and hashing 1.40 MB from the page cache takes about
  10 ms, and the full build reads those bytes anyway. That is one
  `git diff`'s worth of time.
- **No base needed.** It needs no previous commit. A snapshot has no history,
  and a clone replaced by Reset Clone shares none with the old one.
- **Hand edits.** It sees a file changed in the clone by hand. Nothing should
  change one, but a full rebuild would pick it up, and the incremental build
  must match.
- **One path.** It is one code path for both stores, testable with temporary
  directories and no git.

A fixture test still checks that, between two commits of a fixture
repository, the fingerprint difference names exactly the files
`git diff --name-status --no-renames` names. The sync summary ("Wiki updated:
4 pages changed") then comes from `changes.changedPages` for both stores.
That drops a `git diff` per pull and gives snapshots a count too.

At launch there is no previous library in memory, so the in-memory build is
full and `LibraryUpdate.changes` is nil. Whenever previous fingerprints
exist, `changes` is their real difference, even when the build was full
(`isFullBuild`), so the summary keeps its page count. The search index and the modified dates have their own persisted state
and are incremental from the first load (§3.4, §3.7).

### 3.4 Each artifact, and what makes it stale

The rows from `WikiPage`s to `LinkPreviews` are D6's, built only under
§3.2's condition; until then each is rebuilt on every load.
`resolutionChanged` and `labelsChanged` are computed either way, for §3.6.

| Artifact | Depends on | Rebuilt | Otherwise |
|---|---|---|---|
| `WikiPage`s | the file's bytes | when its digest changed, or it is new | the previous page value, reused |
| The resolution tables: `allSlugs`, slug → path, alias owners, basenames, folders, ambiguous aliases | the file list and every page's aliases | always reassembled from the pages (cheap). `resolutionChanged` is true when a file was added or deleted or a changed page's aliases differ | |
| `backlinks` | every page body, and the resolution | in full when `resolutionChanged` | for each changed or deleted source, remove its old entries (found with the previous index), add each changed source's new ones, and keep every list sorted by source path, as the full sweep leaves it |
| `TextGrep` | each page's path, title, kind and body | the changed pages' entries | reused, then sorted by path as before |
| `RelationsManifest` | `relations.json` | when its digest changed | reused |
| `RelationLabels` | the manifest, and host pages' headings on old clones | always (cheap); `labelsChanged` compares it with the previous one | |
| `Derivation` | the manifest and the bundled curation | when the manifest changed | reused |
| `Derivation.unverifiedCitations` (relations-followups §6.2) | the text of the pages the curation cites, about 30 | always, in `build` and in `update`, also when the derivation itself is reused (cheap) | never carried over: a pull can edit a cited page and leave `relations.json` alone |
| `LinkPreviews` | a reduction or barrier card: the page, the manifest and the labels. Every other card: the page alone | the changed pages' cards; every reduction and barrier card when the manifest or the labels changed | reused |
| `MacroTable` | `macros.ts` | always, as today (cheap) | |
| The rankers (`ConceptRanker`, `ReferenceRanker`) | all pages, and the backlinks | always, inside the search actor, from pages sorted by path | |
| FTS rows | each page's bytes, and the code that builds a row | each row whose stored digest differs, plus inserts and deletes; in full when the `builder` stamp differs | untouched |
| Modified dates | git history | §3.7 | |

**The search index, in detail.** Schema version 3 adds `doc.hash` and a
`meta(key, value)` table holding `builder`: the app's `CFBundleVersion` and
the schema version. The version bump resets the index once, through the
existing `user_version` check. `sync(pages:backlinks:fingerprints:builder:)`
works like this:

1. A `builder` that differs means a full rebuild, as today: delete, insert
   all, `optimize`, checkpoint. Any change to how a row is built therefore
   rebuilds once, with no one having to remember a version bump.
2. Otherwise, one `SELECT path, hash FROM doc`, then in one transaction:
   delete the paths that are gone, `UPDATE` the rows whose hash differs (the
   existing `doc_au` trigger keeps FTS in step), and insert the new ones.
   `meta.builder` is written in the same transaction as the rows, in both
   cases, so a crash never leaves a stamp over rows it does not describe.
3. `optimize` runs only after more than 100 writes. FTS5's automerge handles
   the rest. The WAL is checkpointed only after writes.
4. The rankers are rebuilt from pages sorted by path. Today they take
   `index.allPages`, whose order is a dictionary's, which changes from one
   build to the next. Sorting makes their ties deterministic, so the full and
   the incremental build rank alike.
5. Every `ORDER BY bm25(…)` gains `, d.path` as its tie-break. Rows written
   incrementally get new rowids, and ties would otherwise fall back to rowid
   order.

### 3.5 The full build is the definition

`SWIFTUI-RULES` §3.2 says not to build caches that patch themselves, because
a rebuild from source is correct by construction. This design keeps the
rebuild as the definition and reuses only values whose inputs are provably
unchanged:

- **Reuse is keyed on content digests and on explicit dependency flags**
  (`resolutionChanged`, the manifest digest, `labelsChanged`). It never
  mirrors setters.
- **Each incremental step calls the same functions as the full build.** For
  example, `WikiIndex.build` becomes "load the pages, then `assemble`", and
  the incremental build reuses pages and calls the same `assemble`.
- **The fingerprint and the parse read the same bytes.** Today
  `WikiPage.load` reads with `String(contentsOf:encoding:)`. Track D adds
  `WikiPage.load(path:data:)`, which decodes with `String(data:encoding:
  .utf8)`, and the scan hashes and parses each file's one `Data`. So the two
  cannot disagree about a byte-order mark or a bad byte, and no file is read
  twice.
- **Tests prove equality** of every artifact after every kind of change, on
  fixtures and on the real corpus (§5), once D6 exists.
- **The full build runs** when:
  - there is no previous library (the launch);
  - the previous fingerprints are empty;
  - the search `builder` differs;
  - D6's update meets a case it does not handle, and calls `build`;
  - Settings ▸ Storage ▸ Rebuild is pressed (`AppModel.rebuildLibrary()`,
    §4.1, which also resets the search index);
  - `CCWIKI_FULL_RELOAD=1` is set, for diagnosis.

`LibraryUpdate.rebuilt` names what was rebuilt. It goes to the log, under
subsystem `com.axhoover.ccwiki` and category `library`, with the timings.

### 3.6 Open tabs after a pull

Today the one page on screen re-renders after every load, keeping its scroll.
With tabs that would be N renders. `LibraryUpdate.requiresRerender(of:)`
decides per tab, purely:

| Location | Re-render when |
|---|---|
| `.page(path)` | a full build; the page changed; `resolutionChanged`; the manifest or the labels changed; `macros.ts` changed; or a page it links to changed, since its preview card is in the rendered payload |
| `.folder(slug)` | a full build, `resolutionChanged`, the manifest changed (the listing leaves out its `unlistedPaths`), or any changed page under `slug` |
| `.document` | always: it is one synthetic page, and the first load must bring Welcome's links alive and drop its "The wiki is downloading" notice |
| `.empty` | never |

In a snapshot store a page also renders again when the load moved the
revision it was rendered at: a snapshot has no history, so a correction could
not read that revision's file (corrections §3.5). Every load also prunes each
tab's history as the first does (§1.7), and a tab whose page went shows the
nearest one left on Back, or Home (`SessionReloadPlan`).

The page tree, the counts and the quick switcher are rebuilt after every
load, as today. They are cheap.

### 3.7 Git, dates and the housekeeping

**Modified dates.** These are the per-file "last change" dates in the
reader's title bar.

- **One rule for both builds.** A file's date is the latest committer date
  among the non-merge commits that touch it under `content/`. Today's code
  takes the first sighting in `git log` order, which is the same in a linear
  history. Stating it as a maximum makes the incremental merge exact when a
  merged branch carries older dates.
- **A cache.** `index/modified-dates.json` holds `{revision, dates}`. It is
  derived and safe to delete, like the search index.
- **At launch.**
  - If the cache's revision is HEAD, use it.
  - If it is an ancestor (`git merge-base --is-ancestor`), run
    `git log --name-only --no-merges --format=%x00%ct <cached>..HEAD --
    content` and merge, taking the later date per file.
  - Otherwise, run the whole-history log once.
- **After a pull.** The same range merge over `before..after`.
- **A snapshot** has no history, so there are no dates, as today.

**`head`, `headDate`.** After a pull, `after` comes from the outcome, so only
`git log -1 --format=%ct` runs.

**Per pull**, then: the 4 processes of `sync`, plus `headDate` and the range
log, which makes 6, and push capability's 2–4 `git config` calls. When
nothing changed, 4 and those. The worktree housekeeping (§3.2) runs at
launch, after a clone or a reset, and after a job.

### 3.8 Measuring

D1 lands before any incremental code:

- **`LoadTimings`**: one `ContinuousClock` duration per phase of §3.1,
  logged once per load under category `library`.
- **`IncrementalCorpusTests`**, which runs in `make test-corpus` as the CI
  workflow already does. On the real wiki, it prints:
  - the full build, phase by phase;
  - the update after a one-page edit, an alias change and a manifest change;
  - the search sync in full, as a no-op, and after one page changed.
- **It never touches the clone it reads.** `make test-corpus` defaults to the
  release's own clone, and an edit there would make the next pull fail as
  diverged. The test copies `content/`, `.reductions/` and `macros.ts` from
  `CCWIKI_WIKI` to a temporary directory, edits only the copy, and asserts
  afterwards that `ContentFingerprints.scan` of `CCWIKI_WIKI` is unchanged.
  Its search sync uses a temporary SQLite file, never `paths.searchDatabase`.

The output lands in the CI log beside the relevance report, and its head
says which build it measured. CI's run is a debug build, so its numbers
stand beside §3.1's estimates as debug numbers and decide nothing. Only the
release-build run of §3.2, item 3, on a Mac, decides whether D6 is built. No
test fails on time, because shared runners are too noisy for that.

---

## 4. Tracks: who owns which file

One Phase 0 lands every seam the tracks share, then four tracks run in
parallel worktrees. After Phase 0, **no two tracks edit the same file**.

### 4.1 Phase 0: the seams

One PR, made by its own agent run on the base branch. It compiles, is green
on CI, and changes nothing a reader can see; the maintainer confirms on a Mac
that `make shots` is identical. The four tracks branch from its commit once
CI is green. It is not mechanical: it rebuilds `loadLibrary` and the sync
policy and moves `pageZoom`, so it gets the same review as a track.

| File | Change |
|---|---|
| `App/AppModel.swift` | `Location` and `Document` become `Hashable, Codable` (Codable must be synthesized in this file). `let webRoot` (from `stagedWebRoot()`, once). `var pageZoom` is persisted, clamped to `WebController.zoomRange`, applied in `didSet`, and the text-size methods set it. `let papers = PaperLibrary(paths:)`. `loadLibrary(reason:) async -> LibraryUpdate?` is rebuilt on the seams below and serialized (§3.2): `LoadedLibrary.update`, or `build` when nothing is loaded; then `apply`; then `LibraryRefresh.revisionFacts`, keeping `loadedRevision` only if `currentRevision` did not move; then `searchIndex.sync`; worktree housekeeping when `LibraryRefresh.runsJobHousekeeping(reason)`; then a private `libraryDidLoad(_:)` holding today's re-render tail. Add `@ObservationIgnored private var loaded: LoadedLibrary?`. `sync()` asks `LibraryRefresh.needsReload` and `await LibraryRefresh.summary`, and calls `refreshPushCapability()` after every outcome but `.failed`; the load no longer calls it. `rebuildLibrary()`, replacing `rebuildSearchIndex()`, drops `loaded`, resets the search index, then calls `loadLibrary(reason: .rebuild)`. `webController.onNavigate` takes a `LinkDisposition`, and anything but `.here` opens the site, as a modified click does today |
| `App/LoadedLibrary.swift` (new) | `LoadedLibrary`, moved out of `AppModel.swift` and given `fingerprints`. `build(cloneRoot:)` is today's detached body, with relations-followups' `unverifiedCitations` step if that has merged by then (§10). `update(_:cloneRoot:)` calls `build` and reports `changes: nil`, `isFullBuild: true`. Also `LibraryUpdate` (with `requiresRerender` always true) and `LibraryArtifact` |
| `Wiki/LibraryChanges.swift` (new) | `ContentFingerprints` (`.empty`; `scan` returns `.empty`) and `LibraryChanges` (`.none`; `between` returns `.none`) |
| `App/LibraryRefresh.swift` (new) | `LibraryLoadReason`, `RevisionFacts` and `LibraryRefresh` with today's behaviour: reload after every outcome but `.failed`, the summary by `git diff` (hence `summary` is `async` and takes the store, git and clone), the revision facts by today's calls, housekeeping on every load |
| `Search/SearchIndex.swift` | `sync(pages:backlinks:fingerprints:builder:)` calls `rebuild` and returns a `SyncReport` |
| `Reader/LinkDisposition.swift` (new) | the enum. `forClick` maps ⌘ or ⇧ to `.onSite` (today's "modified") and anything else to `.here`. Also `current` |
| `Reader/WebController.swift` | `onNavigate(destination, disposition)`, `sharedDataStore`, and `init(paths:webRoot:pageZoom:)`. `setPageZoom` applies without persisting, and the `pageZoom` property goes |
| `UI/WindowTabbing.swift` (new) | `WindowTabbing.join` as a no-op, `joinsInBackground = false`, and `WindowReader` |
| `App/AppPaths.swift` | `var papers: URL`, which is `library/papers` |
| `App/PaperLibrary.swift` (new) | `init(paths:)`; `show(_:)`, which does nothing; and `applyShot`, a no-op |
| `UI/PaperWindow.swift` (new) | `PaperWindowView(referencePath:)` as a placeholder `ContentUnavailableView`; `extension Theme { paperDefaultWidth … }`; `ShowPaperCommand`, with `isAvailable = false`; `PaperZoomAction` and `FocusedValues.paperZoom` |
| `UI/ShowPaperButton.swift` (new) | an `EmptyView` |
| `UI/ReaderView.swift` | `ShowPaperButton(page: page)` in `referenceBar`, after the Source link |
| `UI/RootView.swift` | `.task` calls `loadLibrary(reason: .launch)` and `ScreenshotRunner.run(model: model, openWindow: openWindow)` |
| `UI/SettingsView.swift` | Rebuild calls `model.rebuildLibrary()`. The "Working files" footer's first sentence becomes "The search index is derived and safe to delete at any time; Rebuild reads every page again and rebuilds it." |
| `App/CCwikiApp.swift` | The Paper `WindowGroup`, declared after the reader's, which stays the first scene because SwiftUI opens the first `WindowGroup` when nothing is restored (corrections' editor scene follows the same rule). Its content with `.environment(model)`, `.onAppear { appDelegate.model = model }` and `.handlesExternalEvents(matching: [])`, and `paperWindowID`. A `WindowReader` on the Jobs and explorer scenes' content sets `tabbingMode = .disallowed`. Wiki ▸ Show Paper (⌥⌘P), last in the page group after Copy Wikilink (corrections' group follows it behind a divider, §10), inside `if ShowPaperCommand.isAvailable`, so no dead item ships (`SWIFTUI-RULES` §7.4); Track C flips the constant, and the integration removed the gate once it was always true. The three zoom items read `@FocusedValue(\.paperZoom)` first: when it is present they are titled Zoom In, Zoom Out and Zoom to Fit and act on it. Actual Size reads `model.pageZoom` |
| `App/ScreenshotRunner.swift` | `run(model:openWindow:)`. The step `paper:<path>` calls `PaperLibrary.applyShot` |
| `scripts/shots.sh` | Launches the app with `-ApplePersistenceIgnoreState YES`, so the maintainer's own windows never enter a capture, and sets `CCWIKI_PAPER_FIXTURES` to `Tests/CCwikiTests/Fixtures/papers` unless it is set |

### 4.2 Track A: sessions and windows

- **Owns (new):**
  - `App/ReaderSession.swift`;
  - `App/ReaderSessionState.swift` (`ReaderSessionState`, `SessionStartPlan`);
  - `App/ReaderWindow.swift` (`ReaderWindow`, `ReaderWindowRequest`,
    `ReaderWindowRequests`, `SessionOrder`, `IngestSheetTarget`);
  - `UI/ReaderWindowView.swift`, `UI/OpenInReader.swift`, `UI/KeyHint.swift`;
  - the tests `ReaderSessionStateTests`, `SessionStartPlanTests`,
    `ReaderWindowRequestsTests`, `SessionOrderTests` and
    `IngestSheetTargetTests`.
- **Edits:**
  - `App/AppModel.swift`, after Phase 0;
  - `App/NavigationHistory.swift`, `App/CCwikiApp.swift`,
    `App/ScreenshotRunner.swift`;
  - `UI/RootView.swift`, `UI/ReaderView.swift` (not the Phase 0 line),
    `UI/SidebarView.swift`, `UI/InspectorView.swift`, `UI/JobsView.swift`
    (New Ingestion Job… and the toolbar's New Job call
    `requestIngestSheet(in: nil)`; corrections later renames both Ingest a
    Paper and keeps this action);
  - `UI/RelationsView.swift` and `UI/DerivedRelationsSections.swift`: reads of
    the current page, and the Open in New Tab and Open in New Window menu
    items;
  - `UI/QuickSwitcherView.swift`, `UI/SearchPalette.swift` (`open` gains a
    `LinkDisposition`), `UI/SearchView.swift`, `UI/GrepView.swift`,
    `UI/ReferenceSearchView.swift`;
  - `UI/RelationsExplorerView.swift`: only the two `openWindow` calls;
  - `Tests/CCwikiTests/NavigationHistoryTests.swift`;
  - the doc [design-system.md](design-system.md).
- **Consumes:** `LinkDisposition` and `WindowTabbing` (B), `LibraryUpdate`
  (D), `PaperZoomAction` (C, through Phase 0).
- **Steps:** A1–A6 (§1.10).

### 4.3 Track B: tab joining and link targets

- **Owns:** `Reader/LinkDisposition.swift`, `UI/WindowTabbing.swift`, and
  `Tests/CCwikiTests/LinkDispositionTests.swift`.
- **Edits:** `Reader/WebController.swift` (the `navigate` and `contextTarget`
  parsing, the `buttonNumber` fallback, `ReaderContextTarget.link` and
  `linkItems`, and `willOpenMenu`), `Resources/web/ccwiki.js` (`click`,
  `mousedown`, `mouseup` and `contextmenu`),
  `Tests/CCwikiTests/ReaderContextMenuTests.swift`, and
  [render-pipeline.md](render-pipeline.md) §4's ⌘-click sentence.
- **Steps:** B1–B3 (§1.10).

### 4.4 Track C: reference PDFs

- **Owns:**
  - `Papers/PaperSource.swift`, `Papers/PaperResponse.swift`,
    `Papers/PaperFetcher.swift`, `Papers/PaperStore.swift`;
  - `App/PaperLibrary.swift`;
  - `UI/PaperWindow.swift`, `UI/PDFKitView.swift`, `UI/ShowPaperButton.swift`;
  - `Tests/CCwikiTests/Fixtures/papers/022.pdf`: a generated one-page PDF
    that says it is a CCwiki test fixture, not a copy of the paper;
  - the tests `PaperSourceTests`, `PaperResponseTests`, `PaperFetcherTests`,
    `PaperStoreTests` and `PaperCorpusTests` (which runs when `CCWIKI_WIKI` is
    set).
- **Edits:** only `UI/SettingsView.swift`, the footer's PDF sentence (§2.5).
  `Papers/` is a new layer above `Jobs/`, since it uses
  `IngestSubmission.Source`, and below `Reader/`.
- **Steps:**
  - C1 `PaperSource`; C2 `PaperResponse`; C3 `PaperStore`;
  - C4 `PaperFetcher` and the streaming transport, with a fake transport;
  - C5 the `PaperLibrary` state machine, with `cancel`;
  - C6 the window (with its launch task and zoom), the button, the command
    (`ShowPaperCommand.isAvailable = true`, a gate the integration then
    removed), the fixture and the `paper:`
    shots.
- **Shots never touch the network or the real library.** Under
  `CCWIKI_SHOTS`, `PaperLibrary.init(paths:)` keeps papers in a fresh
  temporary directory, never `paths.papers`, and always uses the fixture
  transport. It serves `$CCWIKI_PAPER_FIXTURES/<last path component>` and
  fails as offline for anything else, or for everything when the variable is
  unset. So a fixture is never recorded in CCwiki Dev's library as the real
  paper from the real source.

### 4.5 Track D: incremental indexing

- **Owns:**
  - `App/LoadedLibrary.swift`, `App/LibraryRefresh.swift`,
    `Wiki/LibraryChanges.swift`;
  - the tests `LibraryChangesTests`, `IncrementalLibraryTests`,
    `SearchIndexSyncTests`, `ModifiedDatesTests`, `LibraryRefreshTests` and
    `IncrementalCorpusTests` (which runs when `CCWIKI_WIKI` is set).
- **Edits:**
  - `Wiki/WikiPage.swift`: `load(path:data:)`, used by the build and the
    scan alike (§3.5);
  - `Wiki/RelationLabels.swift`: `Equatable`, for `labelsChanged`;
  - `Search/SearchIndex.swift`: schema v3, `sync`, sorted rankers, the
    `d.path` tie-break;
  - `Jobs/GitService.swift`: `modifiedDates(fromLog:)` with the maximum rule,
    `modifiedDates(in:since:)`, `isAncestor`, all beside `modifiedDates(in:)`.
    Corrections adds a dozen methods to the same file after
    `updateSubmodules(in:onLine:)`, so the two never touch the same lines;
  - with D6 only: `Wiki/WikiIndex.swift` (`build` split into load and
    `assemble(contentRoot:files:pages:)`, whose signature corrections'
    `overlaying(_:)` shares (§4.6, §10), `build(contentRoot:reusing:changes:)`,
    `backlinks(updating:from:changes:)`), `Search/TextGrep.swift`
    (`updating(index:changes:)`), `Wiki/LinkPreview.swift` (an internal init
    and `cardsByPath`, with the incremental builder in a new
    `Wiki/LinkPreviews+Update.swift`), and the `Equatable` conformances of
    §4.6 that the equality tests need;
  - the doc [search.md](search.md) §3 (schema v3).
- **Does not edit `AppModel.swift`.** Every policy it needs is behind a
  `LibraryRefresh` or `LoadedLibrary` seam from Phase 0.
- **Steps:**
  - D1 measure (§3.8);
  - D2 fingerprints and changes, and `WikiPage.load(path:data:)`;
  - D3 `LoadedLibrary.update` as `build` plus the difference, the
    `resolutionChanged` and `labelsChanged` flags, and `requiresRerender`;
  - D4 the search index;
  - D5 `LibraryRefresh`: needs-reload, the summary from `changes`, dates,
    housekeeping;
  - D6, only if D1's numbers clear §3.2's threshold: reuse in `WikiIndex`,
    backlinks, grep and previews, with the equality tests.

### 4.6 The interfaces, exactly

Bodies and stored properties are elided where they do not matter to another
track. This is the surface the tracks compile against.

**Phase 0, shared by everyone:**

```swift
// App/AppModel.swift
enum Document: String, Hashable, Codable, Sendable { case welcome, whatsNew }
enum Location: Hashable, Codable, Sendable {
    case page(path: String, anchor: String?)
    case folder(slug: String)
    case document(Document)
    case empty
}
let webRoot: URL
var pageZoom: Double                 // persisted; applied to every reader's web view
let papers: PaperLibrary
@discardableResult
func loadLibrary(reason: LibraryLoadReason) async -> LibraryUpdate?   // serialized
func rebuildLibrary()                // Settings ▸ Storage ▸ Rebuild

// Reader/LinkDisposition.swift (Track B fills forClick)
enum LinkDisposition: Hashable, Sendable {
    case here
    case newTab(inBackground: Bool)
    case newWindow
    case onSite                          // the page on cryptology.city
    /// A click in the page, as Safari reads it (§1.4).
    static func forClick(command: Bool, shift: Bool, option: Bool,
                         middleButton: Bool) -> LinkDisposition
    /// The modifiers held now, for a SwiftUI button's action.
    @MainActor static var current: LinkDisposition { get }
}

// Reader/WebController.swift
@MainActor static let sharedDataStore: WKWebsiteDataStore
init(paths: AppPaths, webRoot: URL, pageZoom: Double)
var onNavigate: ((CCwikiURL.Destination, LinkDisposition) -> Void)?
func setPageZoom(_ zoom: Double)     // applies only; AppModel clamps and persists

// UI/WindowTabbing.swift (Track B fills join)
@MainActor enum WindowTabbing {
    /// False until the maintainer has checked background tabs on a Mac (§1.4).
    static let joinsInBackground: Bool
    /// Makes `window` a tab of `source`'s group, directly after `source`. In
    /// the background, `source` stays the selected tab and the key window.
    static func join(_ window: NSWindow, to source: NSWindow, inBackground: Bool)
}
/// Hands the view's `NSWindow` to `onWindow` once the view is in one.
struct WindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void
}

// UI/PaperWindow.swift (Track C sets it from the paper window)
struct PaperZoomAction: Sendable {
    let zoomIn: @MainActor @Sendable () -> Void
    let zoomOut: @MainActor @Sendable () -> Void
    let zoomToFit: @MainActor @Sendable () -> Void    // autoScales back on
}
extension FocusedValues { var paperZoom: PaperZoomAction? { get set } }
enum ShowPaperCommand {
    @MainActor static func isEnabled(for page: WikiPage?) -> Bool
    @MainActor static func perform(_ page: WikiPage, model: AppModel,
                                   openWindow: OpenWindowAction)
}
```

**Track A:**

```swift
// App/ReaderWindow.swift
struct ReaderWindow: Codable, Hashable, Sendable {
    var id = UUID()
    /// Where an Open in New Tab or New Window starts. Ignored when the
    /// window has restored state (§1.7).
    var opening: AppModel.Location? = nil
    /// Found on the page once `opening` renders: a search hit opened in a new
    /// tab still lands on its match.
    var find: [String]? = nil
}

struct ReaderWindowRequest: Equatable, Sendable {
    var window: ReaderWindow
    /// `NSWindow.windowNumber` of the reader to join as a tab; nil, a window.
    var tabbingInto: Int?
    var inBackground: Bool
}

/// The tabbing of windows the caller is opening itself. Pure.
struct ReaderWindowRequests: Equatable, Sendable {
    mutating func expect(_ request: ReaderWindowRequest)
    /// Consumed once, by the window the request names.
    mutating func takeTabbing(for windowID: UUID) -> ReaderWindowRequest?
}

/// The reader windows, most recently key first. Pure.
struct SessionOrder<ID: Hashable & Sendable>: Equatable, Sendable {
    mutating func opened(_ id: ID)       // least recent until it becomes key
    mutating func becameKey(_ id: ID)
    mutating func closed(_ id: ID)
    var mostRecent: ID? { get }
    var count: Int { get }
}

/// Which window shows the ingest sheet. Pure; a key change never moves it.
struct IngestSheetTarget: Equatable, Sendable {
    private(set) var window: UUID?
    private(set) var isWaiting: Bool     // asked for with no reader open
    /// Pins to `window`, else `active`, else waits. No-op while one is shown.
    mutating func request(in window: UUID?, active: UUID?)
    /// A new session claims a waiting request; true once.
    mutating func claim(by session: UUID) -> Bool
    mutating func dismiss()
    mutating func windowClosed(_ id: UUID)
}

// App/ReaderSessionState.swift
struct ReaderSessionState: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    var history: NavigationHistory
    var inspectorTab: String             // AppModel.InspectorTab.rawValue
    var showsInspector: Bool
    var expandedFolders: [String]        // sorted
    func encoded() -> Data?
    /// nil for nil, for bytes that do not decode, and for another version.
    static func decoded(from data: Data?) -> ReaderSessionState?
}

/// How a session starts (§1.7). Pure.
struct SessionStartPlan: Equatable, Sendable {
    var history: NavigationHistory       // restored, else empty
    var showsAtOnce: AppModel.Location?  // the launch document
    var opensOnLoad: AppModel.Location?  // opening, pending, or the cold start's last page
    var find: [String]?
    var opensHomeOnLoad: Bool
    static func plan(restored: ReaderSessionState?, window: ReaderWindow,
                     pending: AppModel.Location?, launchDocument: AppModel.Document?,
                     isColdStart: Bool, lastPage: String?) -> SessionStartPlan
}

// App/NavigationHistory.swift
struct NavigationHistory: Equatable, Sendable, Codable {
    /// A saved history; `capacity` applies to Back and Forward, on decode too.
    init(current: Location, back: [Location], forward: [Location])
    /// Without the entries `keep` rejects. A rejected current becomes the
    /// nearest kept Back entry, else `.empty`; adjacent duplicates collapse.
    func pruned(keeping keep: (Location) -> Bool) -> NavigationHistory
}

// App/ReaderSession.swift
@MainActor @Observable
final class ReaderSession: Identifiable {
    typealias Location = AppModel.Location
    let id: UUID
    unowned let model: AppModel
    let webController: WebController
    private(set) var history: NavigationHistory
    var location: Location { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var sidebarSelection: String?
    var expandedFolders: Set<String>                 // written to CCwikiSettings
    var inspectorTab: AppModel.InspectorTab          // the same
    var showInspector: Bool                          // the same
    var quickSwitcherPresented = false
    var searchPresented = false
    var referenceSearchPresented = false
    var grepPresented = false
    var syncLogPresented = false
    @ObservationIgnored var windowNumber: Int?
    @ObservationIgnored var openInReader: OpenInReaderAction   // set by its view

    init(id: UUID, model: AppModel)
    /// Idempotent: a second call does nothing.
    func start(_ plan: SessionStartPlan, readingAnchor: String?)
    func libraryDidLoad(_ update: LibraryUpdate)
    func preferencesDidChange()
    var restorationState: ReaderSessionState { get }
    func handleOpenURL(_ url: URL)                   // ccwiki:// or a PDF

    func open(_ location: Location, recordHistory: Bool = true)
    func open(_ location: Location, _ disposition: LinkDisposition, find: [String]? = nil)
    func openPage(_ path: String, anchor: String? = nil)
    func navigate(to destination: CCwikiURL.Destination,
                  disposition: LinkDisposition = .here)
    func goBack()
    func goForward()
    func openHome()
    func openRandomPage()
    func showWelcome()
    func showWhatsNew()
    func openSearchResult(_ hit: SearchHit, query: String,
                          disposition: LinkDisposition = .here)
    func openGrepResult(_ hit: TextGrep.Hit, query: String,
                        disposition: LinkDisposition = .here)
    func openReferenceResult(_ hit: ReferenceHit, query: String,
                             disposition: LinkDisposition = .here)
    func openRelationObject(_ objectID: String, disposition: LinkDisposition = .here)
    func showInspectorTab(_ tab: AppModel.InspectorTab)
    func presentQuickSwitcher()
    func printCurrentPage()

    var currentPage: WikiPage? { get }
    var currentBacklinks: [WikiIndex.Backlink] { get }
    var currentRelations: PageRelations { get }
    var currentDerivations: PageDerivations { get }
    var citingPages: [WikiIndex.Backlink] { get }
    var currentSiteURL: URL? { get }
    var currentTitle: String { get }
    var currentPageExplorerQuery: ExplorerQuery? { get }
    var canExploreCurrentPage: Bool { get }
}

// App/AppModel.swift, after Track A: the reader-facing surface
/// The session for `id`, created once. nil when the id is live in another
/// window or was closed in this process; the caller takes a fresh UUID.
func claimSession(for id: UUID, windowNumber: Int) -> ReaderSession?
func sessionBecameKey(_ id: UUID)
func sessionDidClose(_ id: UUID)                     // on willCloseNotification
var activeSession: ReaderSession? { get }            // SessionOrder.mostRecent; observed
private(set) var mainWindowCount: Int                // live sessions
func expectReaderWindow(_ request: ReaderWindowRequest)
func takeTabbing(for windowID: UUID) -> ReaderWindowRequest?
func launchIfNeeded() async
func takeLaunchDocument() -> Document?
func takeColdStart() -> Bool                         // once per process, and after the last reader closes
func takePendingReaderLocation() -> Location?
func noteVisited(_ path: String)                     // recents and lastPage
func documentRequest(_ document: Document) -> RenderRequest
var quickSwitcherExcludedPath: String?
func refreshQuickSwitcher()
var ingestSheetTarget: UUID? { get }                 // IngestSheetTarget.window
var pendingDroppedPDF: URL?
func requestIngestSheet(in session: UUID?)
func dismissIngestSheet()
// For windows that are not readers (§1.8)
func open(_ location: Location)
func openPage(_ path: String, anchor: String? = nil)
func openRelationObject(_ objectID: String)
func navigate(to destination: CCwikiURL.Destination)
/// Opens `location` in a reader and brings that window forward; false
/// when no reader is open.
func revealInReader(_ location: Location) -> Bool
var currentPageExplorerQuery: ExplorerQuery? { get }
var canExploreCurrentPage: Bool { get }

// UI/OpenInReader.swift
struct OpenInReaderAction: Sendable {
    static let none = OpenInReaderAction { _, _, _ in }
    let handler: @MainActor @Sendable (AppModel.Location, LinkDisposition, [String]?) -> Void
    @MainActor func callAsFunction(_ location: AppModel.Location,
                                   _ disposition: LinkDisposition,
                                   find: [String]? = nil)
}
extension FocusedValues { var readerSession: ReaderSession? { get set } }

// UI/KeyHint.swift: the keycap from QuickSwitcherView, shared with SearchPalette
struct KeyHint: View { let key: String; let label: String }

// UI/ReaderWindowView.swift
struct ReaderWindowView: View { @Binding var window: ReaderWindow }
```

**Track C:**

```swift
// Papers/PaperSource.swift
struct PaperSource: Equatable, Sendable {
    enum Kind: String, Sendable { case eprint, arXiv, eccc, pdf, landingPage }
    struct Candidate: Equatable, Sendable { let url: URL; let kind: Kind }
    let referencePath: String
    let key: String                      // the citation key
    let sourceURL: URL?                  // `source:` as written
    let candidates: [Candidate]          // best first; https; empty: nothing to fetch
    let fileName: String                 // "BGI15.pdf", before PaperStore's uniquing
    init(page: WikiPage)
    static func candidates(for link: String) -> [Candidate]
}

// Papers/PaperResponse.swift
enum PaperResponse: Equatable, Sendable {
    case pdf
    case html(pdfLink: URL?)
    case other(contentType: String?)
    static func classify(prefix: Data, contentType: String?, finalURL: URL,
                         html: () -> String?) -> PaperResponse
    static func citationPDFURL(inHTML html: String, baseURL: URL) -> URL?
}

// Papers/PaperFetcher.swift
enum PaperFailure: Error, Equatable, Sendable {
    case noLink(source: URL?)
    case offline
    case notAPDF(landingPage: URL, redirectedFrom: URL?)
    case refused(status: Int, host: String, page: URL)
    case notFound(url: URL)
    case busy(host: String, status: Int)
    case unreachable(host: String, url: URL)
    case tooLarge(bytes: Int64, host: String, url: URL)
    case unreadable(host: String)
    case unexpected(host: String, detail: String, url: URL)
    var title: String { get }            // §2.7
    var message: String { get }
    var systemImage: String { get }
    /// The URL an "Open on <host>" button opens, if the state has one.
    var openURL: URL? { get }
    static func mostUseful(_ failures: [PaperFailure]) -> PaperFailure?
}
struct PaperDownload: Sendable {
    let response: HTTPURLResponse
    let file: URL?                       // nil when over the cap; nothing kept
    let bytes: Int64                     // received, or the declared length
}
protocol PaperTransport: Sendable {
    /// Streams `url` to a temporary file, stopping at `maximumBytes`.
    /// Throws `URLError` when the request fails.
    func download(_ url: URL, maximumBytes: Int64,
                  progress: @escaping @Sendable (_ received: Int64, _ expected: Int64?) -> Void)
        async throws -> PaperDownload
}
struct URLSessionPaperTransport: PaperTransport { init() }
struct FetchedPaper: Sendable { let file: URL; let from: URL }
struct PaperFetcher: Sendable {
    init(transport: PaperTransport, maximumBytes: Int64 = 100 << 20)
    func fetch(_ source: PaperSource,
               progress: @escaping @Sendable (Int64, Int64?, URL) -> Void)   // the request's URL
        async -> Result<FetchedPaper, PaperFailure>
}

// Papers/PaperStore.swift
struct PaperRecord: Codable, Equatable, Sendable {
    enum Origin: Codable, Equatable, Sendable { case downloaded(from: URL), addedByYou }
    let referencePath: String
    let fileName: String
    let origin: Origin
    let addedAt: Date
    let bytes: Int64
}
struct PaperStore: Sendable {
    let directory: URL                   // AppPaths.papers, or a temporary one for shots
    func record(for referencePath: String) -> PaperRecord?   // nil when the file is gone
    func fileURL(for record: PaperRecord) -> URL
    /// Names the file uniquely, case-insensitively (§2.3); replaces only
    /// this reference's own file.
    func keep(_ file: URL, for source: PaperSource,
              origin: PaperRecord.Origin) throws -> PaperRecord
    func remove(_ referencePath: String) throws          // to the Trash
}

// App/PaperLibrary.swift (Phase 0 declares init(paths:), show, applyShot)
@MainActor @Observable
final class PaperLibrary {
    enum State: Equatable {
        case notDownloaded
        case downloading(host: String, received: Int64, expected: Int64?)
        case ready(PaperRecord, file: URL)
        case failed(PaperFailure)
    }
    init(paths: AppPaths)                // the fixture transport and a temporary store under shots
    init(store: PaperStore, transport: PaperTransport)
    func state(for referencePath: String) -> State
    func show(_ page: WikiPage)          // fetch unless ready or downloading
    func retry(_ page: WikiPage)
    func cancel(_ referencePath: String) // back to .notDownloaded
    func adopt(_ pdf: URL, for page: WikiPage) throws
    func remove(_ referencePath: String) throws      // the window shows why it failed
    static func applyShot(_ referencePath: String, model: AppModel,
                          openWindow: OpenWindowAction) async
}

// UI/PaperWindow.swift, UI/ShowPaperButton.swift, UI/PDFKitView.swift
struct PaperWindowView: View { let referencePath: String? }
struct ShowPaperButton: View { let page: WikiPage }
struct PDFKitView: NSViewRepresentable {
    let url: URL
    let onPageChange: @MainActor (_ index: Int, _ count: Int) -> Void
    let onZoom: @MainActor (PaperZoomAction) -> Void   // hands its actions up
}
```

**Track D:**

```swift
// Wiki/LibraryChanges.swift
struct ContentFingerprints: Equatable, Sendable {
    static let empty: ContentFingerprints
    let pages: [String: String]          // content-relative path → digest, every listed file
    let manifest: String?                // .reductions/relations.json
    let macros: String?                  // macros.ts
    static func scan(cloneRoot: URL) -> ContentFingerprints
    static func digest(_ data: Data) -> String
}
struct LibraryChanges: Equatable, Sendable {
    var added: Set<String>               // content-relative
    var modified: Set<String>
    var deleted: Set<String>
    var manifestChanged: Bool
    var macrosChanged: Bool
    static let none: LibraryChanges
    static func between(_ old: ContentFingerprints,
                        _ new: ContentFingerprints) -> LibraryChanges
    var isEmpty: Bool { get }
    var changedPages: Set<String> { get } // the .md paths among the three sets
}

// Wiki/WikiPage.swift
static func load(path: String, data: Data) -> WikiPage?   // UTF-8; both builds use it

// App/LoadedLibrary.swift
struct LoadedLibrary: Sendable {
    let index: WikiIndex
    let backlinks: [String: [WikiIndex.Backlink]]
    let manifest: RelationsManifest
    let labels: RelationLabels
    let textGrep: TextGrep
    let derivation: Derivation
    let linkPreviews: LinkPreviews
    let fingerprints: ContentFingerprints
    /// The definition: everything from the files.
    static func build(cloneRoot: URL) -> LoadedLibrary
    /// Equal to `build`; before D6 it is `build` plus the difference.
    static func update(_ previous: LoadedLibrary, cloneRoot: URL) -> LibraryUpdate
}
struct LibraryUpdate: Sendable {
    let library: LoadedLibrary
    /// The fingerprint difference; nil only when there was no previous library.
    let changes: LibraryChanges?
    let isFullBuild: Bool
    let rebuilt: Set<LibraryArtifact>
    let resolutionChanged: Bool
    let labelsChanged: Bool
    func requiresRerender(of location: AppModel.Location) -> Bool   // §3.6
}
enum LibraryArtifact: String, Hashable, Sendable, CaseIterable {
    case pages, resolution, backlinks, grep, manifest, labels, derivation, previews
}

// App/LibraryRefresh.swift
enum LibraryLoadReason: Equatable, Sendable {
    case launch, pulled, cloned, reset, offline, rebuild
}
struct RevisionFacts: Equatable, Sendable {
    var head: String?
    var date: Date?
    var modifiedDates: [String: Date]
}
enum LibraryRefresh {
    static func needsReload(after outcome: GitService.SyncOutcome,
                            loadedRevision: String?, isLoaded: Bool) -> Bool
    static func summary(after outcome: GitService.SyncOutcome, changes: LibraryChanges?,
                        store: AppPaths.WikiStore, git: GitService?, clone: URL) async -> String
    /// HEAD, or the snapshot marker's sha; read before and after a load's scan.
    static func currentRevision(store: AppPaths.WikiStore, git: GitService?,
                                clone: URL) async -> String?
    static func revisionFacts(store: AppPaths.WikiStore, git: GitService?, paths: AppPaths,
                              after outcome: GitService.SyncOutcome?) async -> RevisionFacts
    static func runsJobHousekeeping(_ reason: LibraryLoadReason) -> Bool
}

// Search/SearchIndex.swift
struct SyncReport: Equatable, Sendable {
    var inserted = 0, updated = 0, deleted = 0, unchanged = 0
    var rebuiltFromScratch = false
}
static let schemaVersion = 3
@discardableResult
func sync(pages: [WikiPage], backlinks: [String: [WikiIndex.Backlink]],
          fingerprints: ContentFingerprints, builder: String) throws -> SyncReport

// Jobs/GitService.swift
static func modifiedDates(fromLog output: String) -> [String: Date]  // the latest date wins
func modifiedDates(in clone: URL, since base: String) async -> [String: Date]?
func isAncestor(_ base: String, of head: String, in clone: URL) async -> Bool

// Wiki/RelationLabels.swift (D3, for labelsChanged)
extension RelationLabels: Equatable {}

// D6 only. Corrections' Track D needs the same split for
// WikiIndex.overlaying(_:) and defines it with this exact signature if D6 is
// not built; whichever lands second deletes its copy (§10).
extension WikiIndex {
    /// The second half of `build`: every table, from the sorted file list
    /// (`contentFiles(root:)`, assets included) and the markdown pages that
    /// parsed. `build` is `contentFiles`, a `WikiPage` load per `.md` file,
    /// then this.
    static func assemble(contentRoot: URL, files: [String],
                         pages: [String: WikiPage]) -> WikiIndex
}

// D6 only, for the equality tests
extension WikiPage: Equatable {}
extension WikiIndex: Equatable {}        // includes the private resolution tables
extension TextGrep: Equatable {}
extension LinkPreviews { var cardsByPath: [String: LinkPreview] { get } }
```

### 4.7 Merge order, gates, and the other features in flight

1. **Phase 0**, its own agent run, green on CI before anything branches
   from it.
2. **A, B, C and D in parallel**, each against Phase 0's seams.
   - B and A meet only through `LinkDisposition` and `WindowTabbing`. Until B
     lands, a new tab opens as a window, which is acceptable in between.
   - C and D touch no file A touches.
3. **Integration order: A, then B, C and D in any order.** A changes the most
   lines; the others merge onto it cleanly by construction.
4. **The integrator** writes the `PROGRESS.md` entry, the `PLAN.md` index
   line, the `CHANGELOG.md` notes and the measured numbers in §3.1, and every
   [architecture.md](architecture.md) change: §1 gains `Papers/`, §2 becomes
   "One library, one session per window", and §3's diagram gains the session
   and the fingerprints. Tracks describe their part in their PR descriptions
   and do not edit `PROGRESS.md` or architecture.md.

**Gates.** The agents have no Mac and no Swift, so the gate they can meet is
CI: every step is one commit pushed to the track's draft PR, and must be
green (`make check` and `make test-corpus`). `make shots` (identical for
Phase 0 and A1–A4a) and §5's by-eye list are the maintainer's checklist, run
on a Mac before a PR leaves draft. Until then `WindowTabbing.joinsInBackground`
stays false. Every PR is a draft, and **no one merges to `main`**.

**Other features being built alongside this one**
([relations-followups.md](relations-followups.md), then
[corrections.md](corrections.md)) also edit `AppModel.swift`,
`CCwikiApp.swift`, `RootView.swift`, `WebController.swift`, `ccwiki.js` and a
few views. **This feature merges to `main` second, after relations-followups
and before corrections.** §10 says why, and lists every seam.

- **Track A's A2 and A3 are the big mechanical change.** They move the
  per-page members out of `AppModel` and turn `model.X` into `session.X` in
  about fifteen views. A view written against `model.currentPage`
  afterwards is a one-word fix.
- **Any new per-page state belongs in `ReaderSession`.** A feature that adds
  state to the page being read (a "report a problem" target, a selection)
  should put it there, not in `AppModel`. A feature that opens pages from a
  non-reader window should use §1.8's API. Corrections does both when it
  rebases (corrections §17).

---

## 5. Tests and the visual gate

Unit tests use swift-testing, as the suite does, and none needs a window or a
web view: every decision lives in a pure type. Session behaviour that needs a
`WKWebView` is checked by the visual gate and the by-eye list. Tests that
make git commits run in a temporary directory with `GIT_CONFIG_GLOBAL=/dev/null`,
`GIT_CONFIG_NOSYSTEM=1` and `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`,
`GIT_COMMITTER_NAME` and `GIT_COMMITTER_EMAIL` set, since CI has no git
identity and a maintainer's global config may sign or hook; they skip when
git is absent.

| Behaviour | Proved by |
|---|---|
| A tab's Back and Forward survive encode and decode, with `capacity` enforced on decode | `NavigationHistoryTests`: `codableRoundTrip`, `decodeAppliesCapacity` |
| A restored history drops pages the wiki lost; a lost current falls back to Back, else `.empty`; adjacent duplicates collapse | `NavigationHistoryTests.pruned…` |
| Garbage, nil or a future version of saved state is ignored, never half-applied | `ReaderSessionStateTests` |
| A cold launch opens the last page; ⌘N, ⌘T and the + button open Home; a restored window keeps its history and ignores its value's opening; the launch document shows at once with the restored page behind it; a pending location opens; the cold start is used once | `SessionStartPlanTests` |
| The explorer's pages go to the most recently key reader; closing it moves them to the next; with none, nil | `SessionOrderTests` |
| A tabbing request is consumed once, by the window it names | `ReaderWindowRequestsTests` |
| The ingest sheet stays on its window when another reader becomes key; a waiting request is claimed once; a request while one is shown changes nothing; closing its window clears it | `IngestSheetTargetTests` |
| ⌘, ⇧⌘, ⌥⌘, ⇧ and ⌥ alone, and the middle button, mean what §1.4 says | `LinkDispositionTests` |
| Link items appear only for internal links, after "Open Link"; never for an external link or a formula | `ReaderContextMenuTests` |
| Candidates for ePrint, ePrint `.pdf`, arXiv old and new ids, ECCC, direct PDF, DOI and dblp; BibTeX `eprint` after `source`; `http` made `https`; no duplicates; safe file names (`FGJ+25`) | `PaperSourceTests` |
| On the real wiki, invariants only: every `source` that parses as ePrint, arXiv or ECCC yields that full-text candidate first; every candidate is https; file names are unique case-insensitively. The kind counts are printed, with no thresholds, since the wiki's HEAD moves | `PaperCorpusTests` |
| `%PDF-` is a PDF; HTML with `citation_pdf_url` in either attribute order, relative or absolute, gives the link; `javascript:` and `data:` links are refused; PostScript is `other` | `PaperResponseTests` |
| ePrint succeeds; DOI → HTML → `citation_pdf_url` → PDF succeeds; HTML without one is `notAPDF` naming both hosts; 403 is `refused`; 500 and a PostScript body are `unexpected`; `.notConnectedToInternet` stops at once; `.cannotFindHost` on the first candidate then success on the second succeeds; a declared or streamed body over the cap is `tooLarge` and keeps nothing; an unreadable file is rejected; the most useful failure is shown | `PaperFetcherTests` (fake transport) |
| Kept once; the index round-trips; a missing file means not downloaded; adopt replaces; remove moves the file to the Trash and drops the record; keys `SW25` and `sw25`, one added by you, end up as two files and neither is replaced | `PaperStoreTests` (temporary directory) |
| Failure text names the host and never says "error" alone | `PaperFetcherTests.messages` |
| The fingerprint difference is right for added, modified and deleted files, the manifest and the macros; Templates and hidden files are ignored | `LibraryChangesTests` |
| …and equals `git diff --name-status --no-renames` between two commits | `LibraryChangesTests.matchesGit` (fixture repository) |
| `changes`, `isFullBuild`, `resolutionChanged` and `labelsChanged` are right for each kind of change: a body edit, an alias change, an added page, a deleted page, an added asset, a manifest change, a macros change, and several at once | `IncrementalLibraryTests` (fixture wiki) |
| `requiresRerender` follows §3.6: a page whose link target changed; a folder after an `unlistedPaths` change (`rerenderFolderOnUnlistedChange`); Welcome after the first load (`rerenderDocumentAfterFirstLoad`) | `IncrementalLibraryTests.rerender…` |
| With D6: `update` equals `build` for each change above, comparing pages, `WikiIndex`, backlinks, `TextGrep` and `LinkPreviews.cardsByPath`; `rebuilt` is minimal | `IncrementalLibraryTests.updateEqualsBuild…`, `.rebuiltSets` |
| With D6, on a temporary copy of the real wiki: 20 seeded edits (5 deletions, 10 body edits, 3 added pages with aliases, 1 alias change, 1 manifest edit) leave `update` equal to `build`, and `CCWIKI_WIKI` is unchanged afterwards | `IncrementalCorpusTests` |
| Syncing the search index from A to B equals a fresh build of B: the same rows keyed by path, and the same hits, snippets and scores (within 1e-9) for a fixed set of queries | `SearchIndexSyncTests` (temporary database) |
| An unchanged sync writes nothing; a changed `builder` rebuilds; a v2 database resets | `SearchIndexSyncTests` |
| Merged modified dates equal the whole-history log, including a merged branch with older commit dates | `ModifiedDatesTests` (fixture repository, `GIT_COMMITTER_DATE`) |
| `needsReload` per outcome, loaded revision (including nil) and loaded state; `summary` per outcome and store | `LibraryRefreshTests` |

**The visual gate**, run by the maintainer (§4.7). New `make shots` steps: A
adds `window:`, `tab:` and `bgtab:` in A4b and A5, and C6 adds `paper:`. The
paper shots read `Tests/CCwikiTests/Fixtures/papers/022.pdf` through the
fixture transport, and keep it in a temporary library.

| Step | Shows |
|---|---|
| `page:Primitives/pseudorandom-function.md,tab:Assumptions/learning-with-errors.md` | the tab bar, the new tab in front, its own inspector |
| `page:Primitives/pseudorandom-function.md,bgtab:Assumptions/learning-with-errors.md` | the first tab still selected, the second in the bar (once `joinsInBackground` is on) |
| `window:Primitives/one-way-function.md` | a second window with its own sidebar selection |
| `paper:References/AABN02 - From Identification to Signatures via the Fiat-Shamir Transform Minimizing Assumptions for Security and Forward-Security.md` | the paper window, from the fixture PDF |
| `paper:References/BGI15 - Function Secret Sharing.md` | Offline under the fixture transport |
| each of the above, then `dark` | dark mode |

**Things to check by eye**, on a Mac, because no test can:

- **Tabs.**
  - ⌘T and ⌘-click never flash a separate window before the tab appears.
  - The tab bar's + button, if macOS shows one, opens Home.
  - Switching tabs, minimising, and Move Tab to New Window keep each tab's
    history and do not re-render its page.
  - **Background tabs, in a local build.** While `joinsInBackground` is
    false, every tab opens in front and ⌘Return closes the palette, so
    neither check below can be seen. Set
    `WindowTabbing.joinsInBackground = true` (UI/WindowTabbing.swift). That
    turns on background placement for ⌘-click, middle-click, Open in New
    Tab and ⌘Return, keeps a palette open after ⌘Return (`keepsPaletteOpen`),
    and makes `bgtab:` differ from `tab:`. Then check that:
    - a background tab leaves the current tab selected and key;
    - ⌘Return in a palette adds a tab while the palette's sheet stays up (if
      not, make `keepsPaletteOpen` false, §1.4).

    Commit the flip only if both pass.
- **Sidebar.** ⌘-click on a Cited by, backlink or relation row opens a
  background tab; the tree's rows offer Open in New Tab and Open in New
  Window from their context menu.
- **Restoration and routing.**
  - With "Close windows when quitting an application" off, and with Quit and
    Keep Windows (⌥⌘Q) when it is on, relaunch brings back every window and
    tab, each on its page and heading, with Back and Forward intact.
  - `open 'ccwiki-dev://…'` with two reader windows and a paper window open
    navigates the reader window SwiftUI brings forward, and opens no new
    window. With CCwiki not running, the link lands once the wiki loads.
  - The explorer stays key when it opens a page, and the page appears in the
    last reader window used.
  - The ingest sheet appears on one window, and stays there with its text
    and PDF when another reader window is clicked.
- **Per window.**
  - ⌘F's bar and its matches stay with their tab.
  - Text size changes every tab.
- **Papers.**
  - The paper window opens at the trailing edge, no taller than the screen,
    and tiles beside the reader (on macOS 15, Window ▸ Move & Resize ▸ Left
    & Right).
  - A paper window restored alone loads the wiki and its paper.
  - ⌘+ and ⌘− zoom the PDF, ⌘0 fits it again, and Space scrolls at once.
  - The PDF stays white in dark mode.
  - A drop on the window replaces a failure state with the PDF.
  - Show Reference Page brings a reader forward, opening one if none is.

---

## 6. Risks

- **SwiftUI and AppKit window behaviour is unproven here.** No Mac was
  available. Each of the following has a fallback, and §5's by-eye list
  checks each:
  - the timing of `addTabbedWindow` relative to SwiftUI showing the window;
  - whether AppKit restores tab groups of SwiftUI windows;
  - whether `@SceneStorage` behaves in `WindowGroup(for:)` as in a plain
    `WindowGroup`;
  - whether `handlesExternalEvents` stops a new window per `ccwiki://` link;
  - whether `openWindow(id:)` without a value uses `defaultValue`;
  - whether SwiftUI calls `onDisappear` for a deselected or minimised tab
    (the session's life no longer depends on it, §1.3);
  - whether AppKit honours an explicit `tabbingIdentifier` on a SwiftUI
    window, so a reader never joins a paper's group under "Prefer tabs:
    Always";
  - whether AppKit adds a tab to a window that has a sheet attached;
  - whether WebKit delivers the middle button to the page's script; the
    fallback is `WKNavigationAction.buttonNumber`.
- **Memory grows with tabs.** Each tab is a WebContent process. A reader who
  keeps thirty tabs open will see it in Activity Monitor. The shared data
  store keeps the network process single. Unloading background tabs is
  listed in §7, not built.
- **The refactor collides with the features in flight** (§10). The
  forwarders of A2 could also hide a view that reads the active session when
  it should read its own; A3's grep gate is there to catch that.
- **Incremental results could drift from the full build.** Against that: the
  full build is the definition, equality is tested on fixtures and on the
  real corpus in CI once D6 exists, the `builder` stamp rebuilds the search
  index after any app update, and Settings ▸ Storage ▸ Rebuild and
  `CCWIKI_FULL_RELOAD=1` remain.
- **Dictionary order made the rankers' ties nondeterministic.** The search
  index now builds them from sorted pages, and bm25 ties now break by path
  (§3.4). A relevance test that passed before by luck might now fail for a
  real reason, and should be read rather than loosened.
- **Publishers.** Many refuse apps (403), send a bot-check page as HTML, or
  rate-limit (429). A landing page's `citation_pdf_url` often leads to a
  login. All of these end in a state that says so and offers the browser
  route. arXiv asks automated clients to identify themselves; CCwiki does,
  and fetches one file per click.
- **Third-party PDFs are parsed by PDFKit** in an app that is not
  sandboxed. A malformed PDF from a publisher is now opened in-process, as
  it would be in Preview, but without Preview's sandbox. The 100 MB cap and
  the `CGPDFDocument` check bound it; they do not make it safe.
- **The wrong paper.** A reference whose link is wrong yields the wrong PDF.
  The window names where it came from, and Choose Another PDF… replaces it.
- **Copyright.** CCwiki fetches only what a site serves without credentials,
  keeps it on this Mac, never in the repo, and never uploads it.
- **Disk.** Papers accumulate with no eviction. A hundred papers are a few
  hundred megabytes, and Finder is the way to clear them.
- **Launch order.** `launchIfNeeded` must keep the installation check before
  the launch sync, as update-integrity §2.3 requires. A test cannot see this,
  so it is a review item.

---

## 7. Not done, on purpose

- **Reopen Closed Tab.** It is cheap later: `AppModel` keeps the last ten
  closed sessions' `ReaderSessionState`, and Edit ▸ Undo Close Tab (⌘Z)
  opens one in a new tab, as in Safari. Not ⇧⌘T, which AppKit gives to Show
  Tab Bar.
- **Keeping tabs across a relaunch CCwiki starts itself** (an update, Replace
  and Relaunch). It would mean saving every window's state before
  `NSApp.terminate` and restoring it against the system setting.
- **Selecting tabs with ⌘1–⌘9, a tab limit, unloading background tabs.**
  Wait for a reader who keeps many tabs.
- **Per-tab text size.** It is a preference, not a property of a page.
- **CCwiki's own session restore**, ignoring the system's "Close windows when
  quitting" setting. Preview, TextEdit and Mail follow that setting.
- **Rejoining tab groups by hand** if AppKit does not restore them.
- **Paper windows in a reader's tab bar.** That needs a shared tabbing
  identifier, and the reader's commands would go dark in that tab. Two
  windows side by side do the job.
- **In-app PDF search, annotation, outline in the inspector, printing.**
  Preview does these, one click away.
- **Unpaywall, OpenAlex or Semantic Scholar lookups for DOI-only
  references.** They are third-party services, Unpaywall wants an email
  address, and the wiki already prefers a preprint wherever one exists.
- **Publisher-specific rules**, institutional proxies (EZproxy), and borrowing
  the browser's cookies.
- **Fetching papers in the background**, or when a reference page is opened.
- **Searching papers' text in ⌘S.**
- **Incremental rankers**, a parsed library persisted across launches, and
  watching the clone with FSEvents. The clone only changes when CCwiki pulls.
- **Moving jobs and updates out of `AppModel`.** It is worthwhile, but it is
  not this feature.

## 8. Questions for the maintainer

Each has a recommended answer; the spec is written as if it were yes.

1. **⌘-click.** Should it open a background tab (Safari's default), when
   today it opens the linked page on cryptology.city? *Recommended: yes.
   The link's context menu gains Open Link on cryptology.city.*
2. **Restoration.** Should CCwiki follow the system's restore setting, so
   that after a plain Quit (the macOS default) one window opens at the last
   page? Or should it keep its own list of tabs? *Recommended: follow the
   system.*
3. **Papers.** Should a paper open in its own window beside the reader, not
   in a split pane? *Recommended: its own window (§2.2).*
4. **No third-party lookups.** Should CCwiki fetch only from the reference's
   own links? *Recommended: yes; a DOI-only reference is a drop-your-own
   case.*
5. **Show Paper on ⌥⌘P?** *Recommended: yes.*
6. **Fingerprints rather than git's changed-file list** for detecting
   changes? *Recommended: fingerprints (§3.3).*
7. **Search queries shared across tabs** rather than per tab?
   *Recommended: shared (Decision 5).*
8. **Merge order with the other features in flight.** Should this feature
   merge to `main` after relations-followups and before corrections?
   *Recommended: yes (§10).*
9. **In-memory reuse only if measured.** Should D6 be built only when D1's
   suite shows the in-memory phases above 300 ms in a release build (§3.2)?
   *Recommended: yes (§3.2); otherwise the self-patching costs more than it
   saves.*

## 9. Review notes

Three critics (architecture, macOS conventions, safety and honesty) filed 66
findings. Each was checked against the code at `640842b` and the wiki, and
all were adopted; none is rejected. Where critics overlapped or left a
choice open, this spec chose:

- **The ingest sheet** (three findings): one pure `IngestSheetTarget`, fixed
  at request time, plus one rule of its own: while the sheet is up, other
  windows refuse dropped PDFs rather than move or replace it.
- **A paper window restored alone** (two findings): it calls
  `launchIfNeeded()` rather than opening a reader, since the reader was
  closed on purpose.
- **"Sync again (⌘R)"**: kept true by refreshing push capability after every
  sync, rather than changing the blocker's words.
- **The session's lifetime**: `onAppear` and `onDisappear` are not used at
  all; `mainWindowCount` counts live sessions.
- **The palettes' ⌘Return and ⇧⌘Return** are invisible key-equivalent
  buttons with a keycap hint, not a visible footer button, so the footer
  does not show the same action twice.
- **The paper window's height** is clamped by its `WindowReader` on first
  show: on macOS 14, `.defaultSize` cannot read the screen.
- **A linked page on the site** keeps a one-step route, Open Link on
  cryptology.city, carried by a new `LinkDisposition.onSite`. Phase 0 maps
  today's modified click to it, so nothing changes until A5.
- **`LibraryChanges.everything`** is gone: `changes` is nil only with no
  previous library, and a full build is `isFullBuild`.
- **D3–D4's in-memory reuse** became D6, built only if measured worth it;
  added as question 9.

## 10. Seams with the rest of the batch

Two other specs are built beside this one, from the same base:
[relations-followups.md](relations-followups.md) and
[corrections.md](corrections.md). **They merge to `main` one at a time:
relations-followups, then this spec, then corrections.**

- **relations-followups first.** It is the smallest, and it meets this spec
  in five places, each a few lines: one step of the library load, the
  inspector's derived-row menu, `CCwikiCommands`, `RelationsExplorerView`
  and `RelationLabels.swift`.
- **This spec before corrections.** This spec changes the ground the other
  two stand on: who owns the page being read, the window scenes, the
  launch, and `WebController`'s initialiser and link callback. Corrections
  adds per-window state, an editor window, a review in the Jobs window, and
  code in the same `WebController` and `ccwiki.js` handlers. Its integrator, who knows its
  design, adapts it once on top of the sessions (corrections §17). The
  other way round, A2's mechanical move would have to decide what in a
  design it does not own is per window.

**When this spec's integrator rebases onto relations-followups:**

- `LoadedLibrary.build(cloneRoot:)` carries relations-followups' step out
  of the old detached body: after building the derivation, set
  `derivation.unverifiedCitations` from `missingQuotes`, reading the cited
  pages under `content/`. `update` sets it afresh on every load (§3.4).
- The inspector's derived rows keep their click (Show Proof) and get this
  menu:

  ```
  Show Proof
  Explore From Here…              (when the row has a question)
  Open “<label>”
  Open in New Tab                 (this spec, A5)
  Open in New Window              (this spec, A5)
  ───
  Copy Statement
  Copy Proof As ▸ Text · LaTeX · Wiki Markdown    (relations-followups B)
  ```
- `CCwikiCommands` keeps `@FocusedValue(\.proofCopyAction)` and
  `CommandGroup(after: .pasteboard)`. Copy Proof As needs no session: the
  explorer is one window however many readers are open, and the inspector's
  copy goes through `model.copyDerivedProof`, which is app-wide.
- `RelationsExplorerView`: A's two `openWindow` calls, and
  relations-followups' `rowMenu`, focused value and new `follow` case, are
  different lines. The new case calls `model.openPage(path, anchor:)`,
  which §1.8 keeps for windows that are not readers.
- `RelationLabels.swift`: D3's `extension RelationLabels: Equatable {}` goes
  at the end of the file; relations-followups edits only the symbol table.

**What corrections builds on.** These are interfaces corrections §17
names; renaming one means updating that section: `ReaderSession` (its
stored properties, the closures its `init` wires, `renderCurrent`),
`launchIfNeeded()`, `WindowReader`, `model.webRoot`, `model.pageZoom`,
`WebController.init(paths:webRoot:pageZoom:)` and `sharedDataStore`,
`LinkDisposition`, `ReaderWindow()`, `requestIngestSheet(in:)`, the API
for windows that are not readers (§1.8), `mainWindowCount`, and
`ScreenshotRunner.run(model:session:openWindow:)`.

**Code both specs touch:**

- `webRoot`: corrections' Phase 0 declares the same `let webRoot: URL`, set
  once in `init` from `paths.stagedWebRoot()`. Its integrator drops its copy.
- `WikiIndex.assemble(contentRoot:files:pages:)` (§4.6): one function,
  whichever of D6 and corrections' Track D lands first.
- `GitService.swift`: D's methods beside `modifiedDates(in:)`; corrections'
  after `updateSubmodules(in:onLine:)`.
- `ReaderContextTarget` ends `…, algorithmExpanded, link, selection`, with
  both new parameters defaulted to nil, so existing calls and
  `ReaderContextMenuTests` compile. Both specs add test functions to that
  file and edit no existing one.
- The reader's context menu, top to bottom: the copy items (Copy LaTeX…);
  WebKit's Open Link and B's three link items; WebKit's own items; the page
  group (Open Page on cryptology.city, Copy Link to Page, Explore From This
  Page…); corrections' group behind a separator (Edit This Passage…,
  Describe a Correction…, Open an Issue About This Passage…). The existing
  pass that drops doubled separators runs last.
- `ccwiki.js`: corrections moves the Markdown half into
  `ccwiki-markdown.js`. B edits only the `click`, `mousedown`, `mouseup`
  and `contextmenu` handlers, which stay in `ccwiki.js`.

**Menus after the batch:**

| Menu | Items, in order |
|---|---|
| File | New Window ⌘N, New Tab ⌘T, ─, Quick Switcher… ⌘O, Ingest a Paper… ⇧⌘N; Print… ⌘P |
| Edit | the system's items; after the pasteboard group: ─, Copy Proof As ▸ (Text, LaTeX ⌥⌘C, Wiki Markdown ⌥⇧⌘C), Copy BibTeX of Cited Works; then Find as today |
| Wiki | Sync with GitHub, Go Home, Show Sync Log…, Random Page ─ Relations Explorer, Explore From This Page ─ Open on cryptology.city, Copy Link, Copy Wikilink, Show Paper ─ Edit Page…, Describe a Correction…, Open an Issue About This Page… ─ Reveal Page in Finder, Reveal Clone in Finder |
| Jobs | Ingest a Paper… ⇧⌘N, Show Jobs ⇧⌘J ─ Review Changes ⌘↩, Open Draft PR |

**Shortcuts the batch adds.** design-system.md §4 is the app's map; each
feature adds its own rows to it. None collides:

| Keys | Command | Enabled | Spec |
|---|---|---|---|
| ⌘N, ⌘T | New Window, New Tab | always | this |
| ⌥⌘P | Wiki ▸ Show Paper | a reference page in the key reader | this |
| ⌘+ ⌘− ⌘0 | the same items, titled Zoom In, Zoom Out, Zoom to Fit | a paper window | this |
| ⌘↩, ⇧⌘↩ | open the highlighted hit in a background or a front tab | inside a palette | this |
| ⌥⌘E | Wiki ▸ Edit Page… | a wiki page in the key reader | corrections |
| ⌘↩ | Jobs ▸ Review Changes | an editor window | corrections |
| ⌥⌘C, ⌥⇧⌘C | Edit ▸ Copy Proof As ▸ LaTeX, Wiki Markdown | the explorer, with an answer | relations-followups |

⌘↩ is the one chord with two meanings, never in one window: a menu item
only in an editor window, and elsewhere a sheet's own button (IngestSheet's
Start Job today, corrections' two sheets, these palettes). Corrections
§12.3 checks by hand that a sheet keeps it.

**If the lead reverses the order** (corrections before this spec), the
same seams apply the other way. A2 also moves corrections' per-window
members into `ReaderSession` (corrections §17 lists them).
`launchIfNeeded` gets no `loadJobHistory()` step. A3's gate excepts
`ReviewView` and `EditorWindow`. A4b gives the editor and Jobs scenes
`launchIfNeeded`, `appDelegate.model` and the editor's tabbing identifier.
