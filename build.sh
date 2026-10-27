#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="${SHIGUANG_BUILD_DIR:-$project_dir/.build}"
output_dir="${SHIGUANG_OUTPUT_DIR:-$project_dir/dist}"
configuration="${SHIGUANG_CONFIGURATION:-release}"
mkdir -p "$build_dir" "$output_dir"
runtime_dir="$(python3 "$project_dir/tools/prepare-toolchain.py" "$build_dir")"
if [[ -n "$runtime_dir" ]]; then
  export SWIFTPM_CUSTOM_LIBS_DIR="$runtime_dir"
  export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/manifest-cache"
fi
swift build --package-path "$project_dir" --scratch-path "$build_dir" -c "$configuration" --product Shiguang
binary_dir="$(swift build --package-path "$project_dir" --scratch-path "$build_dir" -c "$configuration" --show-bin-path)"
app_dir="$output_dir/拾光.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/Shiguang" "$app_dir/Contents/MacOS/Shiguang"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp -R "$project_dir/Licenses" "$app_dir/Contents/Resources/"
cp -R "$project_dir/Resources/en.lproj" "$project_dir/Resources/zh-Hans.lproj" "$app_dir/Contents/Resources/"
cp -R "$binary_dir/Shiguang_DiaryCore.bundle" "$app_dir/Contents/Resources/"
if [[ ! -f "$project_dir/Resources/AppIcon.icns" ]]; then
  xcrun swift "$project_dir/tools/make-icon.swift" "$build_dir/AppIcon.png"
  icon_dir="$build_dir/AppIcon.iconset"
  mkdir -p "$icon_dir"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$build_dir/AppIcon.png" --out "$icon_dir/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$build_dir/AppIcon.png" --out "$icon_dir/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$icon_dir" -o "$project_dir/Resources/AppIcon.icns"
fi
cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/"
if [[ "$configuration" == "debug" ]]; then
  codesign --force --sign - "$app_dir"
else
  codesign --force --options runtime --entitlements "$project_dir/Resources/Shiguang.entitlements" --sign - "$app_dir"
fi
codesign --verify --deep --strict "$app_dir"
printf '%s\n' "$app_dir"
