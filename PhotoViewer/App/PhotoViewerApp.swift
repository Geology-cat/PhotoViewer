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
