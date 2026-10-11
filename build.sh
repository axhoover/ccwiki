#!/usr/bin/env bash
#
# build.sh — compile with SwiftPM, assemble a macOS .app bundle, codesign.
#
# Usage:  ./build.sh [debug|release]
#
# Driven by the Makefile. NO Xcode IDE, NO xcodebuild — `swift build` does
# the compile, this script does the bundling and signing. Xcode is only a
# toolchain provider (swift / codesign).
#
# The bundle is always build/CCwiki.app; what it IS comes from CHANNEL. The
# default, dev, is "CCwiki Dev": its own bundle id, data folders and URL
# scheme, and no updater, so it runs beside an installed release without
# touching it. Only `make package` and `make dist` build the release channel.
# See scripts/stamp-info-plist.sh and plans/build-system.md.
#
# Environment:
#   CHANNEL            dev (default) or release. Picks the bundle's identity.
#   SIGN_IDENTITY      codesign identity. Defaults to ad-hoc ("-"), which is
#                      all you need for `make run` on your own machine.
#   PROVISION_PROFILE  optional .provisionprofile to embed (release/dist).
#   VERSION            CFBundleShortVersionString to stamp (default 0.0.0).
#                      The release channel takes X.Y.Z only; the dev channel
#                      adds a -dev suffix when it has none.
#
set -euo pipefail

CONFIG="${1:-debug}"
CHANNEL="${CHANNEL:-dev}"
APP_NAME="CCwiki"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
PROVISION_PROFILE="${PROVISION_PROFILE:-}"
VERSION="${VERSION:-0.0.0}"
ENTITLEMENTS="$APP_NAME/$APP_NAME.entitlements"
INFO_PLIST_SRC="Resources/Info.plist"

# Build number: the build time in UTC, so local and CI builds compare and
# re-signs differ. Falls back to 1.
BUILD_NUMBER="$(date -u +%Y%m%d%H%M 2>/dev/null || echo 1)"

# Stamp the Info.plist before compiling: a release-channel build with a
# version that is not X.Y.Z fails here, not after a two-architecture compile.
mkdir -p "$BUILD_DIR"
STAMPED_PLIST="$BUILD_DIR/Info.plist.stamped"
IDENTITY="$(./scripts/stamp-info-plist.sh \
	"$CHANNEL" "$VERSION" "$BUILD_NUMBER" "$INFO_PLIST_SRC" "$STAMPED_PLIST")"
echo "→ channel $IDENTITY"

# A release is built for both architectures: a download has to run on an
# Intel Mac and an Apple silicon one. One `swift build` per architecture and
# `lipo -create`, rather than one build with two `--arch` flags: the latter
# fails with "duplicate output file" on current toolchains. Debug builds
# stay native, since they are for the machine that made them.
if [ "$CONFIG" = "release" ]; then
	UNIVERSAL_DIR="$BUILD_DIR/universal"
	mkdir -p "$UNIVERSAL_DIR"
	SLICES=()
	for arch in arm64 x86_64; do
		echo "→ swift build -c release --arch $arch"
		swift build -c release --arch "$arch"
		slice="$(swift build -c release --arch "$arch" --show-bin-path)/$APP_NAME"
		if [ ! -x "$slice" ]; then
			echo "✗ executable not found at $slice" >&2
			exit 1
		fi
		SLICES+=("$slice")
	done
	EXECUTABLE="$UNIVERSAL_DIR/$APP_NAME"
	lipo -create "${SLICES[@]}" -output "$EXECUTABLE"
	# Resource bundles, if any dependency ever ships one, are per-arch
	# identical; take them from the first slice's directory.
	BIN_PATH="$(dirname "${SLICES[0]}")"
else
	echo "→ swift build -c $CONFIG"
	swift build -c "$CONFIG"
	BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
	EXECUTABLE="$BIN_PATH/$APP_NAME"
	if [ ! -x "$EXECUTABLE" ]; then
		echo "✗ executable not found at $EXECUTABLE" >&2
		exit 1
	fi
fi

