#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="${1:-$project_root/_build.noindex}"
target_arch="${ARCH:-arm64}"
sdk_path="${MACOS_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
compiler="${SWIFTC:-$(xcrun --find swiftc)}"
release_name="PansDesktop-v1.0.0-build53-macOS-$target_arch.zip"
runtime="$output_root/Pan's Desktop"
app="$runtime/Pan's Desktop.app"

case "$target_arch" in arm64|x86_64) ;; *) echo "ARCH must be arm64 or x86_64" >&2; exit 1 ;; esac
if [[ -e "$runtime" || -e "$output_root/$release_name" ]]; then
  echo "Output already exists. Choose a new output folder; existing app/data will not be overwritten." >&2
  exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$output_root/module-cache"
"$compiler" -O -swift-version 5 -target "$target_arch-apple-macos14.0" \
  -sdk "$sdk_path" -module-cache-path "$output_root/module-cache" \
  -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers \
  -framework QuickLookUI -framework ImageIO \
  "$project_root/Sources/DataHome.swift" "$project_root/Sources/Model.swift" "$project_root/Sources/Storage.swift" \
  "$project_root/Sources/CopyExport.swift" "$project_root/Sources/MoveActions.swift" \
  "$project_root/Sources/PartitionActions.swift" "$project_root/Sources/main.swift" \
  -o "$app/Contents/MacOS/PansDesktop"
cp "$project_root/Sources/Info.plist" "$app/Contents/Info.plist"
cp "$project_root/Assets/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$project_root/LICENSE" "$runtime/LICENSE.txt"
cp "$project_root/README.md" "$runtime/先读我.md"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
python3 "$project_root/scripts/package.py" "$runtime" "$output_root/$release_name"
(cd "$output_root" && shasum -a 256 "$release_name" > SHA256SUMS.txt)
echo "Created $output_root/$release_name"
echo "Build only: no app launched or installed, no existing partition data changed."
