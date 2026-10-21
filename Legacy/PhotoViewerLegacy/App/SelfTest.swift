import AppKit
import AVKit

/// 自動の動作確認（環境変数 PV_SELFTEST=<画像を保存するフォルダ> のときだけ動く。普段は何もしない）
/// 本物のマウス・キーのイベントをアプリに送り、場面ごとにウインドウの画像を保存して、結果を標準エラー出力に書く。
/// - PV_SELFTEST_FOLDER：最初に開くフォルダ（テストデータ。★の書き込みはここで行い、元に戻す）
/// - PV_SELFTEST_VIDEO：動画のあるフォルダ（任意）
enum SelfTest {
    private static var steps: [(String, Double, () -> Void)] = []
    private static var outDir: URL!
    private static var index = 0
    private static var failures = 0

    static func startIfRequested(window: MainWindowController) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["PV_SELFTEST"], let folder = env["PV_SELFTEST_FOLDER"] else { return }
        outDir = URL(fileURLWithPath: dir)
        // 最前面でないと、クリックが「ウインドウを前に出す操作」として扱われる
        NSApp.activate(ignoringOtherApps: true)
        window.window?.makeKeyAndOrderFront(nil)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        build(window, folder: URL(fileURLWithPath: folder), video: env["PV_SELFTEST_VIDEO"].map { URL(fileURLWithPath: $0) })
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { runNext() }
    }

    private static func runNext() {
        guard index < steps.count else {
            log("終了（確認 NG：\(failures) 件）")
            NSApp.terminate(nil)
            return
        }
        let (name, wait, action) = steps[index]
        index += 1
        log("▶︎ \(name)")
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { runNext() }
    }

    private static func step(_ name: String, wait: Double = 0.8, _ action: @escaping () -> Void) {
        steps.append((name, wait, action))
    }

    static func log(_ s: String) {
        FileHandle.standardError.write(Data("[selftest] \(s)\n".utf8))
    }

    private static func check(_ label: String, _ ok: Bool) {
        if !ok { failures += 1 }
        log("  \(ok ? "OK" : "NG")：\(label)")
    }

    /// ウインドウの中身を画像に保存する
    private static func snapshot(_ name: String, _ view: NSView?) {
        guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let n = String(format: "%02d", index)
        try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent("\(n)_\(name).png"))
    }

    // MARK: イベントを送る

    private static func mouse(_ type: NSEvent.EventType, _ view: NSView, _ p: NSPoint, count: Int = 1,
                              flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let w = view.window!
        return NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: flags,
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
    }

    /// クリック：ビューのマウス処理に直接届ける
    /// （テストで裏から起動したアプリは最前面でないため、イベントの列に入れると「ウインドウを前に出すクリック」として扱われる）
    private static func click(_ view: NSView, at p: NSPoint, count: Int = 1, flags: NSEvent.ModifierFlags = []) {
        let down = mouse(.leftMouseDown, view, p, count: count, flags: flags)
        let up = mouse(.leftMouseUp, view, p, count: count, flags: flags)
        if view is NSCollectionView {
            // コレクションビューはボタンを離すまでイベントを待つので、離すイベントを先に入れておく
            NSApp.postEvent(up, atStart: false)
            view.mouseDown(with: down)
        } else {
            view.mouseDown(with: down)
            view.mouseUp(with: up)
        }
    }

    private static func drag(_ view: NSView, from a: NSPoint, to b: NSPoint) {
        view.mouseDown(with: mouse(.leftMouseDown, view, a))
        for i in 1...8 {
            let t = CGFloat(i) / 8
            view.mouseDragged(with: mouse(.leftMouseDragged, view, NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
        }
        view.mouseUp(with: mouse(.leftMouseUp, view, b))
    }

    private static func key(_ window: NSWindow, code: UInt16, chars: String, flags: NSEvent.ModifierFlags = []) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                 isARepeat: false, keyCode: code)!
        NSApp.postEvent(e, atStart: false)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let v = view as? T { return v }
        for s in view.subviews { if let f = find(type, in: s) { return f } }
        return nil
    }

    // MARK: 手順

    private static func build(_ wc: MainWindowController, folder: URL, video: URL?) {
        let browser = BrowserModel.shared
        let window = wc.window!
        let content = { window.contentView }
        let grid = { wc.split.grid.collectionView! }
        func cellCenter(_ i: Int) -> NSPoint? {
            grid().layoutAttributesForItem(at: IndexPath(item: i, section: 0)).map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) }
        }
        func url(named name: String) -> URL? { browser.displayedItems.first { $0.name == name }?.url }

        step("フォルダを開く", wait: 2.5) {
            browser.navigate(listRoot: folder.deletingLastPathComponent().path, folder: folder)
        }
        step("最初の画面") { snapshot("最初の画面", content()) }

        // クリックで選ぶ → プレビュー・情報
        step("IMG_0001 をクリック", wait: 2) {
            if let i = browser.displayedItems.firstIndex(where: { $0.name == "IMG_0001.JPG" }), let p = cellCenter(i) {
                click(grid(), at: p)
            }
        }
        step("選択とプレビュー") {
            check("クリックで選択された", browser.primarySelection?.lastPathComponent == "IMG_0001.JPG")
            check("プレビューに画像が出た", find(ZoomImageView.self, in: content())?.image != nil)
            snapshot("選択とプレビュー", content())
        }

        // ⌘クリックで追加、Shift クリックで範囲
        step("⌘クリックで追加", wait: 1) {
            if let p = cellCenter(0) { click(grid(), at: p, flags: .command) }
        }
        step("⌘クリックの確認") { check("2 件選択", browser.selection.count == 2) }
        step("Shift クリックで範囲", wait: 1) {
            if let p = cellCenter(0) { click(grid(), at: p) }
        }
        step("Shift クリック 2", wait: 1) {
            if let p = cellCenter(5) { click(grid(), at: p, flags: .shift) }
        }
        step("範囲選択の確認") {
            check("0〜5 の 6 件を選択", browser.selection.count == 6)
            snapshot("範囲選択", content())
        }

        // 矢印キー（行の端で回り込む）
        step("グリッドにフォーカス", wait: 0.5) {
            if let p = cellCenter(0) { click(grid(), at: p) }
            wc.split.grid.focus()
        }
        let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        var columns = 0
        step("→ を列の数だけ押す", wait: 1) {
            let cv = grid()
            let y0 = cv.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame.minY
            columns = (0..<browser.displayedItems.count).prefix {
                cv.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame.minY == y0
            }.count
            for _ in 0..<columns { key(window, code: 124, chars: right, flags: [.function, .numericPad]) }
        }
        step("→ の回り込みの確認", wait: 0.5) {
            check("→ で次の行の左端へ（\(columns) 列）", browser.primarySelection == browser.displayedItems[safe: columns]?.url)
            key(window, code: 123, chars: left, flags: [.function, .numericPad])
        }
        step("← の回り込みの確認", wait: 0.5) {
            check("← で前の行の右端へ", browser.primarySelection == browser.displayedItems[safe: columns - 1]?.url)
            key(window, code: 125, chars: down, flags: [.function, .numericPad])
        }
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        step("↓ の確認", wait: 0.5) {
            check("↓ で 1 行下へ（←→ の後でも同じ列）", browser.primarySelection == browser.displayedItems[safe: 2 * columns - 1]?.url)
            key(window, code: 126, chars: up, flags: [.function, .numericPad])
        }
        step("↑ の確認") {
            check("↑ で 1 行上へ", browser.primarySelection == browser.displayedItems[safe: columns - 1]?.url)
        }

        // ★を付けて戻す（テストデータ）
        step("IMG_0001 を選ぶ", wait: 1.5) {
            if let u = url(named: "IMG_0001.JPG") { browser.updateSelection([u], lastAdded: u) }
            wc.split.grid.focus()
        }
        var originalRating = 0
        step("5 キーで★5", wait: 1.5) {
            if let u = url(named: "IMG_0001.JPG") { originalRating = browser.tags(for: u).rating }
            key(window, code: 23, chars: "5")
        }
        step("★5 の確認", wait: 1) {
            let xmp = (try? String(contentsOf: folder.appendingPathComponent("IMG_0001.xmp"))) ?? ""
            check("★5 になった", url(named: "IMG_0001.JPG").map { browser.tags(for: $0).rating } == 5)
            check("XMP に Rating=5 が書かれた", xmp.contains("Rating=\"5\""))
            snapshot("星5", content())
            let codes: [Int: UInt16] = [0: 29, 1: 18, 2: 19, 3: 20, 4: 21, 5: 23]
            key(window, code: codes[originalRating] ?? 29, chars: "\(max(0, originalRating))")
        }
        step("★を元に戻した確認", wait: 1) {
            check("★を元に戻した", url(named: "IMG_0001.JPG").map { browser.tags(for: $0).rating } == originalRating)
        }

        // プレビューの拡大・移動・回転
        step("プレビューをクリックで拡大", wait: 2.5) {
            if let z = find(ZoomImageView.self, in: content()) {
                click(z, at: NSPoint(x: z.bounds.midX + 40, y: z.bounds.midY))
            }
        }
        step("拡大の確認", wait: 0.5) {
            check("拡大した", find(ZoomImageView.self, in: content())?.zoomed == true)
            snapshot("拡大", content())
            if let z = find(ZoomImageView.self, in: content()) {
                drag(z, from: NSPoint(x: z.bounds.midX, y: z.bounds.midY),
                     to: NSPoint(x: z.bounds.midX - 120, y: z.bounds.midY - 60))
            }
        }
        step("ドラッグ後", wait: 0.5) {
            check("ドラッグ後も拡大のまま", find(ZoomImageView.self, in: content())?.zoomed == true)
            snapshot("拡大して移動", content())
            if let z = find(ZoomImageView.self, in: content()) { click(z, at: NSPoint(x: z.bounds.midX, y: z.bounds.midY)) }
        }
        step("全体表示に戻る") {
            check("クリックで全体表示に戻った", find(ZoomImageView.self, in: content())?.zoomed == false)
            if let u = browser.primarySelection { browser.rotatePreview(u, by: 90) }
        }
        step("右に回転") {
            snapshot("右に回転", content())
            if let u = browser.primarySelection { browser.rotatePreview(u, by: -90) }
        }

        // 並べ替え・検索・絞り込み
        step("種類で並べ替え", wait: 1) { browser.filter.sortKey = .kind }
        step("種類の確認") {
            check("先頭が JPEG（RAW なし）", browser.displayedItems.first?.ext == "jpg")
            snapshot("種類で並べ替え", content())
            browser.filter.sortKey = .name
        }
        step("検索", wait: 1) {
            wc.searchField.stringValue = "IMG_000"
            wc.searchField.sendAction(wc.searchField.action, to: wc.searchField.target)
        }
        step("検索の確認") {
            check("検索で絞り込まれた", browser.displayedItems.allSatisfy { $0.name.hasPrefix("IMG_000") }
                    && !browser.displayedItems.isEmpty)
            snapshot("検索", content())
            wc.searchField.stringValue = ""
            wc.searchField.sendAction(wc.searchField.action, to: wc.searchField.target)
        }
        var popover: NSPopover?
        step("絞り込みパネル", wait: 1.5) {
            let p = NSPopover()
            p.behavior = .applicationDefined
            p.contentViewController = FilterPanelController()
            p.show(relativeTo: .zero, of: grid(), preferredEdge: .minY)
            popover = p
        }
        step("絞り込みパネルの画面") {
            snapshot("絞り込みパネル", popover?.contentViewController?.view)
            browser.filter.rating = .atLeast(3)
        }
        step("★3 以上の確認", wait: 1) {
            check("★3 以上で絞り込まれた", browser.displayedItems.allSatisfy { browser.tags(for: $0.url).rating >= 3 }
                    && !browser.displayedItems.isEmpty)
            browser.filter.rating = .all
            popover?.close()
        }

        // 右列・サイドバーの開閉
        step("右列を閉じる", wait: 1) { wc.toggleInspectorPressed() }
        step("右列を閉じた画面") {
            check("右列が閉じた", wc.split.inspectorItem.isCollapsed)
            snapshot("右列を閉じた", content())
            wc.toggleInspectorPressed()
        }
        step("サイドバーを閉じる", wait: 1) { wc.toggleSidebarPressed() }
        step("サイドバーを閉じた画面") {
            check("サイドバーが閉じた", wc.split.sidebarItem.isCollapsed)
            snapshot("サイドバーを閉じた", content())
            wc.toggleSidebarPressed()
        }

        // サイドバー：別のフォルダに入る・戻る・進む・アイコン表示
        let other = folder.deletingLastPathComponent().appendingPathComponent("RAWペア")
        step("別のフォルダに入る", wait: 2) { browser.navigate(listRoot: other.path, folder: other) }
        step("別のフォルダの画面") {
            check("RAWペア を表示", browser.currentFolder?.lastPathComponent == "RAWペア")
            snapshot("別のフォルダ", content())
            browser.goBack()
        }
        step("戻るの確認", wait: 1.5) {
            check("戻るで元のフォルダ", browser.currentFolder?.lastPathComponent == folder.lastPathComponent)
            browser.goForward()
        }
        step("進むの確認", wait: 1.5) {
            check("進むで RAWペア", browser.currentFolder?.lastPathComponent == "RAWペア")
            snapshot("RAWペア", content())
            browser.goBack()
        }
        step("アイコン表示", wait: 1.5) {
            UserDefaults.standard.set("icon", forKey: "sidebar.style")
            if let seg = find(NSSegmentedControl.self, in: wc.split.sidebar.view) {
                seg.selectedSegment = 1
                seg.sendAction(seg.action, to: seg.target)
            }
        }
        step("アイコン表示の画面") {
            snapshot("アイコン表示", content())
            if let seg = find(NSSegmentedControl.self, in: wc.split.sidebar.view) {
                seg.selectedSegment = 0
                seg.sendAction(seg.action, to: seg.target)
            }
        }

        // リネームのシート・環境設定
        var sheet: RenameSheetController?
        step("リネームのシート", wait: 2) {
            let targets = Array(browser.displayedItems.prefix(3).map(\.url))
            let vc = RenameSheetController(targets: targets, undoManager: window.undoManager)
            wc.contentViewController?.presentAsSheet(vc)
            sheet = vc
        }
        step("リネームの画面") {
            snapshot("リネーム", sheet?.view)
            if let s = sheet { wc.contentViewController?.dismiss(s) }
        }
        step("環境設定", wait: 1.5) { SettingsWindowController.shared.showWindow(nil) }
        step("環境設定の画面") {
            snapshot("環境設定", SettingsWindowController.shared.window?.contentView)
            SettingsWindowController.shared.close()
        }

        // 動画
        if let video {
            step("動画のフォルダ", wait: 2.5) { browser.navigate(listRoot: video.deletingLastPathComponent().path, folder: video) }
            step("動画を選ぶ", wait: 2.5) {
                if let u = browser.displayedItems.first(where: \.isVideo)?.url { browser.updateSelection([u], lastAdded: u) }
            }
            step("動画の画面") {
                check("動画の再生画面が出た", find(AVPlayerView.self, in: content())?.player != nil)
                snapshot("動画", content())
                browser.navigate(listRoot: folder.deletingLastPathComponent().path, folder: folder)
            }
        }
        step("最後の画面", wait: 1.5) { snapshot("最後", content()) }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
