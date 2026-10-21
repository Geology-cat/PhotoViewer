import AppKit

/// 環境設定（⌘,）：一般・関連アプリ
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    convenience init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let general = NSTabViewItem(viewController: GeneralSettingsController())
        general.label = "一般"
        general.image = NSImage(named: NSImage.preferencesGeneralName)
        let assoc = NSTabViewItem(viewController: AssociationSettingsController())
        assoc.label = "関連アプリ"
        assoc.image = NSImage(named: NSImage.multipleDocumentsName)
        tabs.addTabViewItem(general)
        tabs.addTabViewItem(assoc)
        let window = NSWindow(contentViewController: tabs)
        window.title = "環境設定"
        window.styleMask = [.titled, .closable]
        self.init(window: window)
        window.center()
    }
}

// MARK: - 一般

final class GeneralSettingsController: NSViewController {
    private let d = UserDefaults.standard
    private let sizeMode = NSButton(radioButtonWithTitle: "サイズ指定", target: nil, action: nil)
    private let columnsMode = NSButton(radioButtonWithTitle: "列数指定", target: nil, action: nil)
    private let sizeSlider = NSSlider()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let columnsStepper = NSStepper()
    private let columnsLabel = NSTextField(labelWithString: "")
    private let namesCheck = NSButton(checkboxWithTitle: "ファイル名を表示", target: nil, action: nil)
    private let zoomPopup = NSPopUpButton()

    override func loadView() {
        for b in [sizeMode, columnsMode] {
            b.target = self
            b.action = #selector(modeChanged(_:))
        }
        sizeSlider.minValue = GridSettings.sizeRange.lowerBound
        sizeSlider.maxValue = GridSettings.sizeRange.upperBound
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged)
        sizeSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        columnsStepper.minValue = Double(GridSettings.columnsRange.lowerBound)
        columnsStepper.maxValue = Double(GridSettings.columnsRange.upperBound)
        columnsStepper.target = self
        columnsStepper.action = #selector(columnsChanged)
        namesCheck.target = self
        namesCheck.action = #selector(namesChanged)
        for p in PreviewSettings.zoomPercents {
            zoomPopup.addItem(withTitle: "\(p)%")
            zoomPopup.lastItem?.tag = p
        }
        zoomPopup.target = self
        zoomPopup.action = #selector(zoomChanged)
        let zoomNote = NSTextField(wrappingLabelWithString: "100% は画像の 1 ピクセルを画面の 1 ピクセルで表示します。拡大中はドラッグで動かせ、もう一度クリックすると全体表示に戻ります。")
        zoomNote.font = .systemFont(ofSize: 11)
        zoomNote.textColor = .secondaryLabelColor
        zoomNote.preferredMaxLayoutWidth = 320

        let heading1 = NSTextField(labelWithString: "サムネイル")
        heading1.font = .boldSystemFont(ofSize: 13)
        let heading2 = NSTextField(labelWithString: "プレビュー")
        heading2.font = .boldSystemFont(ofSize: 13)
        let grid = NSGridView(views: [
            [heading1, NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "並べ方"), NSStackView(views: [sizeMode, columnsMode])],
            [NSTextField(labelWithString: "大きさ"), NSStackView(views: [sizeSlider, sizeLabel])],
            [NSTextField(labelWithString: "列数"), NSStackView(views: [columnsLabel, columnsStepper])],
            [NSGridCell.emptyContentView, namesCheck],
            [heading2, NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "クリックしたときの拡大率"), zoomPopup],
            [NSGridCell.emptyContentView, zoomNote],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        let v = NSView()
        v.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: v.topAnchor, constant: 20),
            v.widthAnchor.constraint(equalToConstant: 560),
            v.heightAnchor.constraint(equalToConstant: 360),
        ])
        view = v
        refresh()
    }

    private func refresh() {
        let c = GridViewController.currentConfig()
        sizeMode.state = c.mode == .size ? .on : .off
        columnsMode.state = c.mode == .columns ? .on : .off
        sizeSlider.doubleValue = c.thumbnailSize
        sizeLabel.stringValue = "\(Int(c.thumbnailSize)) pt"
        columnsStepper.integerValue = c.columns
        columnsLabel.stringValue = "\(c.columns) 列"
        sizeSlider.isEnabled = c.mode == .size
        columnsStepper.isEnabled = c.mode == .columns
        namesCheck.state = c.showNames ? .on : .off
        let zoom = d.integer(forKey: PreviewSettings.zoomPercentKey)
        zoomPopup.selectItem(withTag: zoom > 0 ? zoom : PreviewSettings.defaultZoomPercent)
    }

    @objc private func modeChanged(_ sender: NSButton) {
        d.set((sender === sizeMode ? GridLayoutMode.size : .columns).rawValue, forKey: GridSettings.modeKey)
        refresh()
    }

    @objc private func sizeChanged() {
        d.set(sizeSlider.doubleValue, forKey: GridSettings.thumbnailSizeKey)
        refresh()
    }

    @objc private func columnsChanged() {
        d.set(columnsStepper.integerValue, forKey: GridSettings.columnsKey)
        refresh()
    }

    @objc private func namesChanged() {
        d.set(namesCheck.state == .on, forKey: GridSettings.showNamesKey)
    }

    @objc private func zoomChanged() {
        d.set(zoomPopup.selectedTag(), forKey: PreviewSettings.zoomPercentKey)
    }
}

