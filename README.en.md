# Pan's Desktop

[中文说明](README.md) · **1.0.0, Build 54** · MIT license

A transparent desktop partition app for macOS, written in Swift, SwiftUI, and AppKit with no third-party dependencies.

## Language

The interface follows your preferred system language: Chinese for Chinese language settings, and English otherwise. Menus, tooltips, search, dialogs, errors, and activity controls are available in both languages. Your existing partition names, file names, locations, and settings stay unchanged. Newly created default partitions use the selected language.

## Download and install

1. Open the [latest release](https://github.com/pws110/pans-desktop/releases/latest) and download `PansDesktop-v1.0.0-build54-macOS-arm64.zip`.
2. Extract it. Keep the **entire outer “Pan's Desktop” folder** in a writable location, such as Documents or `~/Applications/Pan's Desktop`. Do not move just the app into the system `/Applications` root: the clean portable app stores its data next to itself.
3. Open `Pan's Desktop.app` inside that folder. A fresh installation creates new default partitions.
4. Choose an **Import Mode** from each partition's **More (···)** menu. **Add References Only (Keep Originals)** preserves the original file locations. **Collect Files (Move, Undo Available)** moves files into the app's storage folder. Check the mode before adding your own files.

This download is for **Apple Silicon (M-series) Macs**. Its minimum build target is macOS 14; every supported macOS version has not been tested individually. Intel Macs need a separate build and validation.

The app uses a local ad-hoc signature. It has **no Apple Developer ID signature or Apple notarization**, so another Mac may show a system security warning. Verify the source and SHA256 checksums, or build from source. Do not disable system security protections.

## Features

- Transparent desktop partitions with independent locking, collapse/expand, search, and sorting.
- Expand in place to fit the number of files, and restore the previous size.
- Documents, images, and ordinary folders; each partition has its own import mode.
- Grid-aligned ordering and transfers between unlocked partitions.
- Move items into folders within unlocked partitions.
- Partitions stay at the desktop layer when you open a document. An expanded partition appears in front of other partitions.
- Large white PAN lettering on a red icon. The running app hides its Dock icon and remains accessible from its menu-bar menu.

A locked partition keeps its position and blocks moving, adding, and removing files. Opening, previewing, collapsing, expanding, and restoring its size remain available. Unlock only the partitions involved in a move.

## Data and updates

The clean portable app stores `Configuration`, `收纳文件` (collected files), and `TestFiles` next to the app. These directory names remain stable across languages to preserve existing data locations.

Before updating, quit the app and back up its entire outer folder. Replace only the app, keeping the data folders. Existing installations that use a private data-location connection need an update that preserves that connection; a clean public package does not include it.

References depend on the original files. Downloading this software onto another Mac does not copy your documents or reconnect paths from the old computer automatically. Back up and migrate personal data separately.

To start automatically after login, add the actual app you use under **System Settings → General → Login Items & Extensions → Open at Login**. This is a per-computer setting.

## Build from source

Install Xcode or Apple Command Line Tools, then run:

```sh
./scripts/build.sh
```

The default output is `_build.noindex/`; the script does not install or launch the app and does not change existing partition settings. Use `MACOS_SDK` to select a matching SDK, or `ARCH=x86_64` for a separate Intel build. The published binary has only been validated on Apple Silicon.

```sh
./scripts/test-model.sh
./scripts/test-localization.sh
```

These checks create temporary test files. Additional interaction tests are in `Tests/`; tests that operate a real desktop require explicit test setup and are not run by the build script.

## Public package contents

Only software, source, icon assets, synthetic tests, and documentation are published. No personal documents, private partition settings, original-file path lists, activity logs, or same-Mac reinstall packages are included.

Release downloads include `SHA256SUMS.txt` for checking integrity. Keep personal backups private.
