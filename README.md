# jorvik-release

Shared Make include for Jorvik Software project releases. Each project's `Makefile` declares its identity (bundle name, build system, frameworks, etc.) and `include`s `release.mk`. The single `gmake release` target then handles build → version stamp → sign → notarise → staple → package end-to-end, in shell, where `codesign`, `xcrun notarytool`, `pkgbuild`, and `ditto` are first-class citizens.

## Prerequisites

GNU Make **4.0+** (the macOS-bundled `/usr/bin/make` is 3.81 from 2006 and lacks `.ONESHELL` and `.SHELLFLAGS`):

```bash
brew install make
```

Homebrew installs it as `gmake` to avoid clobbering the system `make`. Invoke as `gmake release …` everywhere; Release Manager invokes `gmake` explicitly.

This replaces the per-app build/sign/package logic that used to live inside [Release Manager](https://github.com/PerpetualBeta/JorvikReleaseManager)'s Swift `PipelineEngine`. RM now dispatches `gmake release` with a handful of environment variables and re-verifies the resulting artefacts; it no longer re-implements `xcodebuild`, `codesign --deep`, or `pkgbuild` invocations in Swift.

## Layout

```
jorvik-release/
├── release.mk                          # the include
├── helpers/
│   ├── sign-framework.sh               # leaves-first recursive Sparkle/XPC sign
│   ├── stamp-version.sh                # PlistBuddy version + build-number stamp
│   └── pkg-postinstall.sh.template     # parametrised postinstall (installName mv + xattr -dr quarantine)
└── README.md
```

Clone path on the dev machine: `~/Desktop/Jorvik Software/jorvik-release/`. Each Jorvik project's `Makefile` references the include via a relative path (the absolute path contains a space and Make's `include` directive treats whitespace as a path-list separator):

```makefile
include ../jorvik-release/release.mk
```

