import AppKit
import Foundation

/// 自動の負荷試験（環境変数 PV_STRESS=1 のときだけ動く。普段は何もしない）
/// よくある操作を決まった手順で素早く繰り返し、HangWatchdog と組み合わせてメインスレッドの止まりを調べる。
/// - PV_STRESS_WRITE：★を付けてよいフォルダ（テストデータ）。指定がなければ書き込みはしない
/// - PV_STRESS_FOLDERS：開くフォルダ（「:」区切り）。外付け HDD などは読むだけ
@MainActor
enum StressTest {
    static func startIfRequested(browser: BrowserState) {
        let env = ProcessInfo.processInfo.environment
        guard env["PV_STRESS"] == "1" else { return }
        let folders = (env["PV_STRESS_FOLDERS"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let writable = env["PV_STRESS_WRITE"].map { URL(fileURLWithPath: $0) }
        Task {
            try? await Task.sleep(for: .seconds(3))
            await run(browser: browser, folders: folders, writable: writable)
            log("終了")
            NSApp.terminate(nil)
        }
    }

    private static func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        FileHandle.standardError.write(Data("[stress] \(f.string(from: Date())) \(s)\n".utf8))
    }

    private static func pause(_ ms: Int) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// フォルダを開いて、一覧の読み込みが終わるまで待つ
    private static func open(_ browser: BrowserState, _ folder: URL) async {
        log("フォルダを開く \(folder.lastPathComponent)")
        browser.open(folder: folder)
        for _ in 0..<100 {
            await pause(100)
            if !browser.isScanning && browser.currentFolder == folder.standardizedFileURL { break }
        }
        await pause(800)
    }

    private static var collectionView: PhotoCollectionView? {
        func find(_ v: NSView) -> PhotoCollectionView? {
            if let c = v as? PhotoCollectionView { return c }
            for s in v.subviews { if let c = find(s) { return c } }
            return nil
        }
        return NSApp.windows.lazy.compactMap { $0.contentView.flatMap(find) }.first
    }

    /// セルの間隔（横・縦）と、最後の行の並び（間隔が広がっていないか）を記録する
    private static func logGaps(_ size: Double) {
        guard let cv = collectionView else { return }
        cv.layoutSubtreeIfNeeded()
        let count = cv.numberOfItems(inSection: 0)
        let frames = (0..<count).compactMap { cv.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame }
        guard frames.count > 1 else { return }
        let firstRow = frames.filter { $0.minY == frames[0].minY }
        let lastRow = frames.filter { $0.minY == frames[frames.count - 1].minY }
        func gaps(_ row: [NSRect]) -> Set<Int> { Set(zip(row, row.dropFirst()).map { Int(($1.minX - $0.maxX).rounded()) }) }
        let vertical = frames.first { $0.minY > frames[0].minY }.map { Int(($0.minY - frames[0].maxY).rounded()) }
        log("大きさ \(Int(size))：\(firstRow.count) 列、セル \(Int(frames[0].width)) pt、横の間隔 \(gaps(firstRow).sorted())、縦の間隔 \(vertical ?? -1)、最後の行 \(lastRow.count) 個の間隔 \(gaps(lastRow).sorted())、左端 \(Int(frames[0].minX))/\(Int(lastRow[0].minX))")
    }

    /// 表示中のセルが重なっていないか・間隔が 8pt か・左端が揃っているかを調べる。問題があれば内容を返す
    private static func layoutProblems(_ cv: NSCollectionView) -> String? {
        let cells = cv.visibleItems().map(\.view.frame).sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        guard cells.count > 1 else { return nil }
        for (i, a) in cells.enumerated() {
            for b in cells[(i + 1)...] where a.insetBy(dx: 1, dy: 1).intersects(b) {
                return "セルが重なっている \(a) \(b)"
            }
        }
        let rows = Dictionary(grouping: cells) { Int($0.minY.rounded()) }
        for (_, row) in rows {
            let r = row.sorted { $0.minX < $1.minX }
            if Int(r[0].minX.rounded()) != 8 { return "行の左端が \(r[0].minX)" }
            for (a, b) in zip(r, r.dropFirst()) where abs(b.minX - a.maxX - 8) > 0.5 {
                return "横の間隔が \(b.minX - a.maxX)"
            }
        }
        return nil
    }

    /// ウインドウの幅を 1pt ずつ変えながら、グリッドの並びが崩れないかを調べる（中途半端な幅でセルが重なった不具合の確認）
    private static func checkWidths() async {
        guard let cv = collectionView, let window = cv.window else { return }
        log("ウインドウの幅を変えながら並びを確認")
        let original = window.frame
        var problems = 0, checked = 0
        for w in stride(from: 900.0, through: 1400, by: 1) {
            var f = window.frame
            f.size.width = w
            window.setFrame(f, display: true)
            window.layoutIfNeeded()
            cv.layoutSubtreeIfNeeded()
            if let p = layoutProblems(cv) {
                problems += 1
                if problems <= 3 { log("幅 \(Int(w))：\(p)") }
            }
            checked += 1
            if checked % 50 == 0 { await pause(10) }
        }
        window.setFrame(original, display: true)
        log("幅の確認：\(checked) 通り中、崩れ \(problems) 件")
    }

    /// ←→ キーが行の端で前後の行へ回り込むか（実際のキーイベントをグリッドに送って確かめる）
    private static func checkArrowWrap(_ browser: BrowserState) {
        guard let cv = collectionView, let window = cv.window, browser.displayedItems.count > 2,
              let firstY = cv.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame.minY else { return }
        let count = browser.displayedItems.count
        let columns = (0..<count).prefix { cv.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame.minY == firstY }.count
        guard columns < count else { return }
        func press(_ keyCode: UInt16, _ ch: Int) {
            let s = UnicodeScalar(UInt32(ch)).map { String(Character($0)) } ?? ""
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                                           timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                           characters: s, charactersIgnoringModifiers: s, isARepeat: false,
                                           keyCode: keyCode) else { return }
            cv.keyDown(with: e)
        }
        let lastInRow = browser.displayedItems[columns - 1].url
        browser.updateSelection([lastInRow], lastAdded: lastInRow)
        cv.selectionIndexPaths = [IndexPath(item: columns - 1, section: 0)]
        (cv as PhotoCollectionView).resetAnchor(to: IndexPath(item: columns - 1, section: 0))
        press(124, 0xF703)   // →
        let right = browser.primarySelection == browser.displayedItems[columns].url
        press(123, 0xF702)   // ←
        let left = browser.primarySelection == lastInRow
        log("←→ の回り込み（\(columns) 列）：→ \(right ? "OK" : "NG")、← \(left ? "OK" : "NG")")
        // ↓↑ は 1 行下・上の同じ列へ（標準の動作。レイアウトを自前にしても動くか）
        let top = browser.displayedItems[0].url
        browser.updateSelection([top], lastAdded: top)
        cv.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
        (cv as PhotoCollectionView).resetAnchor(to: IndexPath(item: 0, section: 0))
        press(125, 0xF701)   // ↓
        let down = browser.primarySelection == browser.displayedItems[columns].url
        press(126, 0xF700)   // ↑
        let up = browser.primarySelection == top
        log("↓↑ の移動：↓ \(down ? "OK" : "NG")、↑ \(up ? "OK" : "NG")")
    }

