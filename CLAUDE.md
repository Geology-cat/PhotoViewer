# CLAUDE.md — PhotoViewer 開発ガイド

Adobe Bridge の代わりに使う、軽量な macOS 用写真閲覧アプリ（SwiftUI）。
仕様は `作成案.md`、設計と進め方は `開発計画書.md`、作業の記録は `開発履歴.md` を参照する。

## 基本ルール
- やり取り・コメント・ドキュメント・コミットメッセージはすべて日本語。
- **コードを更新したら、必ず `./Scripts/build_dist.sh` を実行して `dist/PhotoViewer.app` を作り直す**（ユーザーはこの app を使う。`dist/` は git 管理外）。
- **軽量であることが最優先**。重い処理（画像デコード、EXIF 読み込み、ファイル操作）は必ずメインスレッドの外で行う。
- 外部ライブラリは使わない（OS 標準フレームワークのみ）。
- 作業の区切りごとに `開発履歴.md` に追記し、コミットして GitHub に push する。

## 配布用 app（dist）
```bash
./Scripts/build_dist.sh   # Release ビルド → dist/PhotoViewer.app（起動中なら終了してから置き換える）
```

## リリース（DMG）
```bash
./Scripts/build_dmg.sh   # dist/PhotoViewer-<バージョン>.dmg を作る（中身：app・Applications へのリンク・かんたんインストーラ.scpt）
```
- バージョンは `project.yml` の `MARKETING_VERSION`。
- インストーラの元は `Scripts/installer/かんたんインストーラ.applescript`（osacompile で .scpt にして同梱）。
- GitHub リリース：`gh release create v<バージョン> dist/PhotoViewer-<バージョン>.dmg`。
- 署名は Apple Development（Developer ID ではなく公証もしていない）なので、配布先では隔離属性の削除が必要。インストーラがこれを行う。

## ビルド・テスト
Xcode プロジェクトは XcodeGen で `project.yml` から生成する（`*.xcodeproj` は git 管理外）。
**ファイルを追加・削除したら必ず `xcodegen generate` を再実行する**。

```bash
xcodegen generate
xcodebuild -project PhotoViewer.xcodeproj -scheme PhotoViewer -derivedDataPath build -destination 'platform=macOS' build
xcodebuild -project PhotoViewer.xcodeproj -scheme PhotoViewer -derivedDataPath build -destination 'platform=macOS' test
open build/Build/Products/Debug/PhotoViewer.app
```

テスト用の写真は `swift Scripts/generate_testdata.swift ~/Library/Caches/PhotoViewerTestData` で生成する。
`TestData` はそこへのシンボリックリンク（git 管理外）。
- デスクトップ配下はアクセス許可（TCC）の対象。以前の ad-hoc 署名ではビルドのたびに許可ダイアログが出て読み込みが止まったため、テストデータはデスクトップの外に置いている。
- 外付け HDD（/Volumes/LaCie_d2）の実写真は**読み取り専用**で性能確認に使う。レーティングやリネームなどの書き込みテストは必ず TestData で行う。
- 性能計測：`PV_PERF=1 build/Build/Products/Debug/PhotoViewer.app/Contents/MacOS/PhotoViewer` で起動すると、最初のサムネイルが出るまでの時間を標準エラー出力に出す。
- 止まりの調査：`PV_HANGCHECK=1` で起動すると、メインスレッドが 100ms 以上止まるたびに標準エラー出力に記録する（`PV_HANGCHECK_DIR=<フォルダ>` を付けると、そのときの呼び出し履歴を `sample` で保存する）。
- 負荷試験：`PV_STRESS=1 PV_STRESS_FOLDERS=<フォルダ:フォルダ…>` で起動すると、スクロール・並べ替え・検索・絞り込み・右列の開閉・戻る/進むなどを自動で繰り返して終了する。★の連続書き込みは `PV_STRESS_WRITE=<TestData のフォルダ>` を指定したときだけ行う。設定（UserDefaults）を書き換えるので、事前に `defaults export com.geologycat.PhotoViewer` で控えて、終わったら戻す。
- `contentsOfDirectory` などで得た URL は中身が NSURL のままで、辞書のキーや比較に使うと日本語のパスでは非常に遅い。`PhotoItem` は `swiftNative(isDirectory:)` で作り直した URL を持つ。

