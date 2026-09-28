#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == "--skip-engine" ]]; then
  [[ -x engine/target/release/tops-engine ]] || { echo 'Build the Rust engine first.' >&2; exit 1; }
elif [[ -z "${1:-}" ]]; then
  cargo build --locked --release --manifest-path engine/Cargo.toml
else
  echo 'Usage: scripts/build-app.sh [--skip-engine]' >&2
  exit 1
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox --cache-path .build/swiftpm-cache
./scripts/build-icon.sh
app_dir="$PWD/dist/Tops.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp .build/release/Tops "$app_dir/Contents/MacOS/Tops"
cp engine/target/release/tops-engine "$app_dir/Contents/Resources/tops-engine"
cp config/operations.json "$app_dir/Contents/Resources/operations.json"
cp .build/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Tops</string>
<key>CFBundleIdentifier</key><string>local.tops.player</string>
<key>CFBundleName</key><string>Tops</string>
<key>CFBundleDisplayName</key><string>Tops</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSEnvironment</key><dict>
<key>MallocSpaceEfficient</key><string>1</string>
</dict>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir/Contents/Resources/tops-engine"
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
touch "$app_dir"
echo "Built $app_dir"