    private static func run(browser: BrowserState, folders: [URL], writable: URL?) async {
        let defaults = UserDefaults.standard
        for folder in folders {
            await open(browser, folder)

            log("高速スクロール")
            if let cv = collectionView, let clip = cv.enclosingScrollView?.contentView {
                let height = cv.bounds.height
                for i in 0..<30 {
                    let y = height * Double(i % 10) / 10
                    clip.scroll(to: NSPoint(x: 0, y: y))
                    cv.enclosingScrollView?.reflectScrolledClipView(clip)
                    await pause(50)
                }
                clip.scroll(to: .zero)
            }
            await pause(500)

            log("サムネイルの大きさを変える")
            for size in [100.0, 140, 200, 260, 120, 160] {
                defaults.set(size, forKey: GridSettings.thumbnailSizeKey)
                await pause(150)
                logGaps(size)
            }

            log("選択を次々に動かす（矢印キーの連打の代わり）")
            for item in browser.displayedItems.prefix(40) {
                browser.updateSelection([item.url], lastAdded: item.url)
                await pause(60)
            }

            checkArrowWrap(browser)
            await checkWidths()

            log("並べ替えを全種類")
            for key in SortKey.allCases {
                browser.filter.sortKey = key
                await pause(key == .captureDate ? 1500 : 400)
            }
            browser.filter.sortKey = .name

            log("検索欄に 1 文字ずつ入力")
            for text in ["I", "IM", "IMG", "IMG_", "IMG_1", "", "j", "jp", "jpg", ""] {
                browser.filter.text = text
                await pause(120)
            }

            log("レーティングで絞り込み")
            browser.filter.rating = .atLeast(1)
            await pause(800)
            browser.filter.rating = .all
            await pause(300)

            log("右列の開閉")
            for _ in 0..<4 {
                defaults.set(!defaults.bool(forKey: "inspector.visible"), forKey: "inspector.visible")
                await pause(300)
            }
            defaults.set(true, forKey: "inspector.visible")

            if let writable, folder.standardizedFileURL == writable.standardizedFileURL {
                log("★を連続で付ける（テストデータ）")
                for (i, item) in browser.displayedItems.prefix(20).enumerated() {
                    browser.updateSelection([item.url], lastAdded: item.url)
                    browser.setRating(i % 6, for: [item.url])
                    await pause(80)
                }
                for item in browser.displayedItems.prefix(20) { browser.setRating(0, for: [item.url]) }
                await pause(1500)
            }

            // 動画があれば選んで、プレビューの再生画面を出す
            if let video = browser.displayedItems.first(where: \.isVideo) {
                log("動画を選ぶ")
                browser.updateSelection([video.url], lastAdded: video.url)
                await pause(1500)
            }
        }

        log("戻る・進むを連打")
        for _ in 0..<4 { browser.goBack(); await pause(400) }
        for _ in 0..<4 { browser.goForward(); await pause(400) }

        log("サイドバーの起点を切り替える")
        for folder in folders + [URL(fileURLWithPath: "/"), URL(fileURLWithPath: NSHomeDirectory())] {
            defaults.set(folder.path, forKey: BrowserState.listRootKey)
            await pause(700)
        }
        defaults.set("", forKey: BrowserState.listRootKey)
        await pause(1000)
    }
}
