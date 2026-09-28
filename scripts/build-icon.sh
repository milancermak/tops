#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

source_icon="$PWD/assets/AppIcon.png"
iconset_dir="$PWD/.build/AppIcon.iconset"
rendered_icon="$PWD/.build/AppIcon-macOS.png"

[[ -f "$source_icon" ]] || { echo 'Missing assets/AppIcon.png.' >&2; exit 1; }
read -r width height < <(sips -g pixelWidth -g pixelHeight "$source_icon" | awk '/pixelWidth:/ { width = $2 } /pixelHeight:/ { print width, $2 }')
if [[ "$width" != "$height" || "$width" -lt 1024 ]]; then
  echo 'assets/AppIcon.png must be square and at least 1024 pixels wide.' >&2
  exit 1
fi

mkdir -p "$iconset_dir"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-cache}"
swift scripts/render-icon.swift "$source_icon" "$rendered_icon"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$rendered_icon" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$rendered_icon" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$PWD/.build/AppIcon.icns"
