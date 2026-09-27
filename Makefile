# CCwiki — an offline reader for cryptology.city, and an agent job launcher
#
# Quick start:
#   make           # debug-builds via SwiftPM into ./build/CCwiki.app
#   make run       # build + launch
#   make check     # compile + unit tests — the gate after every change
#   make shots     # drive the app and capture screenshots (the visual gate)
#   make test      # run the SwiftPM test suite
#   make install   # copy to /Applications/ and register with LaunchServices
#   make help      # full target list
#
# Build is driven by `swift build` + ./build.sh — NO Xcode IDE, NO
# xcodebuild, NO XcodeGen. Xcode is only a toolchain provider (swift /
# codesign / notarytool / stapler). `make dist` produces a
# signed-and-stapled release zip once signing identities are configured.
#
# Offline render pipeline: `./scripts/vendor-web.sh` fetches the pinned,
# checksum-verified markdown-it / KaTeX / pseudocode.js assets into
# Resources/web/. Run once after cloning; the app never fetches at runtime.

CONFIG       := debug
APP          := build/CCwiki.app
LSREGISTER   := /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
MIN_MACOS    := 14
MIN_SWIFT    := 6.0

APP_NAME      := CCwiki
ENTITLEMENTS  := CCwiki/CCwiki.entitlements

# ---------------------------------------------------------------------------
# Release variables
# ---------------------------------------------------------------------------
# Version is resolved in this order:
#   1. VERSION=... on the command line (one-off testing, no tag needed).
#   2. An exact `vX.Y.Z` git tag at HEAD (the canonical `make dist` path).
#   3. The VERSION file at the repo root (preview the pipeline pre-tag).
GIT_TAG_VERSION := $(shell git describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null | sed 's/^v//')
FILE_VERSION    := $(shell test -f VERSION && sed -n '1p' VERSION | tr -d '[:space:]')
VERSION         ?= $(or $(GIT_TAG_VERSION),$(FILE_VERSION))

DIST_DIR      := dist
NOTARY_ZIP    := $(DIST_DIR)/$(APP_NAME)-$(VERSION)-notary.zip
RELEASE_ZIP   := $(DIST_DIR)/$(APP_NAME)-$(VERSION)-macos.zip

# Dev signing identity (used by ./build.sh). Falls back to ad-hoc ("-") if
# the named identity is missing — fine for `make run` on your own machine.
DEV_IDENTITY  ?= -

# Distribution signing. Developer ID + hardened runtime + notarization.
# Set TEAM_ID (and DEVELOPER_NAME if the certificate's common name differs
# from the default) before the first `make dist`, or pass CERT_NAME whole.
# Check the exact name with: security find-identity -v -p codesigning
TEAM_ID        ?=
DEVELOPER_NAME ?= Alex Hoover
CERT_NAME      ?= $(if $(TEAM_ID),Developer ID Application: $(DEVELOPER_NAME) ($(TEAM_ID)),)

# Notarization credentials profile name. Populate once with
# `make notary-setup` (interactive; never puts the password on the cmdline).
NOTARY_PROFILE ?= ccwiki-notary

# The Ed25519 key that signs release zips, which is what the in-app updater
# checks instead of a Developer ID. `make release-keys` makes it once.
RELEASE_KEY_FILE   ?= $(if $(CCWIKI_RELEASE_KEY),$(CCWIKI_RELEASE_KEY),$(HOME)/.config/ccwiki/release-key)
RELEASE_KEY_SOURCE := Sources/CCwiki/App/ReleaseKey.swift
PUBLIC_KEY         := $(shell sed -n 's/.*publicKeyBase64 = "\(.*\)".*/\1/p' $(RELEASE_KEY_SOURCE) 2>/dev/null)
RELEASE_SIG        := $(RELEASE_ZIP).sig

PROVISION_PROFILE ?=
NOTES_FILE       ?=

.PHONY: all deps build check build-only test test-corpus release run clean install uninstall register help \
        icon check-version notary-setup sign zip-notary notarize staple zip-release \
        checksum verify-release dist github-release print-version \
        release-keys package zip-package sign-package verify-package

all: build

