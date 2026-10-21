#!/bin/zsh
# レガシー版（macOS 10.12 向け）の配布用 DMG を作る
# 使い方: ./Legacy/Scripts/build_dmg.sh
# 中身：PhotoViewer Legacy.app、Applications へのリンク、かんたんインストーラ（.scpt と、文字のままの .applescript）
# 10.12 は APFS のディスクイメージを開けないので、HFS+ で作る
set -euo pipefail
cd "$(dirname "$0")/../.."

./Legacy/Scripts/build.sh release

APP="dist/PhotoViewer Legacy.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
NAME="PhotoViewerLegacy-${VERSION}"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/PhotoViewer Legacy.app"
ln -s /Applications "$STAGE/Applications"
osacompile -o "$STAGE/かんたんインストーラ.scpt" "Legacy/Scripts/installer/かんたんインストーラ.applescript"
# 新しい macOS で作った .scpt を古いスクリプトエディタで開けない場合に備えて、文字のままの版も入れる
cp "Legacy/Scripts/installer/かんたんインストーラ.applescript" "$STAGE/かんたんインストーラ（開けないとき用）.applescript"

rm -f "dist/${NAME}.dmg"
hdiutil create -volname "PhotoViewer Legacy ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "dist/${NAME}.dmg" -quiet
hdiutil verify "dist/${NAME}.dmg" -quiet
echo "作成しました: dist/${NAME}.dmg（$(du -h "dist/${NAME}.dmg" | cut -f1)）"
