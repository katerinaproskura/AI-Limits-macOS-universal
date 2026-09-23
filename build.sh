#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
build_dir="$project_dir/build"
app_dir="$build_dir/AI Limits.app"

mkdir -p "$app_dir/Contents/MacOS"
/usr/bin/swiftc "$project_dir/Sources/main.swift" \
  -O \
  -framework AppKit \
  -framework Foundation \
  -framework Security \
  -o "$app_dir/Contents/MacOS/LimitLens"

cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$app_dir"
echo "$app_dir"

