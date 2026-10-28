#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="${1:?Pass a fresh isolated test output folder}"
[[ ! -e "$output_root" ]] || { echo 'Choose a new test output folder'; exit 1; }
mkdir -p "$output_root/HoverChecks.app/Contents/MacOS" "$output_root/module-cache"
python3 - "$project_root" "$output_root" <<'PY'
import pathlib,sys,plistlib

p=pathlib.Path(sys.argv[1]); out=pathlib.Path(sys.argv[2])
build=plistlib.loads((p/'Sources/Info.plist').read_bytes())['CFBundleVersion']
source=(p/'Sources/main.swift').read_text().split('func bootTrace(_ message: String)')[0]
(out/'main.swift').write_text(source+'\n'+(p/'Tests/HoverDesktopTests/Checks.swift').read_text())
(out/'HoverChecks.app/Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.andy.pansdesktop.hover-checks.build'+build,'CFBundleExecutable':'HoverChecks','CFBundleName':'Pan Hover Checks','LSUIElement':True,'PansDesktopDisableAppHidingForTests':True}))
PY
compiler="${SWIFTC:-$(xcrun --find swiftc)}"
sdk_path="${MACOS_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
"$compiler" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$sdk_path" -module-cache-path "$output_root/module-cache" \
  -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework QuickLookUI -framework ImageIO \
  "$project_root/Sources/DataHome.swift" "$project_root/Sources/Localization.swift" "$project_root/Sources/Model.swift" "$project_root/Sources/Storage.swift" \
  "$project_root/Sources/CopyExport.swift" "$project_root/Sources/MoveActions.swift" "$project_root/Sources/PartitionActions.swift" \
  "$project_root/Sources/FileActions.swift" "$project_root/Sources/FileActionsUI.swift" "$output_root/main.swift" -o "$output_root/HoverChecks.app/Contents/MacOS/HoverChecks"
codesign --force --sign - "$output_root/HoverChecks.app"
echo "Built $output_root/HoverChecks.app; launch it normally to run isolated AppKit checks. Results are written beside the app."