// MARK: - 関連アプリ

final class AssociationSettingsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let settings = AppSettings.shared
    private let table = NSTableView()
    private let newField = NSTextField()
    private var rows: [String] { settings.associations.keys.sorted() }

    override func loadView() {
        let note = NSTextField(wrappingLabelWithString: "グリッドでダブルクリック（または Return / ⌘O）したときに使うアプリを、拡張子ごとに指定します。指定のない拡張子は macOS の既定のアプリで開きます。")
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 520
        for (id, title, width) in [("ext", "拡張子", 90.0), ("app", "開くアプリ", 400.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = CGFloat(width)
            table.addTableColumn(c)
        }
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        newField.placeholderString = "拡張子（例：cr3）"
        newField.target = self
        newField.action = #selector(add)
        newField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let addButton = NSButton(title: "追加", target: self, action: #selector(add))
        let removeButton = NSButton(title: "削除", target: self, action: #selector(remove))
        let buttons = NSStackView(views: [newField, addButton, NSView(), removeButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [note, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let v = NSView()
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            v.widthAnchor.constraint(equalToConstant: 560),
            v.heightAnchor.constraint(equalToConstant: 420),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        view = v
    }

    /// 拡張子を追加し、アプリ選択パネルを開く
    @objc private func add() {
        let ext = AppSettings.normalize(newField.stringValue)
        guard !ext.isEmpty else { return }
        if let app = Self.chooseApplication(for: ext) {
            settings.setAssociation(ext, appURL: app)
            newField.stringValue = ""
            table.reloadData()
        }
    }

    @objc private func remove() {
        let r = table.selectedRow
        guard rows.indices.contains(r) else { return }
        settings.removeAssociation(rows[r])
        table.reloadData()
    }

    /// .app を選ぶパネル
    static func chooseApplication(for ext: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = ".\(ext) を開くアプリを選択"
        panel.prompt = "選択"
        panel.allowedFileTypes = ["app"]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        return panel.runModal() == .OK ? panel.url : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let ext = rows[row]
        if tableColumn?.identifier.rawValue == "ext" {
            let t = NSTextField(labelWithString: ".\(ext)")
            t.font = .userFixedPitchFont(ofSize: 12)
            return t
        }
        // 「開くアプリ」：候補アプリのメニューから選ぶ
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.isBordered = false
        let current = settings.associations[ext]
        let head = NSMenuItem(title: current?.appURL != nil ? (current?.name ?? "") : "⚠︎ \(current?.name ?? "") が見つかりません",
                              action: nil, keyEquivalent: "")
        if let url = current?.appURL {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            head.image = icon
        }
        popup.menu?.addItem(head)
        let candidates = AppSettings.candidateApps(forExtension: ext)
        for app in candidates {
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            popup.menu?.addItem(ClosureMenuItem(AppAssociation(appURL: app).name, image: icon) { [weak self] in
                self?.settings.setAssociation(ext, appURL: app)
                self?.table.reloadData()
            })
        }
        if !candidates.isEmpty { popup.menu?.addItem(.separator()) }
        popup.menu?.addItem(ClosureMenuItem("その他…") { [weak self] in
            if let app = Self.chooseApplication(for: ext) {
                self?.settings.setAssociation(ext, appURL: app)
                self?.table.reloadData()
            }
        })
        return popup
    }
}
