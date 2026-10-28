#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/pans-grid-check.XXXXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
sdk_path="${MACOS_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
"${SWIFTC:-$(xcrun --find swiftc)}" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$sdk_path" -module-cache-path "$test_root/module-cache" -framework AppKit -framework UniformTypeIdentifiers "$project_root/Sources/Localization.swift" "$project_root/Sources/Model.swift" "$project_root/Tests/GridGeometryTests/main.swift" -o "$test_root/checks"
"$test_root/checks"
