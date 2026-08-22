#!/usr/bin/env bash
#
# shots.sh — drive the built app through a plan of views and capture each one.
#
#   ./scripts/shots.sh <output-dir> "<plan>"
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
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build/shots}"
PLAN="${2:-home}"
APP="$ROOT/build/CityDesk.app"

[ -d "$APP" ] || { echo "✗ $APP not found — run make first" >&2; exit 1; }

mkdir -p "$OUT"
rm -f "$OUT"/.ready-* "$OUT"/.go-* "$OUT"/*.png

STEPS=$(printf '%s' "$PLAN" | awk -F',' '{print NF}')
echo "→ $STEPS step(s): $PLAN"

# Can this process capture the screen at all? Probe once, up front, so the
# failure mode is one clear message rather than N blank PNGs.
PROBE="$(mktemp -t citydesk-probe).png"
if screencapture -x -o "$PROBE" 2>/dev/null && [ -s "$PROBE" ]; then
	EXTERNAL=1
else
	EXTERNAL=0
	echo "  ⚠️  no Screen Recording permission — falling back to the app's own"
	echo "     capture, which cannot draw vibrancy (sidebars will look flat)."
fi
rm -f "$PROBE"

CITYDESK_SHOTS="$OUT" \
CITYDESK_SHOT_PLAN="$PLAN" \
CITYDESK_SHOT_EXTERNAL="$EXTERNAL" \
	"$APP/Contents/MacOS/CityDesk" >/dev/null 2>&1 &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true' EXIT

# `screencapture -l` needs a CGWindowID. A tiny compiled helper beats
# AppleScript here: UI scripting would need the Accessibility permission on top
# of Screen Recording, and CoreGraphics needs neither.
HELPER="$ROOT/build/window-id"
if [ ! -x "$HELPER" ] || [ "$ROOT/scripts/window-id.swift" -nt "$HELPER" ]; then
	swiftc -O -o "$HELPER" "$ROOT/scripts/window-id.swift"
fi

window_id() { "$HELPER" CityDesk 2>/dev/null || true; }

if [ "$EXTERNAL" = "1" ]; then
	i=1
	while [ "$i" -le "$STEPS" ]; do
		# Wait for the app to say this view is on screen and settled.
		waited=0
		while [ ! -f "$OUT/.ready-$i" ]; do
			sleep 0.2
			waited=$((waited + 1))
			if [ "$waited" -gt 600 ]; then
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
			echo "  ⚠️  could not find the CityDesk window for $NAME"
		fi
		printf 'ok' > "$OUT/.go-$i"
		rm -f "$OUT/.ready-$i"
		echo "  ✓ $NAME"
		i=$((i + 1))
	done
fi

wait "$APP_PID" 2>/dev/null || true
trap - EXIT
rm -f "$OUT"/.ready-* "$OUT"/.go-*

echo "✓ wrote:"
ls -1 "$OUT" | sed 's/^/  /'
