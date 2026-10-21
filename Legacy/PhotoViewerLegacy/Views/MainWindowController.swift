import AppKit

/// 右列：プレビュー（上）と画像情報（下）
final class InspectorViewController: NSSplitViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        let preview = NSViewController()
        preview.view = PreviewPane(frame: NSRect(x: 0, y: 0, width: 340, height: 360))
        let info = NSViewController()
        info.view = InfoPanel(frame: NSRect(x: 0, y: 0, width: 340, height: 300))
        let top = NSSplitViewItem(viewController: preview)
        top.minimumThickness = 160
        let bottom = NSSplitViewItem(viewController: info)
        bottom.minimumThickness = 140
        addSplitViewItem(top)
        addSplitViewItem(bottom)
        splitView.autosaveName = "inspector.split"
    }
}

/// 3 列（サイドバー／グリッド／右列）
final class MainSplitViewController: NSSplitViewController {
    let sidebar = SidebarViewController()
    let grid = GridViewController()
    let inspector = InspectorViewController()
    private(set) var sidebarItem: NSSplitViewItem!
    private(set) var inspectorItem: NSSplitViewItem!

    static let sidebarVisibleKey = "sidebar.visible"
    static let inspectorVisibleKey = "inspector.visible"

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 600
        sidebarItem.canCollapse = true
        let gridItem = NSSplitViewItem(viewController: grid)
        gridItem.minimumThickness = 120
        gridItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 200)
        inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.minimumThickness = 240
        inspectorItem.canCollapse = true
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)
        addSplitViewItem(sidebarItem)
        addSplitViewItem(gridItem)
        addSplitViewItem(inspectorItem)
        splitView.autosaveName = "main.split"

        let d = UserDefaults.standard
        sidebarItem.isCollapsed = d.object(forKey: Self.sidebarVisibleKey) as? Bool == false
        inspectorItem.isCollapsed = d.object(forKey: Self.inspectorVisibleKey) as? Bool == false
    }

    /// 初回だけ：サイドバー 230、右列 340 の幅にする（次からは保存した幅を使う）
    func applyInitialWidths(totalWidth: CGFloat) {
        view.layoutSubtreeIfNeeded()
        splitView.setPosition(230, ofDividerAt: 0)
        splitView.setPosition(totalWidth - 340, ofDividerAt: 1)
    }

    func toggleSidebarItem() {
        sidebarItem.animator().isCollapsed = !sidebarItem.isCollapsed
        // 保存するのは「表示しているか」
        UserDefaults.standard.set(!sidebarItem.isCollapsed, forKey: Self.sidebarVisibleKey)
    }

    func toggleInspectorItem() {
        inspectorItem.animator().isCollapsed = !inspectorItem.isCollapsed
        UserDefaults.standard.set(!inspectorItem.isCollapsed, forKey: Self.inspectorVisibleKey)
    }

    /// 境界のドラッグで閉じたときも状態を保存する
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard sidebarItem != nil else { return }
        UserDefaults.standard.set(!sidebarItem.isCollapsed, forKey: Self.sidebarVisibleKey)
        UserDefaults.standard.set(!inspectorItem.isCollapsed, forKey: Self.inspectorVisibleKey)
    }
}