help:
	@echo "Build:"
	@echo "  make / build      Build $(CONFIG) into ./$(APP)  (default)"
	@echo "  check             Compile + unit tests — the gate after every change"
	@echo "  build-only        Compile only, no tests"
	@echo "  test              Run the SwiftPM test suite"
	@echo "  test-corpus       …and validate against the real cloned wiki"
	@echo "  shots             Drive the app and capture screenshots (visual gate)"
	@echo "  release           Build release into ./$(APP)"
	@echo "  run               Build and launch $(APP_NAME)"
	@echo "  icon              Regenerate build/AppIcon.icns from scripts/make-icon.swift"
	@echo "  clean             Remove ./build/ ./.build/ ./dist/"
	@echo "  deps              Verify build prerequisites (auto-run before build)"
	@echo ""
	@echo "Local install:"
	@echo "  install           Copy $(APP_NAME).app to /Applications/ and register it"
	@echo "  uninstall         Remove /Applications/$(APP_NAME).app"
	@echo "  register          Refresh LaunchServices for ./$(APP)"
	@echo ""
	@echo "Release without a Developer ID (needs an exact 'vX.Y.Z' git tag):"
	@echo "  release-keys      One-time: make the Ed25519 release key and embed its public half"
	@echo "  package           Build (universal, ad-hoc) → zip → checksum → Ed25519 sign → verify"
	@echo "  github-release    Upload the zip, .sha256 and .sig to a GitHub release"
	@echo ""
	@echo "Release with a Developer ID (also needs a signing identity):"
	@echo "  notary-setup      One-time: store notary creds in keychain ($(NOTARY_PROFILE))"
	@echo "  dist              Build → sign → notarize → staple → zip → checksum → Ed25519 sign"
	@echo "  print-version     Print resolved release VERSION"
	@echo ""
	@echo "  help              Show this message"

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------

deps:
	@echo "→ Checking build prerequisites..."
	@OS_VERSION=$$(sw_vers -productVersion 2>/dev/null); \
	if [ -z "$$OS_VERSION" ]; then \
	  echo "  ✗ Could not detect macOS version. $(APP_NAME) only builds on macOS."; exit 1; \
	fi; \
	OS_MAJOR=$$(echo $$OS_VERSION | cut -d. -f1); \
	if [ $$OS_MAJOR -lt $(MIN_MACOS) ]; then \
	  echo "  ✗ macOS $$OS_VERSION — $(APP_NAME) requires macOS $(MIN_MACOS).0 or newer."; exit 1; \
	fi; \
	echo "  ✓ macOS $$OS_VERSION"
	@command -v swift >/dev/null 2>&1 || { \
	  echo "  ✗ swift not on PATH. Install Xcode (App Store) or the Swift toolchain"; \
	  echo "    from https://swift.org/install/macos/, then re-run."; exit 1; }
	@SW_LINE=$$(swift --version 2>&1 | head -1); \
	echo "  ✓ $$SW_LINE"
	@[ -f Package.swift ] || { echo "  ✗ Package.swift not found. Run make from the repo root."; exit 1; }
	@echo "  ✓ Package.swift present"
	@[ -x ./build.sh ] || { echo "  ✗ ./build.sh missing or not executable."; exit 1; }
	@echo "  ✓ build.sh present"
	@echo "→ Prerequisites OK."

# ---------------------------------------------------------------------------
# Build (delegates to ./build.sh: swift build + bundle + codesign)
# ---------------------------------------------------------------------------

ICON_SCRIPT := scripts/make-icon.swift
APP_ICON    := build/AppIcon.icns

# App icon: regenerated when the script changes. The script renders the icon
# at every macOS size and iconutil packages them.
$(APP_ICON): $(ICON_SCRIPT)
	@mkdir -p build
	@swift $(ICON_SCRIPT)
	@iconutil -c icns build/AppIcon.iconset -o $(APP_ICON)
	@echo "✓ $(APP_ICON)"

icon: $(APP_ICON)

build: deps $(APP_ICON)
	SIGN_IDENTITY="$(DEV_IDENTITY)" PROVISION_PROFILE="$(PROVISION_PROFILE)" VERSION="$(VERSION)" ./build.sh $(CONFIG)

release: deps $(APP_ICON)
	SIGN_IDENTITY="$(DEV_IDENTITY)" PROVISION_PROFILE="$(PROVISION_PROFILE)" VERSION="$(VERSION)" ./build.sh release

