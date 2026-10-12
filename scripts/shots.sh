#!/usr/bin/env bash
#
# shots.sh — drive the built app through a plan of views and capture each one.
#
#   ./scripts/shots.sh <output-dir> "<plan>" [<app>]
#
# The plan is a comma-separated list of steps understood by ScreenshotRunner:
#
#   home                      the wiki's front page
#   page:<content-relative>   e.g. page:Primitives/pseudorandom-function.md
#   folder:<slug>             a synthetic folder listing, e.g. folder:References
#   switcher:<query>          the ⌘O palette, pre-filled
#   search:<query>            the ⇧⌘F full-text sheet, pre-filled
#   outline | backlinks       flip the inspector
#   light | dark              switch NSAppearance
#   paper:<content-relative>  a reference page's paper window, served from
#                             CCWIKI_PAPER_FIXTURES (Offline for any paper
#                             without a fixture); it stays in front
#   window:<content-relative> a second reader window on that page; the
#                             steps after it drive the new window
#   tab:<content-relative>    a new tab of the key reader window on that
#                             page, in front; the steps after it drive it
#   bgtab:<content-relative>  the same tab behind the one being read, once
#                             WindowTabbing.joinsInBackground is on (in
#                             front until then)
#   edit:<content-relative>   an edit of that page, begun past the blockers,
#                             in its editor (plans/corrections.md §12.3)
#   review:<content-relative> a scripted one-word edit of that page, reviewed
#                             in Jobs; a later `source` step shows it as Source
#   describe:<content-relative>, issue:<content-relative>
#                             the Describe a Correction or Open an Issue
#                             sheet over that page
#
# The jobs edit: and review: begin are discarded when the plan ends, so no
# run leaves a worktree behind.
#
# The app pauses at each step and writes `.ready-N`; this script captures the
# window with `screencapture -l` and answers with `.go-N`. That handshake is
# what makes the captures real — including vibrancy, which no in-process
# drawing API can reproduce.
#
# Requires the Screen Recording permission for whatever runs this script
# (System Settings → Privacy & Security → Screen & System Audio Recording).
# Without it `screencapture` fails and the app's own fallback capture is used
# instead, which renders everything except the blurred backdrops.
#
# The app defaults to "build/CCwiki Dev.app", what `make` builds (`make shots`
# passes the bundle its CHANNEL built). CCwiki Dev reads its own wiki under
# "Application Support/CCwiki-Dev", which its first launch downloads; a release
# that is open meanwhile is left alone. Windows are found by the pid of the
# process started here, never by name.
#
# The app starts with -ApplePersistenceIgnoreState YES, so windows macOS saved
# from your own use of it never come back into a capture. CCWIKI_PAPER_FIXTURES
# defaults to Tests/CCwikiTests/Fixtures/papers; under the harness the app will
# never fetch a paper.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build/shots}"
PLAN="${2:-home}"
APP="${3:-$ROOT/build/CCwiki Dev.app}"

[ -d "$APP" ] || { echo "✗ $APP not found — run make first" >&2; exit 1; }
APP_LABEL="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APP/Contents/Info.plist" 2>/dev/null \
	|| echo CCwiki)"

mkdir -p "$OUT"
rm -f "$OUT"/.ready-* "$OUT"/.go-* "$OUT"/*.png

STEPS=$(printf '%s' "$PLAN" | awk -F',' '{print NF}')
echo "→ $APP_LABEL, $STEPS step(s): $PLAN"

# Can this process capture the screen at all? Probe once, up front, so the
# failure mode is one clear message rather than N blank PNGs.
PROBE="$(mktemp -t ccwiki-probe).png"
if screencapture -x -o "$PROBE" 2>/dev/null && [ -s "$PROBE" ]; then
	EXTERNAL=1
else
	EXTERNAL=0
	echo "  ⚠️  no Screen Recording permission — falling back to the app's own"
	echo "     capture, which cannot draw vibrancy (sidebars will look flat)."
fi
rm -f "$PROBE"

CCWIKI_SHOTS="$OUT" \
CCWIKI_SHOT_PLAN="$PLAN" \
CCWIKI_SHOT_EXTERNAL="$EXTERNAL" \
CCWIKI_PAPER_FIXTURES="${CCWIKI_PAPER_FIXTURES:-$ROOT/Tests/CCwikiTests/Fixtures/papers}" \
	"$APP/Contents/MacOS/CCwiki" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true' EXIT

# `screencapture -l` needs a CGWindowID. A tiny compiled helper beats
# AppleScript here: UI scripting would need the Accessibility permission on top
# of Screen Recording, and CoreGraphics needs neither.
HELPER="$ROOT/build/window-id"
if [ ! -x "$HELPER" ] || [ "$ROOT/scripts/window-id.swift" -nt "$HELPER" ]; then
	swiftc -O -o "$HELPER" "$ROOT/scripts/window-id.swift"
fi

# By pid: the release, "CCwiki", may be open beside this build, and a name
# would find its window as readily as ours.
window_id() { "$HELPER" "$APP_PID" 2>/dev/null || true; }

if [ "$EXTERNAL" = "1" ]; then
	i=1
	while [ "$i" -le "$STEPS" ]; do
		# Wait for the app to say this view is on screen and settled.
		waited=0
		while [ ! -f "$OUT/.ready-$i" ]; do
			sleep 0.2
			waited=$((waited + 1))
			# Generous: an `ingest:` step waits for a real agent job, which is
			# minutes, not seconds.
			if [ "$waited" -gt 12000 ]; then
				echo "✗ timed out waiting for step $i" >&2
				exit 1
			fi
			kill -0 "$APP_PID" 2>/dev/null || { echo "✗ app exited early" >&2; exit 1; }
		done

		NAME="$(cat "$OUT/.ready-$i")"
		WID="$(window_id)" || true
		if [ -n "$WID" ]; then
			screencapture -x -o -l "$WID" "$OUT/$NAME.png" 2>/dev/null \
				|| echo "  ⚠️  capture failed for $NAME"
		else
			echo "  ⚠️  could not find the $APP_LABEL window for $NAME"
		fi
		printf 'ok' > "$OUT/.go-$i"
		rm -f "$OUT/.ready-$i"
		echo "  ✓ $NAME (window $WID)"
		i=$((i + 1))
	done
fi

wait "$APP_PID" 2>/dev/null || true
trap - EXIT
rm -f "$OUT"/.ready-* "$OUT"/.go-*

echo "✓ wrote:"
ls -1 "$OUT" | sed 's/^/  /'
