#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test
bash scripts/build-app.sh release universal
codesign --verify --deep --strict --verbose=2 artifacts/拷卡.app
plutil -lint artifacts/拷卡.app/Contents/Info.plist
lipo artifacts/拷卡.app/Contents/MacOS/CopyCard -verify_arch arm64 x86_64
echo 'Tests, universal build, bundle metadata and local code signature verified.'
echo 'This does not validate Intel hardware, external media, live AI APIs or Apple notarization.'
