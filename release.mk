# release.mk — shared Make include for Jorvik Software project releases.
#
# Each Jorvik project's Makefile sets project-identity variables and
# `include`s this file. The `release` target then handles build → version
# stamp → sign → notarise → staple → package end-to-end. Driven by
# Release Manager (which exports VERSION/BUILD_NUMBER/SIGN_ID/etc as env
# vars) or by hand from the terminal during development.
#
# See README.md in the same directory for the full project-Makefile contract.

# ── Make hygiene ──────────────────────────────────────────────────────────────
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:
.ONESHELL:
.DEFAULT_GOAL := release

# ── Required variables (set by project Makefile) ──────────────────────────────
# BUNDLE_NAME           short name (no extension)             e.g. Reverie
# BUNDLE_TYPE           app | saver                           e.g. saver
# PRODUCT_NAME          on-disk bundle name                   e.g. Reverie.saver
# BUNDLE_ID             reverse-DNS identifier                e.g. cc.jorviksoftware.Reverie
# BUILD_SYSTEM          xcode | spm | swiftc                  e.g. swiftc

# ── Required for swiftc builds ────────────────────────────────────────────────
# SWIFT_FRAMEWORKS      space-separated framework list        e.g. Cocoa ScreenSaver CoreGraphics
# SWIFT_SOURCES         project Swift files (top-level)       e.g. ReverieView.swift ReverieEngine.swift ...

# ── Required for xcode builds ─────────────────────────────────────────────────
# XCODE_PROJECT         project file                          e.g. ASCIISaver.xcodeproj
# XCODE_SCHEME          scheme to build                       e.g. ASCIISaver

# ── Required for spm builds ───────────────────────────────────────────────────
# SPM_PRODUCT           Package.swift product name            e.g. ClipMan

# ── Optional ──────────────────────────────────────────────────────────────────
# INSTALL_NAME          display name (defaults to PRODUCT_NAME)   e.g. "Jorvik Release Manager.app"
# PACKAGE_TYPE          zip | pkg                                  default: zip
# ALSO_SHIP_PKG         true | false                               default: false
# EMBEDDED_FRAMEWORKS   space-separated, embedded into bundle      e.g. Sparkle
# ENTITLEMENTS          path to MAIN bundle's .entitlements file   e.g. Reverie.entitlements
# ICON_FILE             AppIcon.icns or other                      default: AppIcon.icns
# DISTRIBUTION_XML      multi-component productbuild definition    e.g. Installer/Distribution.xml
# PKG_RESOURCES         dir of Welcome.html/Conclusion.html etc    e.g. Installer
# PKG_MAIN_IDENTIFIER   component-pkg identifier for main target   e.g. com.jorviksoftware.ASCIISaver.saver
# PKG_MAIN_FILENAME     component-pkg filename, matches Dist.xml   e.g. ASCIISaver-saver.pkg
# PKG_MAIN_SCRIPTS      per-main-component scripts dir             e.g. Installer/scripts
# HELPER_TARGETS        space-sep colon-records (multi-target).
#                       Each: <xcodeTarget>:<productName>:<entitlements>:<pkgIdentifier>:<pkgFilename>
#                       e.g. ASCIISaverCameraAgent:ASCIISaverCameraAgent.app:CameraAgent/ASCIISaverCameraAgent.entitlements:com.jorviksoftware.ASCIISaver.agent:ASCIISaver-agent.pkg

# ── Defaults ──────────────────────────────────────────────────────────────────
INSTALL_NAME ?= $(PRODUCT_NAME)
PACKAGE_TYPE ?= zip
ALSO_SHIP_PKG ?= false
ICON_FILE ?= AppIcon.icns
# Path to the project's Info.plist. Most apps keep it at project root;
# SPM apps that put it under Resources/ override this (e.g. ClipMan).
INFO_PLIST ?= Info.plist

# ── Variables expected from environment (RM passes these) ─────────────────────
# VERSION             marketing version             e.g. 1.0.0
# BUILD_NUMBER        timestamp build number        e.g. 20260506061500
# SIGN_ID             Developer ID Application      "Developer ID Application: Jonthan Hollin (EG86BCGUE7)"
# INSTALLER_SIGN_ID   Developer ID Installer
# NOTARY_PROFILE      keychain profile name         "JorvikNotary"
# OUT_DIR             absolute path for outputs     RM's buildOutputDir
# JORVIK_RELEASE_MK   path to this file (already resolved by `include`)
#
# When run from terminal without RM, sensible fallbacks let `make release`
# work locally (will use ad-hoc signing if SIGN_ID isn't set).

