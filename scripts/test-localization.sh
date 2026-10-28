#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
sdk_path="${MACOS_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
compiler="${SWIFTC:-$(xcrun --find swiftc)}"
target_arch="${ARCH:-$(uname -m)}"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/pans-desktop-language-check.XXXXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
"$compiler" -swift-version 5 -target "$target_arch-apple-macos14.0" \
  -sdk "$sdk_path" -module-cache-path "$test_root/module-cache" \
  -framework UniformTypeIdentifiers -framework AppKit \
  "$project_root/Sources/Localization.swift" "$project_root/Sources/DataHome.swift" \
  "$project_root/Sources/Model.swift" "$project_root/Sources/Storage.swift" \
  "$project_root/Sources/CopyExport.swift" "$project_root/Sources/MoveActions.swift" "$project_root/Sources/FileActions.swift" \
  "$project_root/Tests/LocalizationTests/main.swift" -o "$test_root/language-tests"
PANS_DESKTOP_TEST_LANGUAGE=en "$test_root/language-tests"
PANS_DESKTOP_TEST_LANGUAGE=zh-Hans "$test_root/language-tests"
