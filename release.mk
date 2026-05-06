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
# ENTITLEMENTS          path to .entitlements file                 e.g. Reverie.entitlements
# ICON_FILE             AppIcon.icns or other                      default: AppIcon.icns
# DISTRIBUTION_XML      multi-component productbuild definition    e.g. Installer/Distribution.xml

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

OUT_DIR ?= $(CURDIR)/_BuildOutput
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

sign: stamp
	@echo "→ sign $(PRODUCT_NAME)"
	xattr -cr "$(BUILT_BUNDLE)"
	# Recursively sign every embedded framework (leaves first).
	for FW in $(EMBEDDED_FRAMEWORKS); do
		bash $(HELPERS_DIR)/sign-framework.sh "$(BUILT_BUNDLE)/Contents/Frameworks/$$FW.framework" "$(SIGN_ID)"
	done
	# Sign nested helper apps inside the bundle (rare, but ASCII Saver-style).
	if [[ -d "$(BUILT_BUNDLE)/Contents/Library/LoginItems" ]]; then
		for HELPER in "$(BUILT_BUNDLE)"/Contents/Library/LoginItems/*.app; do
			[[ -d "$$HELPER" ]] || continue
			codesign --force --sign "$(SIGN_ID)" --options runtime --timestamp "$$HELPER"
		done
	fi
	# Seal the main bundle. Entitlements file passed if set.
	if [[ -n "$(ENTITLEMENTS)" && -f "$(ENTITLEMENTS)" ]]; then
		codesign --force --sign "$(SIGN_ID)" --options runtime --timestamp \
			--entitlements "$(ENTITLEMENTS)" "$(BUILT_BUNDLE)"
	else
		codesign --force --sign "$(SIGN_ID)" --options runtime --timestamp "$(BUILT_BUNDLE)"
	fi

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
	fi

staple: notarise
	@echo "→ staple $(PRODUCT_NAME)"
	if [[ "$(SIGN_ID)" == "-" ]]; then
		echo "  (skipped: ad-hoc signed)"
	else
		xcrun stapler staple "$(BUILT_BUNDLE)"
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
	# Rename pre-zip if installName differs from productName.
	if [[ "$(INSTALL_NAME)" != "$(PRODUCT_NAME)" ]]; then
		rm -rf "$(INSTALLED_BUNDLE)"
		mv "$(BUILT_BUNDLE)" "$(INSTALLED_BUNDLE)"
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
	# Multi-component installer (ASCII Saver pattern). Each component pkg is
	# expected to already exist in $(OUT_DIR)/<componentID>.pkg — projects with
	# multi-component packages produce them via custom rules in their Makefile
	# before `package-pkg` runs. productbuild assembles the distribution.
	productbuild --distribution "$(DISTRIBUTION_XML)" \
		--package-path "$(OUT_DIR)" \
		--resources "$(dir $(DISTRIBUTION_XML))" \
		"$(PKG_PATH).unsigned"
else
	# Single-component pkg from a renamed bundle.
	# Use INSTALLED_BUNDLE if it exists (zip path renamed it); else the original.
	BUNDLE_FOR_PKG="$(BUILT_BUNDLE)"
	if [[ -d "$(INSTALLED_BUNDLE)" && "$(INSTALL_NAME)" != "$(PRODUCT_NAME)" ]]; then
		BUNDLE_FOR_PKG="$(INSTALLED_BUNDLE)"
	fi
	pkgbuild --component "$$BUNDLE_FOR_PKG" \
		--identifier "$(BUNDLE_ID)" \
		--version "$(VERSION)" \
		--install-location "$(INSTALL_ROOT)" \
		--scripts "$(OUT_DIR)/_pkg_scripts" \
		"$(PKG_PATH).unsigned"
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
		"$(OUT_DIR)/_pkg_scripts" "$(OUT_DIR)/_verify"

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
	rm -rf "$(OUT_DIR)"
	mkdir -p "$(OUT_DIR)"
	xcodebuild -project "$(XCODE_PROJECT)" \
		-scheme "$(XCODE_SCHEME)" \
		-configuration Release \
		CONFIGURATION_BUILD_DIR="$(OUT_DIR)" \
		CODE_SIGNING_ALLOWED=NO \
		ARCHS='arm64 x86_64' \
		ONLY_ACTIVE_ARCH=NO \
		build
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