OUT_DIR ?= $(CURDIR)/.build
SIGN_ID ?= -
INSTALLER_SIGN_ID ?=
NOTARY_PROFILE ?= JorvikNotary
VERSION ?= 0.0.0
BUILD_NUMBER ?= $(shell date "+%Y%m%d%H%M%S")

# Resolve the helpers directory relative to this file. `lastword MAKEFILE_LIST`
# is "this file's path" while it's being parsed, even when included.
JORVIK_RELEASE_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
HELPERS_DIR := $(JORVIK_RELEASE_DIR)helpers

# ── Derived paths ─────────────────────────────────────────────────────────────
BUILT_BUNDLE := $(OUT_DIR)/$(PRODUCT_NAME)
INSTALLED_BUNDLE := $(OUT_DIR)/$(INSTALL_NAME)
ZIP_PATH := $(OUT_DIR)/$(BUNDLE_NAME).zip
PKG_PATH := $(OUT_DIR)/$(BUNDLE_NAME).pkg
NOTARIZE_ZIP := $(OUT_DIR)/$(BUNDLE_NAME)-notarize.zip

# Install root depends on bundle type.
ifeq ($(BUNDLE_TYPE),saver)
INSTALL_ROOT := /Library/Screen Savers
else
INSTALL_ROOT := /Applications
endif

# Build Mach-O architecture flags (universal binaries are non-negotiable).
ARCH_LIST := arm64 x86_64

# Platform target. macOS 14 minimum across the suite.
MACOS_TARGET := 14.0
SDK := $(shell xcrun --sdk macosx --show-sdk-path)

# ── Top-level targets ─────────────────────────────────────────────────────────
# All targets are .PHONY because Make cannot have a file-target whose path
# contains a space (e.g. "/Users/jonathanhollin/Desktop/Jorvik Software/...").
# Inside recipes, paths are quoted so the shell handles spaces correctly.

.PHONY: release build stamp sign notarise staple package package-zip package-pkg clean

release: package
	@echo "✅ release: $(BUNDLE_NAME) $(VERSION) ($(BUILD_NUMBER))"

# Pipeline order: build → stamp (pre-sign) → sign → notarise → staple → package.
# Make's prerequisite chain enforces order.

stamp: build
	@echo "→ stamp $(VERSION) ($(BUILD_NUMBER))"
	bash $(HELPERS_DIR)/stamp-version.sh "$(BUILT_BUNDLE)" "$(VERSION)" "$(BUILD_NUMBER)"
	# Multi-target: stamp each helper bundle too.
	for HELPER in $(HELPER_TARGETS); do
		HELPER_PRODUCT=$$(echo "$$HELPER" | cut -d: -f2)
		bash $(HELPERS_DIR)/stamp-version.sh "$(OUT_DIR)/$$HELPER_PRODUCT" "$(VERSION)" "$(BUILD_NUMBER)"
	done

