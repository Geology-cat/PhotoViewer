# CLAUDE.md — PhotoViewer 開発ガイド

Adobe Bridge の代わりに使う、軽量な macOS 用写真閲覧アプリ（SwiftUI）。
仕様は `作成案.md`、設計と進め方は `開発計画書.md`、作業の記録は `開発履歴.md` を参照する。

## 基本ルール
- やり取り・コメント・ドキュメント・コミットメッセージはすべて日本語。
- **軽量であることが最優先**。重い処理（画像デコード、EXIF 読み込み、ファイル操作）は必ずメインスレッドの外で行う。
- 外部ライブラリは使わない（OS 標準フレームワークのみ）。
- 作業の区切りごとに `開発履歴.md` に追記し、コミットして GitHub に push する。

## ビルド・テスト
Xcode プロジェクトは XcodeGen で `project.yml` から生成する（`*.xcodeproj` は git 管理外）。
**ファイルを追加・削除したら必ず `xcodegen generate` を再実行する**。

```bash
xcodegen generate
xcodebuild -project PhotoViewer.xcodeproj -scheme PhotoViewer -derivedDataPath build -destination 'platform=macOS' build
xcodebuild -project PhotoViewer.xcodeproj -scheme PhotoViewer -derivedDataPath build -destination 'platform=macOS' test
open build/Build/Products/Debug/PhotoViewer.app
```

テスト用の写真は `swift Scripts/generate_testdata.swift TestData` で生成する（`TestData/` は git 管理外）。

## 技術的な決定事項
| 項目 | 決定 |
|------|------|
| 最低対応 OS | macOS 15 |
| Swift | Swift 6 / Strict Concurrency complete / 既定のアクター分離は `nonisolated` |
| サンドボックス | 使わない（`ENABLE_APP_SANDBOX: NO`） |
| サムネイルグリッド | `NSCollectionView` を `NSViewRepresentable` でラップ（複数選択・キー操作・性能のため） |
| サムネイル生成 | ImageIO `CGImageSourceCreateThumbnailAtIndex`。RAW は埋め込みプレビューを使う |
| レーティング・現像済み | XMP サイドカー（`<ベース名>.xmp`）。RAW と JPEG の同名ペアは同じサイドカーを共有する |
| レーティングの項目 | `xmp:Rating`（-1 = リジェクト、0〜5） |
| 現像済みの項目 | 独自名前空間 `pv:Developed`（`https://github.com/Geology-cat/PhotoViewer/ns/1.0/`） |
| 検索 | ファイル名・カメラ・レンズのフリーワード＋撮影日・撮影条件などの詳細条件 |
| バッチリネーム | 同名の `.xmp` と RAW＋JPEG ペアも一緒に変更する（オプションでオフ可） |

## コード構成
```
PhotoViewer/
  App/        アプリのエントリポイント、メニューコマンド
  Models/     PhotoItem、PhotoMetadata などの値型
  Services/   フォルダ走査、サムネイル、メタデータ、XMP、リネームなど（UI に依存しない）
  State/      @Observable な画面状態・設定
  Views/      SwiftUI ビュー（Sidebar / Grid / Inspector / Settings）
PhotoViewerTests/  Swift Testing によるユニットテスト
Scripts/           テストデータ生成などの補助スクリプト
```

## 並行処理の注意
- UI に関わる型（`@Observable` の状態クラス、ビュー）は `@MainActor` を明示する。
- 画像デコード・メタデータ読み込みは `nonisolated` な関数で行い、`Task.detached` などでバックグラウンド実行する。
- アクター境界をまたいで渡すのは `CGImage`（Sendable）にし、`NSImage` はメインアクター上で作る。

## ImageIO の注意
- サムネイル生成時は `kCGImageSourceCreateThumbnailWithTransform: true`（縦位置写真の向き）と `kCGImageSourceShouldCacheImmediately: true` を指定する。
- ソース作成時は `kCGImageSourceShouldCache: false`。
- `...FromImageIfAbsent` は小さな EXIF サムネイルを返すことがある。要求サイズより極端に小さければ、RAW 以外は `...FromImageAlways` で作り直す。

## Git
- リポジトリ：GitHub `Geology-cat/PhotoViewer`（private）
- コミットメッセージは日本語。末尾に `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` を付ける。