/// メインウインドウ（ツールバー・タイトル・警告の表示）
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let browser = BrowserModel.shared
    let split = MainSplitViewController()
    private var observers: [NSObjectProtocol] = []

    // ツールバーの部品
    private let navControl = NSSegmentedControl()
    private let filterButton = NSButton()
    private let sortButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let modeButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeSlider = NSSlider()
    private let columnsStepper = NSStepper()
    private let columnsLabel = NSTextField(labelWithString: "")
    private let sizeContainer = NSView()
    private let namesButton = NSButton()
    let searchField = NSSearchField()
    private var filterPopover: NSPopover?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 900, height: 560)
        window.title = "PhotoViewer Legacy"
        window.setFrameAutosaveName("main.window")
        self.init(window: window)
        // contentViewController を設定するとウインドウはビューの大きさになるので、先に初期の大きさにしておく
        split.view.setFrameSize(NSSize(width: 1400, height: 900))
        window.contentViewController = split
        window.delegate = self
        if !window.setFrameUsingName("main.window") {
            window.center()
            split.applyInitialWidths(totalWidth: 1400)
        }

        let toolbar = NSToolbar(identifier: "main.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        browser.onAlert = { [weak self] message in self?.showAlert(message) }
        let nc = NotificationCenter.default
        for name in [Notification.Name.browserFolderChanged, .browserDisplayedChanged, .browserMetadataChanged] {
            observers.append(nc.addObserver(forName: name, object: browser, queue: .main) { [weak self] _ in self?.updateTitle() })
        }
        observers.append(nc.addObserver(forName: .browserLocationChanged, object: browser, queue: .main) { [weak self] _ in
            self?.updateNavigation()
        })
        observers.append(nc.addObserver(forName: .browserFilterChanged, object: browser, queue: .main) { [weak self] _ in
            self?.updateFilterControls()
        })
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateGridControls()
        })
        updateTitle()
        updateNavigation()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { sharedUndoManager }
    let sharedUndoManager = UndoManager()

    private func updateTitle() {
        guard let folder = browser.currentFolder else {
            window?.title = "PhotoViewer Legacy"
            return
        }
        let n = browser.displayedItems.count
        var s = browser.filter.isFiltering ? "\(n) / \(browser.items.count) 枚" : "\(n) 枚"
        if let p = browser.metadataProgress { s += "・撮影情報を読み込み中 \(p.done)/\(p.total)" }
        window?.title = "\(folder.lastPathComponent)　（\(s)）"
    }

    private func showAlert(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "エラー"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    // MARK: - ツールバー

    private enum ItemID {
        static let sidebar = NSToolbarItem.Identifier("sidebar")
        static let navigation = NSToolbarItem.Identifier("navigation")
        static let filter = NSToolbarItem.Identifier("filter")
        static let sort = NSToolbarItem.Identifier("sort")
        static let mode = NSToolbarItem.Identifier("mode")
        static let size = NSToolbarItem.Identifier("size")
        static let names = NSToolbarItem.Identifier("names")
        static let inspector = NSToolbarItem.Identifier("inspector")
        static let search = NSToolbarItem.Identifier("search")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.sidebar, ItemID.navigation, .flexibleSpace, ItemID.filter, ItemID.sort, ItemID.mode, ItemID.size,
         ItemID.names, ItemID.inspector, ItemID.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    private func item(_ id: NSToolbarItem.Identifier, label: String, tip: String, view: NSView,
                      width: CGFloat? = nil) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.view = view
        let size = view.fittingSize
        let w = width ?? max(size.width, 32)
        item.minSize = NSSize(width: w, height: max(size.height, 24))
        item.maxSize = NSSize(width: w, height: max(size.height, 28))
        return item
    }

    private func toolbarButton(_ image: NSImage, action: Selector) -> NSButton {
        let b = NSButton(image: image, target: self, action: action)
        b.bezelStyle = .texturedRounded
        b.imagePosition = .imageOnly
        b.widthAnchor.constraint(equalToConstant: 38).isActive = true
        return b
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ItemID.sidebar:
            return item(id, label: "サイドバー", tip: "サイドバーの表示／非表示（⌃⌘S）",
                        view: toolbarButton(LegacyIcons.sidebar(left: true), action: #selector(toggleSidebarPressed)))
        case ItemID.navigation:
            navControl.segmentCount = 2
            navControl.trackingMode = .momentary
            navControl.segmentStyle = .texturedRounded
            navControl.setImage(NSImage(named: NSImage.goBackTemplateName), forSegment: 0)
            navControl.setImage(NSImage(named: NSImage.goForwardTemplateName), forSegment: 1)
            navControl.setWidth(30, forSegment: 0)
            navControl.setWidth(30, forSegment: 1)
            // 区切りごとの説明は 10.13 以降なので、全体に付ける
            navControl.toolTip = "前に表示していた階層へ戻る（⌘[）／戻る前の階層へ進む（⌘]）"
            navControl.target = self
            navControl.action = #selector(navigationPressed(_:))
            updateNavigation()
            return item(id, label: "戻る / 進む", tip: "戻る・進む", view: navControl)
        case ItemID.filter:
            filterButton.bezelStyle = .texturedRounded
            filterButton.imagePosition = .imageOnly
            filterButton.target = self
            filterButton.action = #selector(filterPressed(_:))
            filterButton.widthAnchor.constraint(equalToConstant: 38).isActive = true
            updateFilterControls()
            return item(id, label: "絞り込み", tip: "絞り込み・詳細検索", view: filterButton)
        case ItemID.sort:
            sortButton.bezelStyle = .texturedRounded
            (sortButton.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
            sortButton.target = self
            sortButton.action = #selector(sortChosen(_:))
            updateFilterControls()
            return item(id, label: "並べ替え", tip: "並べ替え", view: sortButton, width: 52)
        case ItemID.mode:
            modeButton.bezelStyle = .texturedRounded
            modeButton.removeAllItems()
            for m in GridLayoutMode.allCases {
                modeButton.addItem(withTitle: m.label)
                modeButton.lastItem?.representedObject = m.rawValue
            }
            modeButton.target = self
            modeButton.action = #selector(modeChosen(_:))
            updateGridControls()
            return item(id, label: "並べ方", tip: "サムネイルの並べ方", view: modeButton, width: 110)
        case ItemID.size:
            sizeSlider.minValue = GridSettings.sizeRange.lowerBound
            sizeSlider.maxValue = GridSettings.sizeRange.upperBound
            sizeSlider.controlSize = .small
            sizeSlider.target = self
            sizeSlider.action = #selector(sizeChanged(_:))
            sizeSlider.toolTip = "サムネイルの大きさ"
            columnsStepper.minValue = Double(GridSettings.columnsRange.lowerBound)
            columnsStepper.maxValue = Double(GridSettings.columnsRange.upperBound)
            columnsStepper.target = self
            columnsStepper.action = #selector(columnsChanged(_:))
            columnsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            let columnsRow = NSStackView(views: [columnsLabel, columnsStepper])
            columnsRow.spacing = 4
            let small = NSImageView(image: LegacyIcons.photo(11))
            let large = NSImageView(image: LegacyIcons.photo(16))
            let sliderRow = NSStackView(views: [small, sizeSlider, large])
            sliderRow.spacing = 4
            sizeSlider.widthAnchor.constraint(equalToConstant: 100).isActive = true
            for (i, v) in [sliderRow, columnsRow].enumerated() {
                v.translatesAutoresizingMaskIntoConstraints = false
                v.identifier = NSUserInterfaceItemIdentifier(i == 0 ? "slider" : "stepper")
                sizeContainer.addSubview(v)
                NSLayoutConstraint.activate([
                    v.centerXAnchor.constraint(equalTo: sizeContainer.centerXAnchor),
                    v.centerYAnchor.constraint(equalTo: sizeContainer.centerYAnchor),
                ])
            }
            sizeContainer.frame = NSRect(x: 0, y: 0, width: 150, height: 24)
            updateGridControls()
            return item(id, label: "サイズ", tip: "サムネイルの大きさ・列数", view: sizeContainer, width: 150)
        case ItemID.names:
            namesButton.setButtonType(.pushOnPushOff)
            namesButton.bezelStyle = .texturedRounded
            namesButton.image = LegacyIcons.fileName
            namesButton.imagePosition = .imageOnly
            namesButton.target = self
            namesButton.action = #selector(namesToggled(_:))
            namesButton.widthAnchor.constraint(equalToConstant: 38).isActive = true
            updateGridControls()
            return item(id, label: "ファイル名", tip: "ファイル名を表示", view: namesButton)
        case ItemID.inspector:
            return item(id, label: "プレビューと情報", tip: "右列（プレビューと情報）の表示／非表示（⌃⌘I）",
                        view: toolbarButton(LegacyIcons.sidebar(left: false), action: #selector(toggleInspectorPressed)))
        case ItemID.search:
            searchField.placeholderString = "ファイル名・カメラ・レンズ"
            searchField.sendsSearchStringImmediately = true
            searchField.delegate = self
            searchField.target = self
            searchField.action = #selector(searchChanged(_:))
            return item(id, label: "検索", tip: "ファイル名・カメラ・レンズで検索", view: searchField, width: 220)
        default:
            return nil
        }
    }

    // MARK: ツールバーの動作

    @objc func toggleSidebarPressed() { split.toggleSidebarItem() }
    @objc func toggleInspectorPressed() { split.toggleInspectorItem() }

    @objc private func navigationPressed(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { browser.goBack() } else { browser.goForward() }
    }

    private func updateNavigation() {
        navControl.setEnabled(browser.canGoBack, forSegment: 0)
        navControl.setEnabled(browser.canGoForward, forSegment: 1)
    }

    @objc private func filterPressed(_ sender: NSButton) {
        if let p = filterPopover, p.isShown {
            p.close()
            return
        }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = FilterPanelController()
        p.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        filterPopover = p
    }

    private func updateFilterControls() {
        filterButton.image = LegacyIcons.filter(active: browser.filter.isFiltering)
        let menu = NSMenu()
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "").image = LegacyIcons.sort
        for key in SortKey.allCases {
            let mi = NSMenuItem(title: key.label, action: nil, keyEquivalent: "")
            mi.representedObject = key.rawValue
            mi.state = browser.filter.sortKey == key ? .on : .off
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        for (title, asc) in [("昇順", true), ("降順", false)] {
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.representedObject = asc
            mi.state = browser.filter.ascending == asc ? .on : .off
            menu.addItem(mi)
        }
        sortButton.menu = menu
        sortButton.toolTip = "並べ替え：\(browser.filter.sortKey.label)"
        if searchField.stringValue != browser.filter.text { searchField.stringValue = browser.filter.text }
    }

    @objc private func sortChosen(_ sender: NSPopUpButton) {
        guard let mi = sender.selectedItem else { return }
        if let raw = mi.representedObject as? String, let key = SortKey(rawValue: raw) {
            browser.filter.sortKey = key
        } else if let asc = mi.representedObject as? Bool {
            browser.filter.ascending = asc
        }
    }

    private func updateGridControls() {
        let config = GridViewController.currentConfig()
        if let i = GridLayoutMode.allCases.firstIndex(of: config.mode), modeButton.numberOfItems > i {
            modeButton.selectItem(at: i)
        }
        sizeSlider.doubleValue = config.thumbnailSize
        columnsStepper.integerValue = config.columns
        columnsLabel.stringValue = "\(config.columns) 列"
        for v in sizeContainer.subviews {
            v.isHidden = (v.identifier?.rawValue == "slider") != (config.mode == .size)
        }
        namesButton.state = config.showNames ? .on : .off
    }

    @objc private func modeChosen(_ sender: NSPopUpButton) {
        if let raw = sender.selectedItem?.representedObject as? String {
            UserDefaults.standard.set(raw, forKey: GridSettings.modeKey)
        }
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: GridSettings.thumbnailSizeKey)
    }

    @objc private func columnsChanged(_ sender: NSStepper) {
        UserDefaults.standard.set(sender.integerValue, forKey: GridSettings.columnsKey)
    }

    @objc private func namesToggled(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: GridSettings.showNamesKey)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        browser.filter.text = sender.stringValue
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }
}
