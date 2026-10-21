#!/bin/zsh
# レガシー版のビルド・テスト（Xcode 16.4 を使う）
#   ./Legacy/Scripts/build.sh          Debug ビルド
#   ./Legacy/Scripts/build.sh test     テスト（この Mac では Rosetta 2 で動く）
#   ./Legacy/Scripts/build.sh release  Release ビルド → dist/PhotoViewer Legacy.app
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
xcodegen generate --quiet
COMMON=(-project PhotoViewerLegacy.xcodeproj -scheme PhotoViewerLegacy -derivedDataPath build -allowProvisioningUpdates)
case "${1:-build}" in
  test)
    xcodebuild "${COMMON[@]}" -destination 'platform=macOS,arch=x86_64' test ;;
  release)
    xcodebuild "${COMMON[@]}" -configuration Release -destination 'generic/platform=macOS' build
    APP="build/Build/Products/Release/PhotoViewer Legacy.app"
    mkdir -p ../dist
    pkill -x "PhotoViewer Legacy" 2>/dev/null || true
    rm -rf "../dist/PhotoViewer Legacy.app"
    ditto "$APP" "../dist/PhotoViewer Legacy.app"
    echo "作成しました: dist/PhotoViewer Legacy.app" ;;
  *)
    xcodebuild "${COMMON[@]}" -destination 'platform=macOS,arch=x86_64' build ;;
esac
