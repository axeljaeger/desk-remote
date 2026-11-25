#!/bin/sh
set -eu

companion_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir="$companion_dir/build"
app_dir="${1:-$build_dir/Tab5Companion.app}"
mkdir -p "$app_dir/Contents/MacOS" "$build_dir/module-cache"
object_dir=$(mktemp -d "$build_dir/.objects.XXXXXX")
trap 'rm -rf "$object_dir"' EXIT

clang -arch "$(uname -m)" -mmacosx-version-min=13.0 -c "$companion_dir/ExclusivePort.c" \
  -o "$object_dir/ExclusivePort.o"
swiftc -O -module-cache-path "$build_dir/module-cache" \
  -target "$(uname -m)-apple-macosx13.0" \
  -import-objc-header "$companion_dir/ExclusivePort.h" \
  "$companion_dir"/*.swift "$object_dir/ExclusivePort.o" -o "$app_dir/Contents/MacOS/Tab5Companion"
cp "$companion_dir/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --sign "${PRO_REMOTE_SIGN_IDENTITY:--}" "$app_dir"
codesign --verify --strict "$app_dir"
printf '%s\n' "$app_dir"
