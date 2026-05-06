#!/bin/bash
# sign-framework.sh — recursively codesign an embedded framework's payload
# in dependency order (leaves first), then seal the framework root.
#
# Usage:  sign-framework.sh <framework-path> <signing-identity>
#
# Modelled on Sparkle's own signing recipe. Required because `codesign --deep`
# can silently miss nested XPC services and helper apps when they don't share
# a parent designated requirement; explicit leaf-first walking is the only
# reliable approach.
#
# Operates on Sparkle.framework today; the structure (Versions/<v>/XPCServices,
# helper apps, framework root) is generic enough that any future embedded
# framework with the same layout is handled correctly.

set -eu -o pipefail

FRAMEWORK="$1"
SIGN_ID="$2"

if [[ ! -d "$FRAMEWORK" ]]; then
    echo "sign-framework: $FRAMEWORK not found" >&2
    exit 1
fi

FW_NAME="$(basename "$FRAMEWORK")"
VERSIONS_DIR="$FRAMEWORK/Versions"

if [[ -d "$VERSIONS_DIR" ]]; then
    # Per-version: sign every artefact inside, leaves first.
    for V in "$VERSIONS_DIR"/*; do
        # Skip the "Current" symlink — it points at one of the real versions.
        [[ "$(basename "$V")" == "Current" ]] && continue
        [[ -d "$V" ]] || continue

        # XPC services (Downloader.xpc, Installer.xpc).
        if [[ -d "$V/XPCServices" ]]; then
            for XPC in "$V/XPCServices"/*.xpc; do
                [[ -d "$XPC" ]] || continue
                codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$XPC"
            done
        fi

        # Nested helper apps (e.g. Sparkle's Updater.app).
        for ENTRY in "$V"/*.app; do
            [[ -d "$ENTRY" ]] || continue
            codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$ENTRY"
        done

        # Standalone Mach-O helper binaries (e.g. Sparkle's Autoupdate).
        # Loop every entry in $V; codesign anything that's a Mach-O file.
        for ENTRY in "$V"/*; do
            [[ -d "$ENTRY" ]] && continue
            [[ -x "$ENTRY" ]] || continue
            if file "$ENTRY" | grep -q "Mach-O"; then
                codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$ENTRY"
            fi
        done
    done
fi

# Finally seal the framework root. This signs the whole bundle's integrity,
# now that every nested component is itself signed.
codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$FRAMEWORK"

echo "sign-framework: $FW_NAME signed"
