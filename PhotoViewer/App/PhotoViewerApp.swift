import AppKit
import SwiftUI

@main
struct PhotoViewerApp: App {
    @State private var browser = BrowserState()
    @State private var tree = FolderTree()
    @State private var settings = AppSettings()

    var body: some Scene {
        Window("PhotoViewer", id: "main") {
            ContentView()
                .environment(browser)
                .environment(tree)
                .environment(settings)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            SidebarCommands()
            InspectorCommands()
            CommandGroup(after: .newItem) {
                Button("開く") { settings.open(browser.selectedURLsInDisplayOrder) }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(browser.selection.isEmpty)
                Button("フォルダを開く…") { openFolderPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("写真") {
                let targets = browser.selectedURLsInDisplayOrder
                ForEach(1...5, id: \.self) { n in
                    Button(String(repeating: "★", count: n)) { browser.setRating(n, for: targets) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
                Button("レーティングなし") { browser.setRating(0, for: targets) }
                    .keyboardShortcut("0", modifiers: .command)
                Button("リジェクト") { browser.setRating(-1, for: targets) }
                    .keyboardShortcut(.delete, modifiers: .option)
                Divider()
                Button("現像済みを切り替え") { browser.toggleDeveloped(for: targets) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("名前を一括変更…") { browser.renameTargets = targets }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(targets.isEmpty)
            }
            CommandGroup(after: .sidebar) {
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
