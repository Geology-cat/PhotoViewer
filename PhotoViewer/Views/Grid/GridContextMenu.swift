import AppKit

/// グリッドの右クリックメニュー
@MainActor
enum GridContextMenu {
    static func make(for urls: [URL], settings: AppSettings, onRename: @escaping () -> Void,
                     onTrash: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        let title = urls.count == 1 ? "開く" : "\(urls.count) 件を開く"
        menu.addItem(ClosureMenuItem(title) { settings.open(urls) })

        // 「このアプリで開く」：選択中の拡張子すべてを開けるアプリを候補にする
        let exts = Set(urls.map { $0.pathExtension.lowercased() })
        var candidates: [URL]? = nil
        for e in exts {
            let apps = AppSettings.candidateApps(forExtension: e)
            candidates = candidates.map { c in c.filter { apps.contains($0) } } ?? apps
        }
        let sub = NSMenu()
        for app in candidates ?? [] {
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            sub.addItem(ClosureMenuItem(AppAssociation(appURL: app).name, image: icon) {
                settings.open(urls, withApplicationAt: app)
            })
        }
        if sub.items.isEmpty {
            sub.addItem(NSMenuItem(title: "候補なし", action: nil, keyEquivalent: ""))
        }
        let openWith = NSMenuItem(title: "このアプリで開く", action: nil, keyEquivalent: "")
        openWith.submenu = sub
        menu.addItem(openWith)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("名前を一括変更…", handler: onRename))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Finder で表示") {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        })
        menu.addItem(ClosureMenuItem("パスをコピー") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("ゴミ箱に入れる", handler: onTrash))
        return menu
    }
}
