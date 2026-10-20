import AppKit
import SwiftUI

@main
struct PhotoViewerApp: App {
    @State private var browser = BrowserState()
    @State private var tree = FolderTree()

    var body: some Scene {
        Window("PhotoViewer", id: "main") {
            ContentView()
                .environment(browser)
                .environment(tree)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            SidebarCommands()
            InspectorCommands()
            CommandGroup(after: .newItem) {
                Button("フォルダを開く…") { openFolderPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("再読み込み") { browser.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
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