This works under terminal `gmake` (cwd = project dir) and under RM (RM `cd`'s to `sourcePath` before invoking `gmake`).

## Project Makefile contract

The minimum `Makefile` for a single-target swiftc-built `.app` with embedded Sparkle and dual `.zip`+`.pkg` shipping looks like this:

```makefile
BUNDLE_NAME      := MenuTidy
BUNDLE_TYPE      := app
PRODUCT_NAME     := MenuTidy.app
BUNDLE_ID        := cc.jorviksoftware.MenuTidy
BUILD_SYSTEM     := swiftc

SWIFT_FRAMEWORKS := Cocoa SwiftUI ServiceManagement
SWIFT_SOURCES    := main.swift MenuTidyApp.swift ...

PACKAGE_TYPE     := zip
ALSO_SHIP_PKG    := true
EMBEDDED_FRAMEWORKS := Sparkle
ENTITLEMENTS     := MenuTidy.entitlements

include ../jorvik-release/release.mk
```

### Required variables (every project)

| Variable | Description | Example |
|---|---|---|
| `BUNDLE_NAME` | Short name without extension | `Reverie` |
| `BUNDLE_TYPE` | `app` or `saver` | `saver` |
| `PRODUCT_NAME` | On-disk bundle name | `Reverie.saver` |
| `BUNDLE_ID` | Reverse-DNS identifier | `cc.jorviksoftware.Reverie` |
| `BUILD_SYSTEM` | `xcode`, `spm`, or `swiftc` | `swiftc` |

### Required by `BUILD_SYSTEM`

**`swiftc`:**

| Variable | Description |
|---|---|
| `SWIFT_FRAMEWORKS` | Space-separated framework list |
| `SWIFT_SOURCES` | Project Swift files at top level (`JorvikKit/*.swift` is auto-included) |

**`xcode`:**

| Variable | Description |
|---|---|
| `XCODE_PROJECT` | Project file (e.g. `MenuTidy.xcodeproj`) |
| `XCODE_SCHEME` | Build scheme |

**`spm`:**

| Variable | Description |
|---|---|
| `SPM_PRODUCT` | `Package.swift` product name |

### Optional variables

| Variable | Default | Description |
|---|---|---|
| `INSTALL_NAME` | `$(PRODUCT_NAME)` | Display name. Override when product and install names differ (e.g. `Jorvik Release Manager.app` vs `JorvikReleaseManager.app`). |
| `PACKAGE_TYPE` | `zip` | `zip` or `pkg` |
| `ALSO_SHIP_PKG` | `false` | When `PACKAGE_TYPE=zip`, also produce a `.pkg` (dual-ship). |
| `EMBEDDED_FRAMEWORKS` | _(empty)_ | Space-separated frameworks to copy into `Contents/Frameworks/` (e.g. `Sparkle`). |
| `ENTITLEMENTS` | _(none)_ | Path to `.entitlements` file passed to `codesign`. |
| `ICON_FILE` | `AppIcon.icns` | Bundle icon name. |
| `DISTRIBUTION_XML` | _(none)_ | For multi-component pkg installers (ASCII Saver pattern), points at a `productbuild` distribution definition. |

## Environment contract (set by RM, fallbacks for terminal use)

| Variable | Required | Default for terminal | Purpose |
|---|---|---|---|
| `VERSION` | recommended | `0.0.0` | `CFBundleShortVersionString` stamp |
| `BUILD_NUMBER` | recommended | `date +%Y%m%d%H%M%S` | `CFBundleVersion` stamp |
| `SIGN_ID` | for distribution | `-` (ad-hoc) | Developer ID Application identity |
| `INSTALLER_SIGN_ID` | for `.pkg` distribution | _(none)_ | Developer ID Installer identity |
| `NOTARY_PROFILE` | for distribution | `JorvikNotary` | `xcrun notarytool` keychain profile |
| `OUT_DIR` | recommended | `$(CURDIR)/_BuildOutput` | Where artefacts land |

When `SIGN_ID` is `-` (the default for terminal use), notarisation is skipped — useful for local development. RM always exports a real identity.

## Targets exposed

| Target | Phase | Output |
|---|---|---|
| `release` | _default goal_ | Full pipeline. Produces `.zip` and/or `.pkg` in `$(OUT_DIR)`. |
| `build` | 1 | Compiles and bundles (`$(OUT_DIR)/$(PRODUCT_NAME)`). |
| `stamp` | 2 | Writes `VERSION`/`BUILD_NUMBER` into `Info.plist` (pre-sign). |
| `sign` | 3 | Codesigns nested frameworks then bundle. |
| `notarise` | 4 | Submits via `notarytool --wait`. Skipped for ad-hoc signing. |
| `staple` | 5 | Staples the notarisation ticket. |
| `package` | 6 | Dispatches to `package-zip`/`package-pkg`/both based on settings. |
| `package-zip` | 6a | Renames bundle to `$(INSTALL_NAME)`, ditto-zips, verifies. |
| `package-pkg` | 6b | pkgbuild + productsign + notarise + staple the .pkg. |
| `clean` | _utility_ | Removes the bundle, zip, pkg, and intermediate artefacts. |

## What `release.mk` handles automatically

- **Universal binaries** — every swiftc/xcode/spm build produces an `arm64 + x86_64` artefact via per-arch compile + `lipo` (or `xcodebuild ARCHS='arm64 x86_64'`).
- **JorvikKit** — `wildcard JorvikKit/*.swift` is appended to every swiftc compile (load-bearing — see SpaceMan v1.0.0 incident).
- **`generate_icon.swift`** — filtered out of the swiftc compile glob.
- **`Resources/`** — every file under `Resources/` (excluding the `*.iconset` intermediate) is copied into `Contents/Resources/`.
- **`xattr -cr`** — runs before every codesign to strip stray `com.apple.quarantine` attributes that would otherwise corrupt the signature.
- **Version stamp pre-sign** — `stamp` writes the plist before `sign`, so the signature covers the stamped values.
- **Sparkle framework recursion** — `helpers/sign-framework.sh` walks `Versions/<v>/{XPCServices,*.app, Mach-O helpers}` leaves-first then seals the framework root.
- **`installName` rename** — pre-zip and pre-pkg, the bundle is renamed if `INSTALL_NAME` differs from `PRODUCT_NAME`.
- **Dual-ship two notarisations** — when `PACKAGE_TYPE=zip ALSO_SHIP_PKG=true`, the bundle is notarised once (for the `.zip`), then the `.pkg` containing it is notarised separately.
- **`.pkg` postinstall** — `helpers/pkg-postinstall.sh.template` is materialised with `INSTALL_ROOT`/`PRODUCT_NAME`/`INSTALL_NAME` substitutions and embedded into the pkg, so installation handles installName relocation and quarantine strip.

## What it doesn't handle (RM keeps these)

- **Preflight** — cert availability, gh auth, notarytool keychain profile validation.
- **Independent verification** — RM runs `codesign -dvv`, `spctl --assess`, and `stapler validate` against the artefacts after `gmake release` finishes, cross-checked against the catalogue's `expectedEntitlements`.
- **Sparkle EdDSA appcast signing** — RM runs `sign_update` on the `.zip` and captures the structured signature + size into the appcast generator.
- **GitHub release upload** — `gh release create`, asset attachment, catalogue write-back of `lastBuiltZipURL` and `currentVersion`.

## Standalone use (without RM)

```bash
cd ~/Desktop/Jorvik\ Software/Reverie
gmake release VERSION=1.0.1 \
    SIGN_ID="Developer ID Application: Jonthan Hollin (EG86BCGUE7)" \
    INSTALLER_SIGN_ID="Developer ID Installer: Jonthan Hollin (EG86BCGUE7)" \
    NOTARY_PROFILE=JorvikNotary
```

Without `SIGN_ID`, the build is ad-hoc-signed and `notarise`/`staple` no-op — useful for local installation testing.

---

License: Public Domain. Do whatever you like with it.