# The gate to run after every change: compile, then run the unit tests. No
# .app, no signing. `make shots` is the visual half of the gate — a passing
# build is not a passing app (SWIFTUI-RULES.md §9.3).
check: deps
	swift build -c $(CONFIG)
	@echo "✓ compiles ($(CONFIG))"
	swift test
	@echo "✓ tests pass"

# Compile only, for when you just want to know it builds.
build-only: deps
	swift build -c $(CONFIG)
	@echo "✓ compiles ($(CONFIG))"

# Run the test suite.
test: deps
	swift test
	@echo "✓ tests pass"

# The corpus suite additionally validates against a real clone: every wikilink
# in ~300 pages, the whole frontmatter schema, and the live macro table. Skipped
# by `make test` because it needs the clone to exist.
test-corpus: deps
	CCWIKI_WIKI="$(HOME)/Library/Application Support/CCwiki/repo" swift test
	@echo "✓ tests pass against the real corpus"

print-version:
	@echo "VERSION=$(VERSION)"
	@echo "  git tag at HEAD: $(if $(GIT_TAG_VERSION),$(GIT_TAG_VERSION),(none))"
	@echo "  VERSION file:    $(if $(FILE_VERSION),$(FILE_VERSION),(missing))"

# ---------------------------------------------------------------------------
# Run / install / register
# ---------------------------------------------------------------------------

run: build
	open "$(APP)"

install: build
	@if [ ! -d "$(APP)" ]; then echo "✗ $(APP) missing — build failed?"; exit 1; fi
	rm -rf /Applications/$(APP_NAME).app
	cp -R "$(APP)" /Applications/
	@echo "✓ copied to /Applications/$(APP_NAME).app"
	$(LSREGISTER) -f /Applications/$(APP_NAME).app
	@echo "✓ registered /Applications/$(APP_NAME).app with LaunchServices"

uninstall:
	@if [ -d /Applications/$(APP_NAME).app ]; then \
	  rm -rf /Applications/$(APP_NAME).app 2>/dev/null || sudo rm -rf /Applications/$(APP_NAME).app; \
	  echo "✓ removed /Applications/$(APP_NAME).app"; \
	else \
	  echo "  (no /Applications/$(APP_NAME).app to remove)"; \
	fi

register: build
	$(LSREGISTER) -f "$(APP)"
	@echo "✓ registered $(APP) with LaunchServices"

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------

clean:
	rm -rf build .build $(DIST_DIR)
	@echo "✓ removed build/, .build/, and $(DIST_DIR)/"

# ---------------------------------------------------------------------------
# Release pipeline: sign → zip-notary → notarize → staple → zip-release →
# checksum → verify-release. The two-zip dance is on purpose: Apple's notary
# service operates on a zip; stapling writes the ticket back into the .app;
# the zip we distribute must be a fresh one taken AFTER stapling.
#
#   git tag v0.1.0 && make dist
# ---------------------------------------------------------------------------

dist: check-version clean release sign zip-notary notarize staple zip-release checksum sign-package verify-release verify-package
	@echo "✓ release artifact ready: $(RELEASE_ZIP)"
	@echo "  next: make github-release   (or upload $(RELEASE_ZIP) manually)"

# ---------------------------------------------------------------------------
# The same, without a Developer ID. Ad-hoc signed and universal; what makes
# it trustworthy to the updater is the Ed25519 signature over the zip, made
# with the key from `make release-keys` and checked against the public key
# built into the app. See plans/distribution.md §3, "Tier 2b".
#
#   make release-keys            (once; commit the change to ReleaseKey.swift)
#   git tag v0.2.0 && make package && make github-release
# ---------------------------------------------------------------------------

