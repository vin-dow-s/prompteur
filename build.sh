#!/bin/sh
# Builds Prompteur.app.
#
#   sh build.sh                      the demo script built in
#   sh build.sh path/to/script.md    your own script built in (.md or .json)
#
# OUT sets where the app goes (build/Prompteur.app by default) and BUNDLE_ID
# its identifier, which is also where its settings are kept.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="${OUT:-$here/build/Prompteur.app}"
id="${BUNDLE_ID:-local.prompteur}"
script="${1:-$here/examples/demo.md}"

mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
# Built for macOS 13 and later, as the Info.plist below says: without a
# target, swiftc builds for the version of macOS it runs on and no older one.
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos13.0" \
  "$here/Sources/main.swift" -o "$out/Contents/MacOS/Prompteur"

cat > "$out/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Prompteur</string>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleExecutable</key><string>Prompteur</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

rm -f "$out/Contents/Resources/script.md" "$out/Contents/Resources/script.json"
case "$script" in
  *.json) cp "$script" "$out/Contents/Resources/script.json" ;;
  *) cp "$script" "$out/Contents/Resources/script.md" ;;
esac

# An ad hoc signature, so macOS runs a build that never left this Mac.
codesign --force --sign - "$out" 2>/dev/null || echo "Warning: could not sign $out" >&2
echo "Built $out"
echo "Open it with: open \"$out\""
