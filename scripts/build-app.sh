#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo 'Expected debug or release' >&2; exit 2;; esac
architecture="${2:-native}"
build_arguments=(-c "$configuration")
case "$architecture" in
  native) ;;
  universal) build_arguments+=(--arch arm64 --arch x86_64) ;;
  *) echo 'Expected native or universal' >&2; exit 2;;
esac
swift build "${build_arguments[@]}"
binary_directory="$(swift build "${build_arguments[@]}" --show-bin-path)"
bundle="${3:-artifacts/拷卡.app}"
case "$bundle" in
  artifacts/*.app) ;;
  *) echo 'Bundle output must be an .app under artifacts/' >&2; exit 2;;
esac
mkdir -p "$bundle/Contents/MacOS"
cp "$binary_directory/CopyCard" "$bundle/Contents/MacOS/CopyCard"
cp scripts/Info.plist "$bundle/Contents/Info.plist"
mkdir -p "$bundle/Contents/Resources"
swiftc Sources/CopyApp/System/AppIcon.swift scripts/render-icon.swift -o artifacts/icon-renderer
artifacts/icon-renderer artifacts/CopyCard.iconset
iconutil -c icns artifacts/CopyCard.iconset -o "$bundle/Contents/Resources/CopyCard.icns"
build_id="$(shasum -a 256 "$binary_directory/CopyCard" | awk '{print $1}')"
plutil -insert CopyCardBuildID -string "$build_id" "$bundle/Contents/Info.plist"
signing_identity="${COPYCARD_SIGNING_IDENTITY:--}"
codesign --force --sign "$signing_identity" "$bundle"
plutil -lint "$bundle/Contents/Info.plist"
lipo -archs "$bundle/Contents/MacOS/CopyCard"
echo "$PWD/$bundle"
