# Update integrity: one copy, the right copy, and a dev build beside it

Written 2026-10-11 after two reports from the maintainer:

1. "Both times that I've updated to the new release 0.1.1 and 0.1.2, when I
   quit and relaunched the app later it went back to 0.1.0 … 0.1.0 doesn't
   have the quick auto updates. I've tried clearing out all the relevant
   folders."
2. "I want to be able to test the dev build and have the prod version
   installed on my computer at the same time … run ./build.sh and launch the
   app from the build directory and make sure it's not writing/reading from
   the same thing as the prod app."

The investigation was three web-research tracks and two code and history
audits, and an adversarial checker re-examined every claim. This page
records what it found, what we changed, and what is still unproven.
Nothing could be run on a Mac.

## 1. What makes CCwiki "go back to 0.1.0"

The version CCwiki shows comes from the `Info.plist` of the bundle that is
running (`Bundle.main.shortVersion`). Nothing in Caches, Application Support
or the preferences can change it. So each "revert" was macOS starting a
**different bundle**. Clearing folders could not help.

Ranked, with the evidence for each:

1. **A second copy with the same bundle id (most likely).**
   - The updater replaces only the copy that is running
     (`Bundle.main.bundleURL`). The Dock, Spotlight, Launchpad, Finder and
     `ccwiki://` links can each open a different copy.
   - PROGRESS.md (2026-09-27) records such a copy: an old `make install`
     build in /Applications that called itself 0.1.0 and had no updater.
     Until 2dcf6ee (2026-09-28), every local `make` build not at an exact
     tag was stamped from the `VERSION` file, which said 0.1.0.
   - The release download counters say no copy ever fetched the `.sig` of
     0.1.2 or 0.1.3. The installer always fetches it, before any other
     check. So no real release copy has tried to install either version.
     A copy that runs every day with auto-install on would have done so.
     The copy that keeps coming back therefore has no updater, which also
     matches "0.1.0 doesn't have the quick auto updates".
   - Shared preferences make it worse. `ccwiki.lastUpdateCheck` is one key
     for every copy, so a real release copy launched within 24 hours of
     another copy's check does not check at all.
2. **The trashed old bundle (unlikely, but a real hygiene bug).** Each
   update moved the old bundle to the Trash as `CCwiki.app.previous`. For a
   Dock tile or a LaunchServices record to follow it there, bookmark
   resolution would have to use the file ID before the path. Apple
   documents path-first resolution since 10.2. Even then, LaunchServices
   refuses to run anything in a Trash (`kLSAppInTrashErr`), and the trashed
   folder has no `.app` extension. Mature updaters delete the old bundle
   instead: Sparkle 2 has since 2016, and Squirrel and Homebrew do too.
3. **Ruled out:**
   - Caches.
   - App Translocation: a translocated copy is read-only, so the install
     would have failed visibly.
   - A half-done swap: that throws and shows an alert.

To settle which copy it is, run these on the Mac while the "0.1.0" window
is open:

- **About CCwiki.** Note the build number in parentheses. 202609271503 is
  the real 0.1.0. A number starting 202608, or any other, means a local
  build. Also check whether the app menu has Check for Updates….
- **The running copy's path:** `pgrep -fl 'Contents/MacOS/CCwiki$'`.
- **Every copy macOS knows about:**
  `mdfind 'kMDItemCFBundleIdentifier == "com.axhoover.ccwiki"'`
- **What the Dock tile points at:** Control-click the Dock icon, then
  Options → Show in Finder.

## 2. What changed

### 2.1 Builds from source are "CCwiki Dev" (report 2)

A build's identity is chosen by `CHANNEL`, not by its version string. A
`make` at an exact tag stamps a bare `0.1.3`, which looks like a release.

| | `CHANNEL=release` | `CHANNEL=dev` (the default) |
|---|---|---|
| Made by | `make package`, `make dist` (so `release.yml`) | `./build.sh`, `make`, `make run`, `make release`, CI's PR zip |
| `CFBundleIdentifier` | `com.axhoover.ccwiki` | `com.axhoover.ccwiki.dev` |
| Name (`CFBundleName`, `CFBundleDisplayName`) | CCwiki | CCwiki Dev |
| URL scheme | `ccwiki` | `ccwiki-dev` |
| Version | `X.Y.Z`, refused otherwise | gets a `-dev` suffix if it lacks one |
| Data | `~/Library/Application Support/CCwiki`, `~/Library/Caches/CCwiki` | `…/CCwiki-Dev` in both (no space: worktrees live in Caches) |
| Updates | checks, installs | never checks, never installs |
| `make install` puts it at | `/Applications/CCwiki.app` | `/Applications/CCwiki Dev.app` |