## レガシー版（macOS 10.12 向け、`Legacy/`）
仕様と方針は `レガシー版開発計画書.md`。通常版と同じ機能を AppKit だけで作った別アプリ（PhotoViewer Legacy、`com.geologycat.PhotoViewerLegacy`）。
```bash
./Legacy/Scripts/build.sh            # Debug ビルド（Xcode 16.4 を使う。Xcode 27 は 10.12 向けにビルドできない）
./Legacy/Scripts/build.sh test       # テスト（この Mac では Rosetta 2 で動く）
./Legacy/Scripts/build.sh release    # dist/PhotoViewer Legacy.app
./Legacy/Scripts/build_dmg.sh        # dist/PhotoViewerLegacy-<バージョン>.dmg（HFS+。10.12 は APFS の DMG を開けない）
```
- **処理部分は通常版のファイルを共有する**（`Legacy/project.yml` の sources を参照）。共有ファイルでは、10.12 で使えないもの（async/await・actor・`MainActor`・CryptoKit・UTType・新しい FileHandle API など）を使わないか、`#if LEGACY` / `#available` で切り替える。共有ファイルを変えたら両方をビルドする。
- 共有している主なもの：Models、FolderScanner、PhotoFilter、RenameService、TIFFCompositeReader、MetadataReader、XMPSidecar、ThumbnailDiskCache、ThumbnailLoader、VideoSupport、DirectoryEventWatcher、GridSettings、`Views/Grid/GridComponents.swift`（グリッドの並べ方・クリック・キー操作・Quick Look）、`Views/Inspector/PreviewGeometry.swift`（拡大・回転の計算）。
- レガシー版だけのもの：`BrowserModel`（状態。変更は NotificationCenter で知らせる）、GCD 版の読み込み（`LegacyLoaders.swift`）、AppKit の画面、コードで描いたアイコン（`LegacyIcons`。SF Symbols は 11 以降）。
- 自動の動作確認：`PV_SELFTEST=<画像の保存先> PV_SELFTEST_FOLDER=<TestData/基本> PV_SELFTEST_VIDEO=<TestData/動画> "Legacy/build/Build/Products/Debug/PhotoViewer Legacy.app/Contents/MacOS/PhotoViewer Legacy"`。マウス・キーのイベントを送って結果を標準エラー出力に書き、場面ごとの画面を保存する（★の書き込みは TestData で行い元に戻す）。普通のクリックだけは、テスト環境では OS の選択処理が働かないため不合格になる（実機で確認する）。
- 予備：Xcode 13.4.1（`~/Library/Developer/Xcode13/Xcode.app`、10.12 を正式に扱える最後の版）もこの Mac で動く。ただし Swift 5.6 なので、共有コードの新しい書き方（switch 式など）はそのままではビルドできない。

## 技術的な決定事項
| 項目 | 決定 |
|------|------|
| 最低対応 OS | macOS 15 |
| 署名 | Apple Development（Personal Team `BT5MH5A8GY`、自動署名）。xcodebuild には `-allowProvisioningUpdates` を付ける |
| アプリアイコン | Codex の画像生成で作った `docs/icon_source.png` を `swift Scripts/generate_icon.swift docs/icon_source.png PhotoViewer/Resources/Assets.xcassets/AppIcon.appiconset` で角丸・各サイズに加工 |
| Swift | Swift 6 / Strict Concurrency complete / 既定のアクター分離は `nonisolated` |
| サンドボックス | 使わない（`ENABLE_APP_SANDBOX: NO`） |
| サムネイルグリッド | `NSCollectionView` を `NSViewRepresentable` でラップ（複数選択・キー操作・性能のため） |
| サムネイル生成 | ImageIO `CGImageSourceCreateThumbnailAtIndex`。RAW は埋め込みプレビューを使う |
| レーティング・現像済み | XMP サイドカー（`<ベース名>.xmp`）。RAW と JPEG の同名ペアは同じサイドカーを共有する |
| レーティングの項目 | `xmp:Rating`（-1 = リジェクト、0〜5） |
| 現像済みの項目 | 独自名前空間 `pv:Developed`（`https://github.com/Geology-cat/PhotoViewer/ns/1.0/`） |
| 検索 | ファイル名・カメラ・レンズのフリーワード＋撮影日・撮影条件などの詳細条件 |
| バッチリネーム | 同名の `.xmp` と RAW＋JPEG ペアも一緒に変更する（オプションでオフ可） |
| 大きな TIF | `TIFFCompositeReader` で必要な部分だけ読む（ImageIO はレイヤー情報を含むファイル全体を読むため）。無圧縮ならサムネイルは行を飛び飛びに読む。撮影情報はタグだけ読む |
| ディスクキャッシュ | 20MB 以上で読むのに 0.2 秒以上かかった画像の縮小版を `~/Library/Caches/com.geologycat.PhotoViewer/Thumbnails` に保存（1GB まで） |
| 動画 | AVFoundation（サムネイル・撮影情報）。プレビューは AppKit の `AVPlayerView`（SwiftUI の `VideoPlayer` は起動時に異常終了したため使わない） |
| サイドバーの即時反映 | FSEvents（`DirectoryEventWatcher`）で表示中の起点以下を監視 |

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
- リポジトリ：GitHub `Geology-cat/PhotoViewer`（**public**）。公開リポジトリなので、個人情報・機密情報をコミットしない。
- コミットの作者メールは GitHub の匿名アドレス（`262972311+Geology-cat@users.noreply.github.com`、このリポジトリの git config に設定済み）。
- コミットメッセージは日本語。末尾に `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` を付ける。
