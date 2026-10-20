#!/bin/zsh
# 配布用 DMG を作る
# 使い方: ./Scripts/build_dmg.sh
# 中身：PhotoViewer.app、Applications へのリンク、かんたんインストーラ.scpt
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/build_dist.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" dist/PhotoViewer.app/Contents/Info.plist)
NAME="PhotoViewer-${VERSION}"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

ditto dist/PhotoViewer.app "$STAGE/PhotoViewer.app"
ln -s /Applications "$STAGE/Applications"
osacompile -o "$STAGE/かんたんインストーラ.scpt" "Scripts/installer/かんたんインストーラ.applescript"

rm -f "dist/${NAME}.dmg"
hdiutil create -volname "PhotoViewer ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "dist/${NAME}.dmg" -quiet
hdiutil verify "dist/${NAME}.dmg" -quiet
echo "作成しました: dist/${NAME}.dmg（$(du -h "dist/${NAME}.dmg" | cut -f1)）"
