import AppKit
import SwiftUI

@main
struct PhotoViewerApp: App {
    @State private var browser = BrowserState()
    @State private var tree = FolderTree()
    @State private var settings = AppSettings()
    @AppStorage("inspector.visible") private var showInspector = true
    @AppStorage("sidebar.listRoot") private var listRoot = ""

    init() {
        // 計測用（PV_HANGCHECK=1 のときだけ）：メインスレッドが止まった時間を記録する
        HangWatchdog.startIfRequested()
        // ディスクに保存した縮小画像が多すぎたら、古いものから消す
        Task.detached(priority: .background) { ThumbnailDiskCache.shared.prune() }
    }

    var body: some Scene {
        Window("PhotoViewer", id: "main") {
            ContentView()
                .environment(browser)
                .environment(tree)
                .environment(settings)
                .frame(minWidth: 900, idealWidth: 1400, minHeight: 560, idealHeight: 900)
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            SidebarCommands()
            CommandGroup(after: .newItem) {
                Button("開く") { settings.open(browser.selectedURLsInDisplayOrder) }
                    .keyboardShortcut("o", modifiers: .command)
                Button("フォルダを開く…") { openFolderPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("写真") {
                // メニューは、読んでいる状態が変わるたびにメニューバーごと作り直される。
                // 選択のように頻繁に変わる値は読まず、押したときに選択がなければ何もしない
                ForEach(1...5, id: \.self) { n in
                    Button(String(repeating: "★", count: n)) { browser.setRating(n, for: browser.selectedURLsInDisplayOrder) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
                Button("レーティングなし") { browser.setRating(0, for: browser.selectedURLsInDisplayOrder) }
                    .keyboardShortcut("0", modifiers: .command)
                Button("リジェクト") { browser.setRating(-1, for: browser.selectedURLsInDisplayOrder) }
                    .keyboardShortcut(.delete, modifiers: .option)
                Divider()
                Button("現像済みを切り替え") { browser.toggleDeveloped(for: browser.selectedURLsInDisplayOrder) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("プレビューを左に 90° 回転") {
                    if let u = browser.primarySelection { browser.rotatePreview(u, by: -90) }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("プレビューを右に 90° 回転") {
                    if let u = browser.primarySelection { browser.rotatePreview(u, by: 90) }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Divider()
                Button("名前を一括変更…") {
                    let targets = browser.selectedURLsInDisplayOrder
                    if !targets.isEmpty { browser.renameTargets = targets }
                }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Quick Look（Space）") {
                    if !browser.selection.isEmpty {
                        (NSApp.keyWindow?.firstResponder as? PhotoCollectionView)?.toggleQuickLook()
                    }
                }
                Button("ゴミ箱に入れる（⌘⌫）") {
                    browser.moveToTrash(browser.selectedURLsInDisplayOrder, undoManager: NSApp.keyWindow?.undoManager)
                }
            }
            CommandGroup(after: .sidebar) {
                Button("戻る") { browser.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!browser.canGoBack)
                Button("進む") { browser.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!browser.canGoForward)
                Button("上の階層へ") { SidebarNavigation.goUp(rootPath: &listRoot, browser: browser, volumes: tree.volumes) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(listRoot.isEmpty)
                Button(showInspector ? "プレビューと情報を隠す" : "プレビューと情報を表示") { showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .control])
                Button("再読み込み") { browser.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
        }
    }

    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "開く"
        if panel.runModal() == .OK, let url = panel.url {
            browser.open(folder: url)
        }
    }
}