sign: stamp
	@echo "→ sign $(PRODUCT_NAME)"
	xattr -cr "$(BUILT_BUNDLE)"
	# Recursively sign every embedded framework (leaves first).
	for FW in $(EMBEDDED_FRAMEWORKS); do
		bash $(HELPERS_DIR)/sign-framework.sh "$(BUILT_BUNDLE)/Contents/Frameworks/$$FW.framework" "$(SIGN_ID)"
	done
	# Pre-sign nested signable items inside the bundle, deepest-first.
	# Two passes: bundle-style nested code, then bare Mach-O binaries.
	#
	# Pass 1 — nested .app/.xpc/.appex bundles. Covers:
	#   Contents/Library/LoginItems/<helper>.app  — ASCII Saver, MenuTidy LoginItem
	#   Contents/Helpers/<helper>.app             — ActiveSpace MouseCatcher
	#   Contents/PlugIns/<extension>.appex        — extensions, when added
	#   Contents/XPCServices/<service>.xpc        — rare; usually inside frameworks
	# Items inside *.framework/ are skipped (sign-framework.sh handled those).
	while IFS= read -r -d '' NESTED; do
		case "$$NESTED" in
			"$(BUILT_BUNDLE)") continue ;;
			*/*.framework/*) continue ;;
		esac
		codesign --force --sign "$(SIGN_ID)" --options runtime --timestamp "$$NESTED"
	done < <(find "$(BUILT_BUNDLE)" -d \( -name '*.app' -o -name '*.xpc' -o -name '*.appex' \) -print0)
	# Pass 2 — bare Mach-O binaries placed at non-standard locations
	# (e.g. ActiveSpace's Contents/Resources/switch_helper). codesign on
	# the outer bundle treats these as opaque resources, NOT as nested
	# code, so notarisation rejects them with "binary not signed with a
	# valid Developer ID certificate". Pre-signing them here means the
	# outer seal hashes a properly-signed file.
	#
	# Skip the main executable (codesign on the bundle covers it) and
	# anything inside an already-signed sub-bundle. file(1) detection
	# avoids signing ordinary resources that happen to have +x set.
	MAIN_EXEC="$(BUILT_BUNDLE)/Contents/MacOS/$(BUNDLE_NAME)"
	while IFS= read -r -d '' BIN; do
		[[ "$$BIN" == "$$MAIN_EXEC" ]] && continue
		REL="$${BIN#$(BUILT_BUNDLE)/}"
		case "$$REL" in
			*.framework/*|*/*.framework/*) continue ;;
			*.app/*|*/*.app/*) continue ;;
			*.xpc/*|*/*.xpc/*) continue ;;
			*.appex/*|*/*.appex/*) continue ;;
		esac
		if file -b "$$BIN" 2>/dev/null | grep -q "Mach-O"; then
			codesign --force --sign "$(SIGN_ID)" --options runtime --timestamp "$$BIN"
		fi
	done < <(find "$(BUILT_BUNDLE)" -type f -print0)
	# Seal the main bundle. Entitlements file passed if set.
	if [[ -n "$(ENTITLEMENTS)" && -f "$(ENTITLEMENTS)" ]]; then
		codesign --force --sign "$(SIGN_ID)" --options runtime --timestamp \
			--entitlements "$(ENTITLEMENTS)" "$(BUILT_BUNDLE)"
	else
		codesign --force --sign "$(SIGN_ID)" --options runtime --timestamp "$(BUILT_BUNDLE)"
	fi
	# Multi-target: sign each helper bundle (no nested-helper recursion;
	# helper bundles are leaves in the suite. Add framework recursion
	# here if a future app embeds Sparkle inside a helper).
	for HELPER in $(HELPER_TARGETS); do
		HELPER_PRODUCT=$$(echo "$$HELPER" | cut -d: -f2)
		HELPER_ENT=$$(echo "$$HELPER" | cut -d: -f3)
		echo "→ sign helper $$HELPER_PRODUCT"
		xattr -cr "$(OUT_DIR)/$$HELPER_PRODUCT"
		if [[ -n "$$HELPER_ENT" && -f "$$HELPER_ENT" ]]; then
			codesign --force --sign "$(SIGN_ID)" --options runtime --timestamp \
				--entitlements "$$HELPER_ENT" "$(OUT_DIR)/$$HELPER_PRODUCT"
		else
			codesign --force --sign "$(SIGN_ID)" --options runtime --timestamp \
				"$(OUT_DIR)/$$HELPER_PRODUCT"
		fi
	done

notarise: sign
	@echo "→ notarise $(PRODUCT_NAME)"
	# Skip notarisation entirely when ad-hoc signing (no SIGN_ID set
	# meaningfully). Useful for local development; real releases pass
	# SIGN_ID through env.
	if [[ "$(SIGN_ID)" == "-" ]]; then
		echo "  (skipped: ad-hoc signed, not notarising)"
	else
		ditto -c -k --keepParent "$(BUILT_BUNDLE)" "$(NOTARIZE_ZIP)"
		xcrun notarytool submit "$(NOTARIZE_ZIP)" \
			--keychain-profile "$(NOTARY_PROFILE)" --wait --timeout 1800
		rm -f "$(NOTARIZE_ZIP)"
		# Multi-target: notarise each helper bundle too. RM's downstream
		# Verify Notarisation stage walks every target listed in the
		# catalogue and runs `stapler validate` on each, so each must
		# carry its own ticket.
		for HELPER in $(HELPER_TARGETS); do
			HELPER_PRODUCT=$$(echo "$$HELPER" | cut -d: -f2)
			HELPER_ZIP="$(OUT_DIR)/$$HELPER_PRODUCT-notarize.zip"
			echo "→ notarise helper $$HELPER_PRODUCT"
			ditto -c -k --keepParent "$(OUT_DIR)/$$HELPER_PRODUCT" "$$HELPER_ZIP"
			xcrun notarytool submit "$$HELPER_ZIP" \
				--keychain-profile "$(NOTARY_PROFILE)" --wait --timeout 1800
			rm -f "$$HELPER_ZIP"
		done
	fi

staple: notarise
	@echo "→ staple $(PRODUCT_NAME)"
	if [[ "$(SIGN_ID)" == "-" ]]; then
		echo "  (skipped: ad-hoc signed)"
	else
		xcrun stapler staple "$(BUILT_BUNDLE)"
		for HELPER in $(HELPER_TARGETS); do
			HELPER_PRODUCT=$$(echo "$$HELPER" | cut -d: -f2)
			echo "→ staple helper $$HELPER_PRODUCT"
			xcrun stapler staple "$(OUT_DIR)/$$HELPER_PRODUCT"
		done
	fi

# `package` is the dispatcher — fans out based on PACKAGE_TYPE and ALSO_SHIP_PKG.
package: staple
ifeq ($(PACKAGE_TYPE),pkg)
	$(MAKE) package-pkg
else
	$(MAKE) package-zip
ifeq ($(ALSO_SHIP_PKG),true)
	$(MAKE) package-pkg
endif
endif

package-zip:
	@echo "→ package-zip $(BUNDLE_NAME).zip"
	# When INSTALL_NAME differs from PRODUCT_NAME, *copy* the bundle to
	# the install-name location rather than renaming. Two reasons:
	# (a) the .zip needs to contain the install-name bundle so users see
	#     a friendly name on extract;
	# (b) RM's downstream Verify Build / Verify Signing / Verify
	#     Notarisation stages still expect the bundle at PRODUCT_NAME
	#     (because that's what the catalogue's target.productName says).
	# Cost is a few MB of extra disk during the build, which gets cleaned
	# at the end of the pipeline anyway.
	if [[ "$(INSTALL_NAME)" != "$(PRODUCT_NAME)" ]]; then
		rm -rf "$(INSTALLED_BUNDLE)"
		cp -R "$(BUILT_BUNDLE)" "$(INSTALLED_BUNDLE)"
	fi
	rm -f "$(ZIP_PATH)"
	cd "$(OUT_DIR)" && ditto -c -k --keepParent "$(INSTALL_NAME)" "$(BUNDLE_NAME).zip"
	# Verify the zip's signature survives a roundtrip extract.
	rm -rf "$(OUT_DIR)/_verify"
	mkdir -p "$(OUT_DIR)/_verify"
	ditto -x -k "$(ZIP_PATH)" "$(OUT_DIR)/_verify"
	codesign -v "$(OUT_DIR)/_verify/$(INSTALL_NAME)"
	rm -rf "$(OUT_DIR)/_verify"

package-pkg:
	@echo "→ package-pkg $(BUNDLE_NAME).pkg"
	rm -f "$(PKG_PATH)"
	# Materialise the postinstall script with substitutions, then build the pkg.
	rm -rf "$(OUT_DIR)/_pkg_scripts"
	mkdir -p "$(OUT_DIR)/_pkg_scripts"
	sed \
		-e 's|{{INSTALL_ROOT}}|$(INSTALL_ROOT)|g' \
		-e 's|{{PRODUCT_NAME}}|$(PRODUCT_NAME)|g' \
		-e 's|{{INSTALL_NAME}}|$(INSTALL_NAME)|g' \
		"$(HELPERS_DIR)/pkg-postinstall.sh.template" > "$(OUT_DIR)/_pkg_scripts/postinstall"
	chmod +x "$(OUT_DIR)/_pkg_scripts/postinstall"
ifdef DISTRIBUTION_XML
	# Multi-component installer (ASCII Saver pattern). Build a component
	# pkg for the main bundle and each helper, then productbuild combines
	# them via Distribution.xml. The package-id and filename of each
	# component must match the <pkg-ref> entries in Distribution.xml.
	#
	# Main component pkg.
	if [[ -z "$(PKG_MAIN_IDENTIFIER)" ]]; then
		echo "ERROR: PKG_MAIN_IDENTIFIER required when DISTRIBUTION_XML is set"
		exit 1
	fi
	if [[ -z "$(PKG_MAIN_FILENAME)" ]]; then
		echo "ERROR: PKG_MAIN_FILENAME required when DISTRIBUTION_XML is set"
		exit 1
	fi
	echo "→ pkgbuild main $(PKG_MAIN_FILENAME) ($(PKG_MAIN_IDENTIFIER))"
	rm -f "$(OUT_DIR)/$(PKG_MAIN_FILENAME)"
	if [[ -n "$(PKG_MAIN_SCRIPTS)" && -d "$(PKG_MAIN_SCRIPTS)" ]]; then
		pkgbuild --component "$(BUILT_BUNDLE)" \
			--identifier "$(PKG_MAIN_IDENTIFIER)" \
			--version "$(VERSION)" \
			--install-location "$(INSTALL_ROOT)" \
			--scripts "$(PKG_MAIN_SCRIPTS)" \
			"$(OUT_DIR)/$(PKG_MAIN_FILENAME)"
	else
		pkgbuild --component "$(BUILT_BUNDLE)" \
			--identifier "$(PKG_MAIN_IDENTIFIER)" \
			--version "$(VERSION)" \
			--install-location "$(INSTALL_ROOT)" \
			"$(OUT_DIR)/$(PKG_MAIN_FILENAME)"
	fi
	# Helper component pkgs.
	for HELPER in $(HELPER_TARGETS); do
		HELPER_PRODUCT=$$(echo "$$HELPER" | cut -d: -f2)
		HELPER_PKG_ID=$$(echo "$$HELPER" | cut -d: -f4)
		HELPER_PKG_FILE=$$(echo "$$HELPER" | cut -d: -f5)
		case "$$HELPER_PRODUCT" in
			*.saver) HELPER_INSTALL_ROOT="/Library/Screen Savers" ;;
			*) HELPER_INSTALL_ROOT="/Applications" ;;
		esac
		echo "→ pkgbuild helper $$HELPER_PKG_FILE ($$HELPER_PKG_ID)"
		rm -f "$(OUT_DIR)/$$HELPER_PKG_FILE"
		pkgbuild --component "$(OUT_DIR)/$$HELPER_PRODUCT" \
			--identifier "$$HELPER_PKG_ID" \
			--version "$(VERSION)" \
			--install-location "$$HELPER_INSTALL_ROOT" \
			"$(OUT_DIR)/$$HELPER_PKG_FILE"
	done
	# Combine via productbuild. --resources points at Welcome.html etc.
	PB_RESOURCES_FLAG=""
	if [[ -n "$(PKG_RESOURCES)" && -d "$(PKG_RESOURCES)" ]]; then
		PB_RESOURCES_FLAG="--resources $(PKG_RESOURCES)"
	elif [[ -n "$(dir $(DISTRIBUTION_XML))" && -d "$(dir $(DISTRIBUTION_XML))" ]]; then
		PB_RESOURCES_FLAG="--resources $(dir $(DISTRIBUTION_XML))"
	fi
	productbuild --distribution "$(DISTRIBUTION_XML)" \
		--package-path "$(OUT_DIR)" \
		$$PB_RESOURCES_FLAG \
		"$(PKG_PATH).unsigned"
	# Strip the now-redundant component pkgs so RM's release-stage glob
	# only finds the outer .pkg as a release asset.
	rm -f "$(OUT_DIR)/$(PKG_MAIN_FILENAME)"
	for HELPER in $(HELPER_TARGETS); do
		HELPER_PKG_FILE=$$(echo "$$HELPER" | cut -d: -f5)
		rm -f "$(OUT_DIR)/$$HELPER_PKG_FILE"
	done
else
	# Single-component pkg, non-relocatable.
	#
	# `pkgbuild --component <bundle>` defaults to BundleIsRelocatable=YES.
	# At install time the macOS Installer then searches the user's
	# volumes (via LaunchServices/Spotlight) for any existing bundle
	# carrying our bundle ID and installs over THAT location instead
	# of --install-location. For an app the user has only ever built
	# locally on their Desktop, that means the .pkg silently installs
	# into the dev tree — /Applications stays empty, Spotlight finds
	# the wrong copy, and the macOS Installer also throws a TCC
	# prompt for Desktop access during the volume search.
	#
	# Stage the bundle into a clean dir, generate a component plist
	# via --analyze, force BundleIsRelocatable=NO, and build with
	# --root. The pkg now lands exactly where INSTALL_ROOT says.
	#
	# (TODO: the multi-component / DISTRIBUTION_XML branch above has
	# the same defaulting; ASCII Saver hasn't hit it because savers
	# install to /Library/Screen Savers which the volume search
	# doesn't find dev builds in. Worth migrating that branch to the
	# same pattern next time it's touched.)
	BUNDLE_FOR_PKG="$(BUILT_BUNDLE)"
	if [[ -d "$(INSTALLED_BUNDLE)" && "$(INSTALL_NAME)" != "$(PRODUCT_NAME)" ]]; then
		BUNDLE_FOR_PKG="$(INSTALLED_BUNDLE)"
	fi
	PKG_STAGING="$(OUT_DIR)/_pkg_staging"
	PKG_COMPONENT_PLIST="$(OUT_DIR)/_pkg_component.plist"
	rm -rf "$$PKG_STAGING" "$$PKG_COMPONENT_PLIST"
	mkdir -p "$$PKG_STAGING"
	cp -R "$$BUNDLE_FOR_PKG" "$$PKG_STAGING/"
	pkgbuild --analyze --root "$$PKG_STAGING" "$$PKG_COMPONENT_PLIST"
	plutil -replace 0.BundleIsRelocatable -bool NO "$$PKG_COMPONENT_PLIST"
	pkgbuild --root "$$PKG_STAGING" \
		--component-plist "$$PKG_COMPONENT_PLIST" \
		--identifier "$(BUNDLE_ID)" \
		--version "$(VERSION)" \
		--install-location "$(INSTALL_ROOT)" \
		--scripts "$(OUT_DIR)/_pkg_scripts" \
		"$(PKG_PATH).unsigned"
	rm -rf "$$PKG_STAGING" "$$PKG_COMPONENT_PLIST"
endif
	# productsign with Developer ID Installer.
	if [[ -n "$(INSTALLER_SIGN_ID)" ]]; then
		productsign --sign "$(INSTALLER_SIGN_ID)" "$(PKG_PATH).unsigned" "$(PKG_PATH)"
		rm -f "$(PKG_PATH).unsigned"
	else
		mv "$(PKG_PATH).unsigned" "$(PKG_PATH)"
	fi
	# Notarise + staple the .pkg itself (separate submission from the bundle).
	if [[ "$(SIGN_ID)" == "-" || -z "$(INSTALLER_SIGN_ID)" ]]; then
		echo "  (pkg notarisation skipped: not signed for distribution)"
	else
		xcrun notarytool submit "$(PKG_PATH)" \
			--keychain-profile "$(NOTARY_PROFILE)" --wait --timeout 1800
		xcrun stapler staple "$(PKG_PATH)"
	fi
	rm -rf "$(OUT_DIR)/_pkg_scripts"

clean:
	rm -rf "$(OUT_DIR)/$(PRODUCT_NAME)" "$(OUT_DIR)/$(INSTALL_NAME)" \
		"$(ZIP_PATH)" "$(PKG_PATH)" "$(NOTARIZE_ZIP)" \
		"$(OUT_DIR)/_pkg_scripts" "$(OUT_DIR)/_pkg_staging" \
		"$(OUT_DIR)/_pkg_component.plist" "$(OUT_DIR)/_verify"
	# Multi-target detritus.
	if [[ -n "$(PKG_MAIN_FILENAME)" ]]; then
		rm -f "$(OUT_DIR)/$(PKG_MAIN_FILENAME)"
	fi
	for HELPER in $(HELPER_TARGETS); do
		HELPER_PRODUCT=$$(echo "$$HELPER" | cut -d: -f2)
		HELPER_PKG_FILE=$$(echo "$$HELPER" | cut -d: -f5)
		rm -rf "$(OUT_DIR)/$$HELPER_PRODUCT" \
			"$(OUT_DIR)/$$HELPER_PRODUCT-notarize.zip" \
			"$(OUT_DIR)/$$HELPER_PKG_FILE"
	done

# ── Build dispatch ────────────────────────────────────────────────────────────
# The actual `build` target dispatches by BUILD_SYSTEM. swiftc gets the most
# elaborate handling because it has the most variation (frameworks, embedded
# frameworks, JorvikKit, multi-arch lipo). xcode/spm are thinner shells over
# the underlying tools.

ifeq ($(BUILD_SYSTEM),swiftc)

# Source list: project sources + JorvikKit auto-glob (load-bearing — see
# SpaceMan v1.0.0 incident in PipelineEngine.swift comments). Filter out
# generate_icon.swift which is a build-time tool, never compiled in.
SWIFT_ALL_SOURCES := $(filter-out generate_icon.swift, $(SWIFT_SOURCES))
JORVIKKIT_SOURCES := $(wildcard JorvikKit/*.swift)

# Framework flags: standard frameworks + embedded.
FRAMEWORK_FLAGS := $(foreach fw,$(SWIFT_FRAMEWORKS),-framework $(fw))
ifneq ($(strip $(EMBEDDED_FRAMEWORKS)),)
FRAMEWORK_FLAGS += $(foreach fw,$(EMBEDDED_FRAMEWORKS),-framework $(fw)) \
                   -F "$(CURDIR)" -Xlinker -rpath -Xlinker '@executable_path/../Frameworks'
endif

# Saver bundles need -emit-library; .app bundles default to executable.
ifeq ($(BUNDLE_TYPE),saver)
SWIFTC_OUTPUT_FLAGS := -emit-library -module-name $(BUNDLE_NAME)
else
SWIFTC_OUTPUT_FLAGS :=
endif

build:
	@echo "→ build $(PRODUCT_NAME) (swiftc, universal)"
	@mkdir -p "$(BUILT_BUNDLE)/Contents/MacOS" "$(BUILT_BUNDLE)/Contents/Resources"
	# Per-arch compile, then lipo. arm64 first, x86_64 second, then merge.
	for ARCH in $(ARCH_LIST); do
		swiftc -O -target $$ARCH-apple-macos$(MACOS_TARGET) \
			$(SWIFTC_OUTPUT_FLAGS) \
			-o "$(BUILT_BUNDLE)/Contents/MacOS/$(BUNDLE_NAME)_$$ARCH" \
			$(SWIFT_ALL_SOURCES) $(JORVIKKIT_SOURCES) \
			$(FRAMEWORK_FLAGS)
	done
	lipo -create \
		"$(BUILT_BUNDLE)/Contents/MacOS/$(BUNDLE_NAME)_arm64" \
		"$(BUILT_BUNDLE)/Contents/MacOS/$(BUNDLE_NAME)_x86_64" \
		-output "$(BUILT_BUNDLE)/Contents/MacOS/$(BUNDLE_NAME)"
	rm -f "$(BUILT_BUNDLE)/Contents/MacOS/$(BUNDLE_NAME)_arm64" \
	      "$(BUILT_BUNDLE)/Contents/MacOS/$(BUNDLE_NAME)_x86_64"
	# Info.plist: project's Info.plist is the source of truth for everything
	# except CFBundleShortVersionString and CFBundleVersion (which `stamp`
	# overwrites pre-sign). Path is configurable via INFO_PLIST.
	cp "$(INFO_PLIST)" "$(BUILT_BUNDLE)/Contents/Info.plist"
	# Resources: copy everything from Resources/ if it exists (Daily News
	# broke without this). Excludes the .iconset intermediate dir.
	if [[ -d Resources ]]; then
		find Resources -mindepth 1 -maxdepth 1 ! -name "*.iconset" \
			-exec cp -R {} "$(BUILT_BUNDLE)/Contents/Resources/" \;
	fi
	# Two project layouts exist for the icon:
	#   (a) icon under Resources/ (Reverie, Daily News) — handled above
	#   (b) icon at project root (MenuTidy and most other public apps)
	# This handles (b) — copy root-level ICON_FILE if not already in place.
	if [[ -f "$(ICON_FILE)" && ! -f "$(BUILT_BUNDLE)/Contents/Resources/$(ICON_FILE)" ]]; then
		cp "$(ICON_FILE)" "$(BUILT_BUNDLE)/Contents/Resources/$(ICON_FILE)"
	fi
	# Embed frameworks.
	for FW in $(EMBEDDED_FRAMEWORKS); do
		mkdir -p "$(BUILT_BUNDLE)/Contents/Frameworks"
		cp -R "$$FW.framework" "$(BUILT_BUNDLE)/Contents/Frameworks/"
	done

endif  # swiftc

ifeq ($(BUILD_SYSTEM),xcode)

build:
	@echo "→ build $(PRODUCT_NAME) (xcodebuild, universal)"
	# Strip stray com.apple.quarantine xattrs from vendored frameworks
	# (Safari downloads attach this; it silently corrupts signatures).
	# Errors suppressed because the recursion hits read-only .git/objects/
	# entries; we only care about the source tree's actual files.
	xattr -cr "$(CURDIR)" 2>/dev/null || true
	# xcodebuild's stricter sandbox in Xcode 26+ flags artefacts in any
	# previously-used CONFIGURATION_BUILD_DIR that isn't part of the
	# current build's outputs as "Stale file outside allowed root paths".
	# Pre-build cleanup handles the cases under our control:
	#
	#   (a) other project-root build dirs (the legacy `_BuildOutput/` from
	#       before we moved to `.build/`, or a project-local `.build/`
	#       left behind by a `gmake build` when RM is now invoking with a
	#       temp OUT_DIR);
	#   (b) the project's `~/Library/Developer/Xcode/DerivedData/<name>-*`
	#       manifest, which xcodebuild uses to remember past output
	#       locations across invocations.
	#
	# That leaves a separate residual class of warnings: xcodebuild tracks
	# at least one prior CONFIGURATION_BUILD_DIR in some path we have not
	# been able to identify (not LS, not DerivedData, not /Library, not
	# any service we can find — verified empirically while debugging the
	# ASCII Saver helper-target build). Killing services, sweeping LS,
	# and wiping DerivedData all leave the warnings intact. They are
	# cosmetic — every documented build output lands at the current
	# OUT_DIR — so the build target filters this specific warning class
	# out of xcodebuild's stdout/stderr below. All other warnings/errors
	# pass through unchanged.
	#
	# Cost of the cleanup itself: this xcode build can't reuse incremental
	# caching — full rebuild every time. For the six Jorvik xcode projects
	# that's seconds, not minutes.
	for STALE_DIR in "$(CURDIR)/_BuildOutput" "$(CURDIR)/.build"; do
		if [[ -d "$$STALE_DIR" && "$(OUT_DIR)" != "$$STALE_DIR" ]]; then
			rm -rf "$$STALE_DIR"
		fi
	done
	rm -rf "$(HOME)/Library/Developer/Xcode/DerivedData/$(basename $(notdir $(XCODE_PROJECT)))-"*
	rm -rf "$(OUT_DIR)"
	mkdir -p "$(OUT_DIR)"
	xcodebuild -project "$(XCODE_PROJECT)" \
		-scheme "$(XCODE_SCHEME)" \
		-configuration Release \
		CONFIGURATION_BUILD_DIR="$(OUT_DIR)" \
		CODE_SIGNING_ALLOWED=NO \
		ARCHS='arm64 x86_64' \
		ONLY_ACTIVE_ARCH=NO \
		build 2>&1 | awk '!/warning: Stale file .* is located outside of the allowed root paths\./'
	# Multi-target build: also compile each helper target into the same
	# output dir. Helper records are colon-delimited; field 1 is the
	# Xcode target name, field 2 is the productName for verification.
	for HELPER in $(HELPER_TARGETS); do
		HELPER_TARGET=$$(echo "$$HELPER" | cut -d: -f1)
		HELPER_PRODUCT=$$(echo "$$HELPER" | cut -d: -f2)
		echo "→ build helper $$HELPER_PRODUCT (xcodebuild target $$HELPER_TARGET)"
		xcodebuild -project "$(XCODE_PROJECT)" \
			-target "$$HELPER_TARGET" \
			-configuration Release \
			CONFIGURATION_BUILD_DIR="$(OUT_DIR)" \
			CODE_SIGNING_ALLOWED=NO \
			ARCHS='arm64 x86_64' \
			ONLY_ACTIVE_ARCH=NO \
			build 2>&1 | awk '!/warning: Stale file .* is located outside of the allowed root paths\./'
		if [[ ! -d "$(OUT_DIR)/$$HELPER_PRODUCT" ]]; then
			echo "ERROR: helper build did not produce $$HELPER_PRODUCT in $(OUT_DIR)"
			exit 1
		fi
	done
	# Strip xcodebuild detritus.
	rm -rf "$(OUT_DIR)"/*.swiftmodule "$(OUT_DIR)"/*.dSYM

endif  # xcode

ifeq ($(BUILD_SYSTEM),spm)

# When the project vendors any framework under EMBEDDED_FRAMEWORKS (Sparkle
# is the only current case), forward search-path + rpath flags to BOTH
# swiftc and ld so `import <Name>` resolves at compile time and ld can
# find <Name>.framework on disk at link time. The actual `-framework <Name>`
# linker directive is contributed automatically by Swift's auto-link
# mechanism — explicit `-framework` flags here would be redundant and
# made ld fail "framework not found" before auto-link's own flags ran.
ifneq ($(strip $(EMBEDDED_FRAMEWORKS)),)
SPM_EMBED_FLAGS := -Xswiftc -F -Xswiftc "$(CURDIR)" \
                   -Xlinker -F -Xlinker "$(CURDIR)" \
                   -Xlinker -rpath -Xlinker @executable_path/../Frameworks
else
SPM_EMBED_FLAGS :=
endif

build:
	@echo "→ build $(PRODUCT_NAME) (swift build, universal)"
	swift build -c release --arch arm64 --arch x86_64 \
		--product "$(SPM_PRODUCT)" $(SPM_EMBED_FLAGS)
	mkdir -p "$(BUILT_BUNDLE)/Contents/MacOS" "$(BUILT_BUNDLE)/Contents/Resources"
	# Universal binary at .build/apple/...; fall back to single-arch path
	# if SPM hasn't laid out the universal directory for some reason.
	if [[ -f ".build/apple/Products/Release/$(SPM_PRODUCT)" ]]; then
		cp ".build/apple/Products/Release/$(SPM_PRODUCT)" \
			"$(BUILT_BUNDLE)/Contents/MacOS/$(BUNDLE_NAME)"
	else
		cp ".build/release/$(SPM_PRODUCT)" \
			"$(BUILT_BUNDLE)/Contents/MacOS/$(BUNDLE_NAME)"
	fi
	cp "$(INFO_PLIST)" "$(BUILT_BUNDLE)/Contents/Info.plist"
	if [[ -d Resources ]]; then
		find Resources -mindepth 1 -maxdepth 1 ! -name "*.iconset" ! -name "Info.plist" \
			-exec cp -R {} "$(BUILT_BUNDLE)/Contents/Resources/" \;
	fi
	# Project-root icon fallback (see swiftc block for rationale).
	if [[ -f "$(ICON_FILE)" && ! -f "$(BUILT_BUNDLE)/Contents/Resources/$(ICON_FILE)" ]]; then
		cp "$(ICON_FILE)" "$(BUILT_BUNDLE)/Contents/Resources/$(ICON_FILE)"
	fi
	for FW in $(EMBEDDED_FRAMEWORKS); do
		mkdir -p "$(BUILT_BUNDLE)/Contents/Frameworks"
		cp -R "$$FW.framework" "$(BUILT_BUNDLE)/Contents/Frameworks/"
	done

endif  # spm
