#!/bin/bash
# stamp-version.sh — write CFBundleShortVersionString and CFBundleVersion into
# a bundle's Info.plist. Must run BEFORE codesign so the stamp is part of the
# signed payload; otherwise the signature would invalidate.
#
# Usage:  stamp-version.sh <bundle-path> <marketing-version> <build-number>
#
# Examples:
#   stamp-version.sh Reverie.saver 1.0.0 20260506061500
#   stamp-version.sh "Jorvik Release Manager.app" 2.0.21 20260506061500

set -eu -o pipefail

BUNDLE="$1"
VERSION="$2"
BUILD_NUMBER="$3"

PLIST="$BUNDLE/Contents/Info.plist"

if [[ ! -f "$PLIST" ]]; then
    echo "stamp-version: $PLIST not found" >&2
    exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"

echo "stamp-version: $(basename "$BUNDLE") → $VERSION ($BUILD_NUMBER)"