release-keys:
	@if ! grep -q 'publicKeyBase64 = ""' "$(RELEASE_KEY_SOURCE)"; then \
	  echo "✗ $(RELEASE_KEY_SOURCE) already carries a public key."; \
	  echo "  Replacing it orphans every installed copy, which would then refuse every"; \
	  echo "  future update. If you really mean it, blank the string by hand first."; \
	  exit 1; \
	fi
	@out="$$(swift scripts/release-sign.swift keygen "$(RELEASE_KEY_FILE)")" || exit 1; \
	echo "$$out"; \
	key="$$(printf '%s\n' "$$out" | sed -n 's/^PUBLIC_KEY=//p')"; \
	[ -n "$$key" ] || { echo "✗ keygen printed no public key"; exit 1; }; \
	sed -i '' "s|publicKeyBase64 = \"\"|publicKeyBase64 = \"$$key\"|" "$(RELEASE_KEY_SOURCE)"; \
	echo "✓ embedded the public key in $(RELEASE_KEY_SOURCE) — commit it"

package: check-version clean release zip-package checksum sign-package verify-package
	@echo "✓ package ready: $(RELEASE_ZIP), .sha256, .sig"
	@echo "  next: make github-release"

zip-package:
	@mkdir -p "$(DIST_DIR)"
	rm -f "$(RELEASE_ZIP)"
	ditto -c -k --keepParent "$(APP)" "$(RELEASE_ZIP)"
	@echo "✓ wrote $(RELEASE_ZIP)"

sign-package:
	@if [ ! -f "$(RELEASE_KEY_FILE)" ]; then \
	  echo "✗ no release key at $(RELEASE_KEY_FILE). Run 'make release-keys' once,"; \
	  echo "  or point RELEASE_KEY_FILE (or CCWIKI_RELEASE_KEY) at it."; exit 1; \
	fi
	swift scripts/release-sign.swift sign "$(RELEASE_ZIP)" "$(RELEASE_KEY_FILE)"

verify-package:
	@if [ -z "$(PUBLIC_KEY)" ]; then \
	  echo "✗ $(RELEASE_KEY_SOURCE) has no public key; the app could not verify this package."; \
	  echo "  Run 'make release-keys' and commit the result."; exit 1; \
	fi
	swift scripts/release-sign.swift verify "$(RELEASE_ZIP)" "$(PUBLIC_KEY)"
	codesign --verify --deep --strict --verbose=2 "$(APP)"

check-version:
	@if [ -z "$(VERSION)" ]; then \
	  echo "✗ VERSION is empty — no exact vX.Y.Z git tag at HEAD and no VERSION file."; \
	  echo "  Tag the release first:   git tag v0.1.0 && make dist"; \
	  echo "  Or override:             make dist VERSION=0.1.0"; \
	  exit 1; \
	fi
	@if [ -z "$(GIT_TAG_VERSION)" ]; then \
	  echo "✗ make dist requires an exact 'vX.Y.Z' git tag at HEAD."; \
	  echo "  HEAD currently has no matching tag; VERSION=$(VERSION) came from a fallback."; \
	  echo "  Tag the release first:   git tag v$(VERSION) && make dist"; \
	  exit 1; \
	fi
	@echo "→ release version $(VERSION)"

notary-setup:
	@command -v xcrun >/dev/null 2>&1 || { echo "✗ xcrun not found — install Xcode or the Command Line Tools"; exit 1; }
	@if [ ! -t 0 ]; then \
	  echo "✗ make notary-setup is interactive — run it in a real terminal,"; \
	  echo "  not from an editor / agent shell (it prompts for your password)."; \
	  echo "    1. Create an App-Specific Password at https://appleid.apple.com → Sign-In and Security."; \
	  echo "    2. Run: make notary-setup APPLE_ID=you@example.com TEAM_ID=XXXXXXXXXX"; \
	  echo "    3. Paste the App-Specific Password when prompted."; \
	  exit 1; \
	fi
	@if [ -z "$(TEAM_ID)" ]; then echo "✗ TEAM_ID required: make notary-setup TEAM_ID=XXXXXXXXXX APPLE_ID=you@example.com"; exit 1; fi
	@echo "→ storing notary credentials in keychain profile '$(NOTARY_PROFILE)' (team $(TEAM_ID))"
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)" \
	  --team-id "$(TEAM_ID)" \
	  $(if $(APPLE_ID),--apple-id "$(APPLE_ID)",)
	@echo "✓ stored. 'make dist' / 'make notarize' will use profile '$(NOTARY_PROFILE)'."