# ---------------------------------------------------------------------------
# Assemble the bundle
# ---------------------------------------------------------------------------
echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$EXECUTABLE" "$APP/Contents/MacOS/$APP_NAME"

# Info.plist — stamped with the channel's identity and the version above.
mv "$STAMPED_PLIST" "$APP/Contents/Info.plist"

# PkgInfo — classic 8-byte file some macOS code paths still look for.
printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftPM resource bundles — if any dependency ships a `*.bundle`, copy it
# into Contents/Resources so the app finds it once moved away from `.build`.
for bundle in "$BIN_PATH"/*.bundle; do
	if [ -e "$bundle" ]; then
		cp -R "$bundle" "$APP/Contents/Resources/"
		echo "  bundled $(basename "$bundle")"
	fi
done

# Vendored offline web pipeline (markdown-it + KaTeX + pseudocode.js). Plain
# files, not a SwiftPM resource bundle: `Bundle.module` resolves against the
# .app ROOT, and anything at the bundle root makes `codesign --verify --strict`
# fail with "unsealed contents present in the bundle root". Contents/Resources
# is the only strictly-valid home, and Bundle.main finds it there.
if [ -d "Resources/web" ]; then
	cp -R "Resources/web" "$APP/Contents/Resources/web"
	echo "  bundled Resources/web ($(find Resources/web -type f | wc -l | tr -d ' ') files)"
else
	echo "  ⚠️  Resources/web missing — run ./scripts/vendor-web.sh (the reader needs it)"
fi

# The ingestion prompt template. Read at job-launch time and filled in by
# PromptComposer; kept as a file rather than a Swift string literal so it can be
# edited and diffed like the wiki's own prompts.
if [ -d "prompts" ]; then
	mkdir -p "$APP/Contents/Resources/prompts"
	cp prompts/*.md "$APP/Contents/Resources/prompts/"
	echo "  bundled prompts/"
fi

# The app's own pages: the Welcome page and the release notes behind What's
# New. Markdown, rendered by the reader like any wiki page.
for doc in Resources/welcome.md CHANGELOG.md; do
	if [ -f "$doc" ]; then
		cp "$doc" "$APP/Contents/Resources/"
		echo "  bundled $doc"
	fi
done

# The derivation engine's reviewed corrections to the wiki's relations.json
# (plans/derivations.md §2a). Read with Bundle.main once Derivation exists.
if [ -f "Resources/derivation-curation.json" ]; then
	cp "Resources/derivation-curation.json" "$APP/Contents/Resources/"
	echo "  bundled Resources/derivation-curation.json"
fi

# App icon (optional — generated by `make icon`).
if [ -f "$BUILD_DIR/AppIcon.icns" ]; then
	cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
	echo "  (no $BUILD_DIR/AppIcon.icns — run 'make icon'; bundling without one)"
fi

# Embed a provisioning profile if one was supplied.
if [ -n "$PROVISION_PROFILE" ] && [ -f "$PROVISION_PROFILE" ]; then
	cp "$PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"
	echo "  embedded provisioning profile"
fi

# ---------------------------------------------------------------------------
# Codesign — try the named identity, fall back to ad-hoc so `make run`
# always works on a fresh machine without certs.
# ---------------------------------------------------------------------------
sign_args=(--force --sign "$SIGN_IDENTITY")
if [ -f "$ENTITLEMENTS" ]; then
	sign_args+=(--entitlements "$ENTITLEMENTS")
fi

echo "→ codesign ($SIGN_IDENTITY)"
if ! codesign "${sign_args[@]}" "$APP" 2>/dev/null; then
	echo "  identity '$SIGN_IDENTITY' unavailable — falling back to ad-hoc (-)"
	codesign --force --sign - ${ENTITLEMENTS:+--entitlements "$ENTITLEMENTS"} "$APP"
fi

codesign --verify --verbose=1 "$APP"
if [ "$CONFIG" = "release" ]; then
	echo "  $(lipo -info "$APP/Contents/MacOS/$APP_NAME")"
fi
echo "✓ built $APP ($CHANNEL channel)"
