import AppKit
import SwiftUI

/// Dock・Finder の「開く」イベントは、画面が作られる前でも受け取る。
@MainActor
final class PhotoViewerAppDelegate: NSObject, NSApplicationDelegate {
    let browser = BrowserState()
    var showMainWindow: (() -> Void)?

    // SwiftUI は openURLs を実装するため、openFiles より優先されるこちらで受け取る。
    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        open(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    private func open(_ urls: [URL]) {
        browser.openExternalURLs(urls) { [weak self] in
            self?.showMainWindow?()
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// ウインドウを閉じた後のドロップでも、同じ閲覧状態の画面を開き直す。
struct PhotoViewerRootView: View {
    let appDelegate: PhotoViewerAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .onAppear {
                appDelegate.showMainWindow = { openWindow(id: "main") }
            }
    }
}
