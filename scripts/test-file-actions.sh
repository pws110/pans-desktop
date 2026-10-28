#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="${1:?Pass a fresh isolated test output folder}"
test_app="$output_root/NativeChecks.app"
test_main="$output_root/main.swift"
[[ ! -e "$output_root" ]] || { echo 'Choose a new test output folder'; exit 1; }
mkdir -p "$test_app/Contents/MacOS" "$output_root/module-cache"
python3 - "$project_root" "$test_main" "$test_app" <<'PY'
import pathlib,sys,plistlib
p=pathlib.Path(sys.argv[1]); output=pathlib.Path(sys.argv[2]); app=pathlib.Path(sys.argv[3])
source=(p/'Sources/main.swift').read_text().split('func bootTrace(_ message: String)')[0]
output.write_text(source+'\n'+(p/'Tests/FileActionsTests/Checks.swift').read_text())
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.andy.pansdesktop.file-actions-check','CFBundleExecutable':'NativeChecks','CFBundleName':'Pan Tests','LSUIElement':True,'PansDesktopDisableAppHidingForTests':True}))
PY
compiler="${SWIFTC:-$(xcrun --find swiftc)}"
sdk_path="${MACOS_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
"$compiler" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$sdk_path" -module-cache-path "$output_root/module-cache" \
  -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework QuickLookUI -framework ImageIO \
  "$project_root/Sources/DataHome.swift" "$project_root/Sources/Localization.swift" "$project_root/Sources/Model.swift" "$project_root/Sources/Storage.swift" \
  "$project_root/Sources/CopyExport.swift" "$project_root/Sources/MoveActions.swift" "$project_root/Sources/PartitionActions.swift" \
  "$project_root/Sources/FileActions.swift" "$project_root/Sources/FileActionsUI.swift" "$test_main" -o "$test_app/Contents/MacOS/NativeChecks"
PANS_DESKTOP_QA_ROOT="$output_root" "$test_app/Contents/MacOS/NativeChecks"