What a distinct bundle id separates automatically:

- UserDefaults.
- Saved Application State.
- WebKit's website data and caches.
- URL caches.
- LaunchServices' choice of handler. A dev build can no longer win
  `ccwiki://` links, Open With or `open -b` from the release.

What the app itself has to separate is the data folders, through
`BuildIdentity.dataFolderName` in `AppPaths.standard()`.

`CFBundleVersion` is stamped in UTC everywhere, so local and CI build
numbers compare. `make verify-package` refuses a package whose bundle id is
not `com.axhoover.ccwiki` or whose version is not the tag.

`AppPaths.stagedWebRoot()` used to delete every other build's staged web
copy at launch. That pulled the reader's JavaScript out from under any other
copy that was running. It now removes only copies untouched for a week.

### 2.2 The updater replaces in one step and leaves nothing behind (cause 2)

`UpdateInstaller.install` stages the verified bundle in a temporary
directory on the destination's volume (`.itemReplacementDirectory`). It
then exchanges it with the installed bundle in one atomic step,
`renamex_np(RENAME_SWAP)`. Where the volume cannot swap, it falls back to
three renames through a temporary name, with rollback. Then it:

- checks that the installed path now carries the new version, and swaps
  back if not;
- deletes the old bundle with the temporary directory, never moving it to
  the Trash;
- touches the new bundle and calls `LSRegisterURL(url, true)`, so
  LaunchServices, Spotlight and Finder see the new version (Sparkle does
  the same);
- never replaces a copy that is already as new as the release;
- refuses, with a clear message, to update a copy running from a Trash or
  from App Translocation.

### 2.3 Other copies are found at launch (cause 1)

A stale copy cannot detect itself, so the new version does it. At launch, a
release build asks LaunchServices for every copy of `com.axhoover.ccwiki`
(`NSWorkspace.urlsForApplications(withBundleIdentifier:)`). It drops itself,
missing paths, anything in a Trash, anything on a read-only volume, and paths
the user chose to ignore. Then it decides, in a pure, tested function
(`InstallationCheck.advice`):

- **A newer copy exists.** "A newer version of CCwiki is on this Mac", with
  Open CCwiki X (opens it, then quits this one) or Keep Using This Version.
  This doubles as the downgrade guard.
- **This copy runs outside an Applications folder, and an older one sits in
  one.** "Replace the older CCwiki in Applications?", with Replace and
  Relaunch:
  1. copy this bundle onto the older copy's volume;
  2. swap it in with the updater's primitive and delete the old one;
  3. move this copy to the Trash;
  4. relaunch from Applications.
  This is the LetsMove idiom, limited to the case that causes confusion.
- **Other older or duplicate copies.** "Another copy of CCwiki is on this
  Mac", listing each version and location, with Move to Trash, Show in
  Finder, or Not Now. A copy in the Trash cannot run (`kLSAppInTrashErr`),
  so moving it there is enough.

Not Now with "Don't ask again" remembers those paths. A copy with the
release id and a `-dev` version is a stale pre-channel dev build. It counts
as older and never as newer.

Settings → About shows the running copy's location with Show in Finder.
Each launch logs one line with the version, build and path, under subsystem
`com.axhoover.ccwiki`, category `launch`. So
`log show --last 7d --predicate 'subsystem BEGINSWITH "com.axhoover.ccwiki"'`
answers "which copy ran when". `ccwiki.lastSeenVersion` only moves forward,
so an older copy can no longer rewind What's New.

## 3. Not done, on purpose

- **Swapping only `Contents/` to keep the bundle folder's identity**, as
  Homebrew does since 2023. It keeps Dock and Launchpad associations, but it
  modifies a launched bundle, which Apple DTS advises against, and it is
  untested against App Management. Revisit only if Dock tiles show a
  question mark after updates.
- **Installing at quit (Sparkle's model).** Today's install-while-running
  works, and the reader's web assets are already pinned per build.
- **Scanning or emptying the Trash.** It is privacy-protected, and it
  belongs to the user.
- **Private SecTranslocate APIs.**

## 4. Open questions for the maintainer

- Which copy was the "0.1.0"? See the commands in §1.
- How do you usually open CCwiki: the Dock, Spotlight, Launchpad or Apps,
  Raycast or Alfred, or Finder? And how did 0.1.2 arrive? Its `.sig` was
  never downloaded.
