# PhotoViewer

Adobe Bridge の代わりに使う、軽量な macOS 用の写真閲覧アプリ（SwiftUI）。

![画面](docs/screenshot.jpg)

## できること
- フォルダツリー（リスト／アイコン表示）とサムネイルグリッド（サイズ指定／列数指定）
- プレビューと撮影情報（撮影日・ISO・F 値・シャッタースピード・焦点距離・カメラ・レンズ）
- GPS：緯度経度のコピー、Google マップ・地理院地図で開く
- レーティング（★1〜5・リジェクト）と「現像済み」チェック。XMP サイドカーに保存する（RAW なら Bridge・Lightroom でも同じ★が見える）
- 検索・絞り込み：ファイル名・カメラ・レンズのフリーワード、拡張子、レーティング、現像済み、撮影日・カメラ・レンズ・ISO・F 値・SS・焦点距離の範囲、位置情報の有無
- 並べ替え：ファイル名・撮影日・更新日・レーティング・サイズ
- 拡張子ごとに、ダブルクリックで開くアプリを環境設定で指定
- ファイル名の一括変更（連番・撮影日時など。RAW＋JPEG ペアとサイドカーも一緒に変更し、⌘Z で取り消せる）
- Quick Look（Space）、ゴミ箱へ（⌘⌫、⌘Z で戻せる）、フォルダの変更の自動反映

## キー操作
| キー | 動作 |
|------|------|
| 矢印キー | 選択の移動（⇧ で範囲選択） |
| Return／ダブルクリック／⌘O | 指定のアプリで開く |
| Space | Quick Look |
| 0〜5 | レーティング（⌘0〜⌘5 でも可） |
| ⌥⌫ | リジェクト |
| D（⇧⌘D） | 現像済みの切り替え |
| ⇧⌘R | 名前の一括変更 |
| ⌘⌫ | ゴミ箱に入れる |
| ⌘Z | 一括変更・ゴミ箱の取り消し |
| ⌘R | 再読み込み |
| ⇧⌘O | フォルダを開く |
| ⌃⌘S／⌃⌘I | サイドバー／右列の開閉 |
| ⌘, | 環境設定 |

## ビルド
```bash
brew install xcodegen
xcodegen generate
xcodebuild -project PhotoViewer.xcodeproj -scheme PhotoViewer -configuration Release -derivedDataPath build build
open build/Build/Products/Release/PhotoViewer.app
```

詳しくは `開発計画書.md`、`開発履歴.md`、`CLAUDE.md` を参照。