sign: release
	@if [ -z "$(CERT_NAME)" ]; then echo "✗ CERT_NAME required (set TEAM_ID, or pass CERT_NAME=...)"; exit 1; fi
	@echo "→ signing $(APP) as $(CERT_NAME)"
	codesign --force --options runtime --timestamp \
	  --entitlements "$(ENTITLEMENTS)" \
	  --sign "$(CERT_NAME)" "$(APP)"
	codesign --verify --strict --verbose=2 "$(APP)"

zip-notary: sign
	@mkdir -p "$(DIST_DIR)"
	rm -f "$(NOTARY_ZIP)"
	ditto -c -k --keepParent "$(APP)" "$(NOTARY_ZIP)"
	@echo "✓ wrote $(NOTARY_ZIP)"

notarize: zip-notary
	@if [ -z "$(NOTARY_PROFILE)" ]; then \
	  echo "✗ NOTARY_PROFILE is empty. Run 'make notary-setup' once first."; \
	  exit 1; \
	fi
	@echo "→ submitting $(NOTARY_ZIP) via profile '$(NOTARY_PROFILE)' (a few minutes)"
	xcrun notarytool submit "$(NOTARY_ZIP)" \
	  --keychain-profile "$(NOTARY_PROFILE)" \
	  --wait

staple: notarize
	xcrun stapler staple "$(APP)"
	xcrun stapler validate "$(APP)"

zip-release: staple
	rm -f "$(RELEASE_ZIP)"
	ditto -c -k --keepParent "$(APP)" "$(RELEASE_ZIP)"
	@echo "✓ wrote $(RELEASE_ZIP)"

# Ordered by the chains that list it (`dist`, `package`); no prerequisite of
# its own, so the notarized and the ad-hoc paths can both reach it.
checksum:
	cd "$(DIST_DIR)" && shasum -a 256 "$$(basename $(RELEASE_ZIP))" > "$$(basename $(RELEASE_ZIP)).sha256"
	@echo "✓ wrote $(RELEASE_ZIP).sha256"

verify-release: zip-release
	spctl --assess --type execute --verbose "$(APP)"
	codesign --verify --deep --strict --verbose=2 "$(APP)"

github-release:
	@if ! command -v gh >/dev/null 2>&1; then echo "✗ gh CLI not installed (brew install gh)"; exit 1; fi
	@if [ -z "$(VERSION)" ]; then echo "✗ VERSION required (tag or override)"; exit 1; fi
	@if [ ! -f "$(RELEASE_ZIP)" ]; then echo "✗ $(RELEASE_ZIP) not found — run make dist first"; exit 1; fi
	@if [ ! -f "$(RELEASE_ZIP).sha256" ]; then echo "✗ $(RELEASE_ZIP).sha256 not found — run make dist first"; exit 1; fi
	@if [ ! -f "$(RELEASE_SIG)" ]; then \
	  echo "✗ $(RELEASE_SIG) not found — the app installs nothing without it. Run make package."; exit 1; \
	fi
	gh release create "v$(VERSION)" \
	  "$(RELEASE_ZIP)" \
	  "$(RELEASE_ZIP).sha256" \
	  "$(RELEASE_SIG)" \
	  --title "$(APP_NAME) $(VERSION)" \
	  $(if $(NOTES_FILE),--notes-file "$(NOTES_FILE)",--generate-notes)
	@echo "✓ published v$(VERSION)"

# ---------------------------------------------------------------------------
# Visual gate
# ---------------------------------------------------------------------------
# SwiftUI's compile guarantees are weak — a passing build is not a passing app
# (SWIFTUI-RULES.md §9.3). `make shots` drives the real .app through a scripted
# plan and writes PNGs, with no Screen Recording permission required: the app
# draws its own views (see Sources/CCwiki/App/ScreenshotRunner.swift).
#
#   make shots                       # the default plan
#   make shots PLAN='page:index.md'  # one specific view
SHOTS_DIR ?= build/shots
PLAN      ?= home,page:Primitives/pseudorandom-function.md,page:Assumptions/learning-with-errors.md,backlinks,switcher:prf,search:oblivious transfer,folder:References,page:References/AGGM06 - On basing one-way functions on NP-hardness.md,light,page:Primitives/pseudorandom-function.md

.PHONY: shots
shots: build
	./scripts/shots.sh "$(PWD)/$(SHOTS_DIR)" "$(PLAN)"
