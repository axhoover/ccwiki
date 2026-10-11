#!/usr/bin/env bash
#
# stamp-info-plist.sh — fill in Resources/Info.plist for one build channel.
#
#   ./scripts/stamp-info-plist.sh <channel> <version> <build> <src> <dst>
#
# A build's identity comes from its channel, never from its version string: a
# `make` at an exact tag has a bare X.Y.Z version and would otherwise look
# exactly like the release (plans/update-integrity.md §2.1).
#
#   channel   bundle id                name         URL scheme    version
#   release   com.axhoover.ccwiki      CCwiki       ccwiki://     X.Y.Z, or refused
#   dev       com.axhoover.ccwiki.dev  CCwiki Dev   ccwiki-dev:// -dev appended
#
# The separate id is what keeps a build from source apart from the release:
# its own defaults, saved state, web data and links, and BuildIdentity.swift
# gives it its own data folders and turns its updater off. Keep the two in
# step; BuildIdentityTests checks that they are.
#
# Plain bash and sed, so it runs on Linux too and CI can check the release
# channel's output without building anything. Prints the stamped identity on
# one line. Writes nothing and exits 1 on an unknown channel, a version or
# build number it will not stamp, or a __PLACEHOLDER__ left in the output.
set -euo pipefail

fail() {
	echo "✗ stamp-info-plist: $*" >&2
	exit 1
}

[ "$#" -eq 5 ] || fail "usage: $0 <release|dev> <version> <build> <src> <dst>"
CHANNEL="$1"
VERSION="$2"
BUILD="$3"
SRC="$4"
DST="$5"

# The characters a version may have. Enough for 0.2.0, 0.2.0-dev and
# 0.2.0-rc1, and nothing that means something to sed or to XML.
VERSION_CHARS='^[0-9A-Za-z.+-]+$'
RELEASE_VERSION='^[0-9]+\.[0-9]+\.[0-9]+$'
ZERO_VERSION='^0+\.0+\.0+$'
BUILD_NUMBER='^[0-9]+(\.[0-9]+)*$'

[[ $VERSION =~ $VERSION_CHARS ]] \
	|| fail "'$VERSION' is not a version: use digits, letters, '.', '+' and '-'."
[[ $BUILD =~ $BUILD_NUMBER ]] \
	|| fail "'$BUILD' is not a build number: use digits and dots, like 202610111530."

case "$CHANNEL" in
release)
	BUNDLE_ID="com.axhoover.ccwiki"
	BUNDLE_NAME="CCwiki"
	URL_NAME="com.axhoover.ccwiki.link"
	URL_SCHEME="ccwiki"
	if ! [[ $VERSION =~ $RELEASE_VERSION ]]; then
		fail "the release channel needs an X.Y.Z version, not '$VERSION'." \
			"Tag the commit (git tag vX.Y.Z), or build the dev channel (CHANNEL=dev)."
	fi
	if [[ $VERSION =~ $ZERO_VERSION ]]; then
		fail "the release channel will not stamp $VERSION: it is no release."
	fi
	;;
dev)
	BUNDLE_ID="com.axhoover.ccwiki.dev"
	BUNDLE_NAME="CCwiki Dev"
	URL_NAME="com.axhoover.ccwiki.dev.link"
	URL_SCHEME="ccwiki-dev"
	case "$VERSION" in
	*-dev*) ;;
	*) VERSION="$VERSION-dev" ;;
	esac
	;;
*)
	fail "unknown channel '$CHANNEL': use release or dev."
	;;
esac

[ -f "$SRC" ] || fail "$SRC not found."

# A source that lost a placeholder would quietly keep whatever literal took
# its place: a dev build stamped with the release's id is the very thing
# this script exists to prevent.
for placeholder in __BUNDLE_ID__ __BUNDLE_NAME__ __URL_NAME__ __URL_SCHEME__ \
	__SHORT_VERSION__ __BUILD_VERSION__; do
	grep -q "$placeholder" "$SRC" || fail "$SRC has no $placeholder to stamp."
done

# Written beside the destination and moved into place, so a failure leaves
# no half-stamped file behind.
PARTIAL="$DST.partial.$$"
trap 'rm -f "$PARTIAL"' EXIT

sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
	-e "s/__BUNDLE_NAME__/$BUNDLE_NAME/g" \
	-e "s/__URL_NAME__/$URL_NAME/g" \
	-e "s/__URL_SCHEME__/$URL_SCHEME/g" \
	-e "s/__SHORT_VERSION__/$VERSION/g" \
	-e "s/__BUILD_VERSION__/$BUILD/g" \
	"$SRC" > "$PARTIAL"

if grep -q '__[A-Z][A-Z_]*__' "$PARTIAL"; then
	left="$(grep -o '__[A-Z][A-Z_]*__' "$PARTIAL" | sort -u | tr '\n' ' ')"
	fail "$SRC has placeholders this script does not fill: ${left% }"
fi

mv "$PARTIAL" "$DST"
trap - EXIT
echo "$CHANNEL: $BUNDLE_NAME $VERSION ($BUILD), $BUNDLE_ID, $URL_SCHEME://"
