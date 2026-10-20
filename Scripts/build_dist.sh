#!/bin/zsh
# Release ビルドを作り、dist/PhotoViewer.app に置く
# 使い方: ./Scripts/build_dist.sh
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate -q
xcodebuild -project PhotoViewer.xcodeproj -scheme PhotoViewer -configuration Release \
    -derivedDataPath build -destination 'platform=macOS,arch=arm64' -allowProvisioningUpdates -quiet build

# 起動中なら終了してから置き換える
if pgrep -x PhotoViewer >/dev/null; then
    osascript -e 'tell application id "com.geologycat.PhotoViewer" to quit' || true
    sleep 1
fi
rm -rf dist/PhotoViewer.app
mkdir -p dist
ditto build/Build/Products/Release/PhotoViewer.app dist/PhotoViewer.app

echo "作成しました: dist/PhotoViewer.app"
codesign -dv dist/PhotoViewer.app 2>&1 | grep -E "Authority=|TeamIdentifier=" | head -2
