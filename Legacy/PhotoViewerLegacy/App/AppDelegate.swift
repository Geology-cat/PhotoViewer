import AppKit

/// アプリ全体：メニューとメインウインドウ（通常版の PhotoViewerApp と同じメニュー・ショートカット）
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let browser = BrowserModel.shared
    private let tree = FolderTreeModel.shared
    private var mainWindow: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        mainWindow = MainWindowController()
        browser.onRenameRequest = { [weak self] urls in self?.showRename(urls) }
        mainWindow.showWindow(nil)
        browser.restoreLastFolder()
        // 動作確認用（PV_SELFTEST のときだけ）
        SelfTest.startIfRequested(window: mainWindow)
        // ディスクに保存した縮小画像が多すぎたら、古いものから消す
        DispatchQueue.global(qos: .background).async { ThumbnailDiskCache.shared.prune() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - メニュー

    private func item(_ title: String, _ action: Selector?, _ key: String = "",
                      _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.keyEquivalentModifierMask = modifiers
        mi.tag = tag
        if let action, responds(to: action) { mi.target = self }
        return mi
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        mi.submenu = m
        return mi
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appName = "PhotoViewer Legacy"
        main.addItem(submenu(appName, [
            item("\(appName) について", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("環境設定…", #selector(showSettings), ","),
            .separator(),
            item("\(appName) を隠す", #selector(NSApplication.hide(_:)), "h"),
            item("ほかを隠す", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("すべてを表示", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("\(appName) を終了", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("ファイル", [
            item("開く", #selector(openSelected), "o"),
            item("フォルダを開く…", #selector(openFolderPanel), "o", [.command, .shift]),
            .separator(),
            item("ウインドウを閉じる", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        main.addItem(submenu("編集", [
            item("取り消す", Selector(("undo:")), "z"),
            item("やり直す", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("カット", #selector(NSText.cut(_:)), "x"),
            item("コピー", #selector(NSText.copy(_:)), "c"),
            item("ペースト", #selector(NSText.paste(_:)), "v"),
            item("すべてを選択", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("検索", #selector(focusSearch), "f"),
        ]))
        main.addItem(submenu("表示", [
            item("サイドバーを表示／非表示", #selector(toggleSidebar), "s", [.command, .control]),
            item("プレビューと情報を表示／非表示", #selector(toggleInspector), "i", [.command, .control]),
            .separator(),
            item("戻る", #selector(goBack), "["),
            item("進む", #selector(goForward), "]"),
            item("上の階層へ", #selector(goUp), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))),
            .separator(),
            item("再読み込み", #selector(reload), "r"),
            .separator(),
            item("フルスクリーンにする", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        var photo: [NSMenuItem] = (1...5).map { n in
            item(String(repeating: "★", count: n), #selector(setRating(_:)), "\(n)", .command, tag: n)
        }
        photo += [
            item("レーティングなし", #selector(setRating(_:)), "0", .command, tag: 0),
            item("リジェクト", #selector(setRating(_:)), String(Character(UnicodeScalar(NSDeleteCharacter)!)), .option, tag: -1),
            .separator(),
            item("現像済みを切り替え", #selector(toggleDeveloped), "d", [.command, .shift]),
            .separator(),
            item("プレビューを左に 90° 回転", #selector(rotateLeft),
                 String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), [.command, .option]),
            item("プレビューを右に 90° 回転", #selector(rotateRight),
                 String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), [.command, .option]),
            .separator(),
            item("名前を一括変更…", #selector(renameSelected), "r", [.command, .shift]),
            .separator(),
            item("Quick Look（Space）", #selector(quickLook)),
            item("ゴミ箱に入れる（⌘⌫）", #selector(trashSelected)),
        ]
        main.addItem(submenu("写真", photo))
        let window = submenu("ウインドウ", [
            item("しまう", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("拡大／縮小", #selector(NSWindow.performZoom(_:))),
        ])
        NSApp.windowsMenu = window.submenu
        main.addItem(window)
        let help = submenu("ヘルプ", [])
        NSApp.helpMenu = help.submenu
        main.addItem(help)
        return main
    }

    // MARK: - メニューの動作

    private var selected: [URL] { browser.selectedURLsInDisplayOrder }

    @objc private func showSettings() {
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSelected() {
        if !selected.isEmpty { AppSettings.shared.open(selected) }
    }

    @objc private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "開く"
        if panel.runModal() == .OK, let url = panel.url { browser.open(folder: url) }
    }

    @objc private func focusSearch() { mainWindow.focusSearch() }
    @objc private func toggleSidebar() { mainWindow.toggleSidebarPressed() }
    @objc private func toggleInspector() { mainWindow.toggleInspectorPressed() }
    @objc private func goBack() { browser.goBack() }
    @objc private func goForward() { browser.goForward() }
    @objc private func goUp() { SidebarNavigation.goUp(browser: browser, volumes: tree.volumes) }
    @objc private func reload() { browser.reload() }

    @objc private func setRating(_ sender: NSMenuItem) {
        browser.setRating(sender.tag, for: selected)
    }

    @objc private func toggleDeveloped() { browser.toggleDeveloped(for: selected) }

    @objc private func rotateLeft() {
        if let u = browser.primarySelection { browser.rotatePreview(u, by: -90) }
    }

    @objc private func rotateRight() {
        if let u = browser.primarySelection { browser.rotatePreview(u, by: 90) }
    }

    @objc private func renameSelected() {
        if !selected.isEmpty { showRename(selected) }
    }

    @objc private func quickLook() {
        guard !browser.selection.isEmpty else { return }
        mainWindow.split.grid.focus()
        mainWindow.split.grid.collectionView.toggleQuickLook()
    }

    @objc private func trashSelected() {
        browser.moveToTrash(selected, undoManager: mainWindow.window?.undoManager)
    }

    private func showRename(_ urls: [URL]) {
        guard !urls.isEmpty, let vc = mainWindow.contentViewController else { return }
        vc.presentAsSheet(RenameSheetController(targets: urls, undoManager: mainWindow.window?.undoManager))
    }

    /// 戻る・進む・上の階層へは、できないときは押せなくする
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack): return browser.canGoBack
        case #selector(goForward): return browser.canGoForward
        case #selector(goUp): return !browser.listRoot.isEmpty
        case #selector(toggleSidebar): return true
        default: return true
        }
    }
}
