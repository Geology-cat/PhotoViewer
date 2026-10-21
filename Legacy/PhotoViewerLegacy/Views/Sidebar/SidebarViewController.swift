import AppKit

/// 上の階層へ・親フォルダの一覧（通常版の SidebarNavigation と同じ）
enum SidebarNavigation {
    /// 自分自身を除く、親フォルダの一覧（近い順。最後が「/」）。必ず止まるようにしている
    static func ancestors(of url: URL) -> [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL
        for _ in 0..<64 {
            if current.path == "/" || current.path.isEmpty { break }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path || parent.path.isEmpty || parent.path.hasSuffix("/..") { break }
            result.append(parent)
            current = parent
        }
        return result
    }

    /// リスト表示の起点を 1 つ上の階層にする（外付けなどのドライブの一番上からは一覧に戻る）
    static func goUp(browser: BrowserModel, volumes: [VolumeInfo]) {
        guard !browser.listRoot.isEmpty else { return }
        let root = URL(fileURLWithPath: browser.listRoot, isDirectory: true)
        let rootStd = root.standardizedFileURL.path
        if volumes.contains(where: { $0.kind != .internal && $0.url.standardizedFileURL.path == rootStd }) {
            browser.listRoot = ""
            return
        }
        guard root.path != "/" else { return }
        let parent = root.deletingLastPathComponent()
        browser.navigate(listRoot: parent.standardizedFileURL.path, folder: parent)
    }
}

/// 左列：表示方式（リスト／アイコン）の切り替えと中身
final class SidebarViewController: NSViewController {
    private let browser = BrowserModel.shared
    private let tree = FolderTreeModel.shared
    private let styleControl = NSSegmentedControl(labels: ["リスト", "アイコン"], trackingMode: .selectOne,
                                                  target: nil, action: nil)
    private let container = NSView()
    private lazy var listController = FolderListViewController()
    private lazy var iconController = FolderIconViewController()
    private static let styleKey = "sidebar.style"

    override func loadView() {
        let v = NSView()
        styleControl.translatesAutoresizingMaskIntoConstraints = false
        styleControl.target = self
        styleControl.action = #selector(styleChanged)
        container.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(styleControl)
        v.addSubview(container)
        NSLayoutConstraint.activate([
            styleControl.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            styleControl.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            styleControl.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            container.topAnchor.constraint(equalTo: styleControl.bottomAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            v.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let isIcon = UserDefaults.standard.string(forKey: Self.styleKey) == "icon"
        styleControl.selectedSegment = isIcon ? 1 : 0
        show(isIcon ? iconController : listController)
        // ドライブが外されたら、そのドライブ上のフォルダを表示し続けない
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumeUnmounted(_:)),
                                                          name: NSWorkspace.didUnmountNotification, object: nil)
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func styleChanged() {
        let isIcon = styleControl.selectedSegment == 1
        UserDefaults.standard.set(isIcon ? "icon" : "list", forKey: Self.styleKey)
        show(isIcon ? iconController : listController)
    }

    private func show(_ vc: NSViewController) {
        children.forEach { $0.view.removeFromSuperview(); $0.removeFromParent() }
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            vc.view.topAnchor.constraint(equalTo: container.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    @objc private func volumeUnmounted(_ note: Notification) {
        guard let vol = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        let prefix = vol.standardizedFileURL.path
        func isOn(_ path: String) -> Bool { path == prefix || path.hasPrefix(prefix + "/") }
        if !browser.listRoot.isEmpty && isOn(browser.listRoot) { browser.listRoot = "" }
        if let cur = browser.currentFolder, isOn(cur.standardizedFileURL.path) { browser.closeFolder() }
    }
}

// MARK: - 小さな部品

/// 枠なしのアイコンボタン
func plainButton(_ image: NSImage, tip: String, target: AnyObject?, action: Selector) -> NSButton {
    let b = NSButton(image: image, target: target, action: action)
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.toolTip = tip
    b.setContentHuggingPriority(.required, for: .horizontal)
    return b
}

/// 「＜」「＞」：前に表示していた階層へ戻る・戻る前の階層へ進む
final class NavigationButtons: NSStackView {
    private let browser = BrowserModel.shared
    private var back: NSButton!
    private var forward: NSButton!

    init() {
        super.init(frame: .zero)
        back = plainButton(NSImage(named: NSImage.goBackTemplateName)!, tip: "戻る（⌘[）", target: self, action: #selector(goBack))
        forward = plainButton(NSImage(named: NSImage.goForwardTemplateName)!, tip: "進む（⌘]）", target: self,
                              action: #selector(goForward))
        spacing = 2
        addArrangedSubview(back)
        addArrangedSubview(forward)
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: .browserLocationChanged, object: browser)
        update()
    }

    required init?(coder: NSCoder) { fatalError("未対応") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func update() {
        back.isEnabled = browser.canGoBack
        forward.isEnabled = browser.canGoForward
    }

    @objc private func goBack() { browser.goBack() }
    @objc private func goForward() { browser.goForward() }
}

/// ドライブのタブ 1 つ（丸い枠のボタン。外付けはオレンジの枠）
final class DriveTab: NSView {
    var onClick: (() -> Void)?
    var isActive = false { didSet { needsDisplay = true; updateFont() } }
    private let emphasized: Bool
    private let tint: NSColor
    private let label = NSTextField(labelWithString: "")

    init(title: String, icon: NSImage, tint: NSColor, emphasized: Bool, help: String) {
        self.emphasized = emphasized
        self.tint = tint
        super.init(frame: .zero)
        toolTip = help
        let iv = NSImageView(image: icon)
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 13).isActive = true
        iv.heightAnchor.constraint(equalToConstant: 13).isActive = true
        label.stringValue = title
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 110).isActive = true
        let s = NSStackView(views: [iv, label])
        s.spacing = 3
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            s.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            s.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        updateFont()
    }

    required init?(coder: NSCoder) { fatalError("未対応") }

    private func updateFont() {
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: emphasized || isActive ? .semibold : .regular)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        (isActive ? accentColor.withAlphaComponent(0.22) : NSColor.labelColor.withAlphaComponent(0.05)).setFill()
        path.fill()
        if emphasized {
            tint.withAlphaComponent(0.6).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - リスト表示（ツリー）

/// Finder のリスト表示のように、フォルダをダブルクリック（または Return）するとその中に入り、
/// そのフォルダから下の階層だけをツリーで表示する
final class FolderListViewController: NSViewController {
    private let browser = BrowserModel.shared
    private let tree = FolderTreeModel.shared
    private let treeController = FolderTreeController()

    private let topBar = NSStackView()
    private let tabsStack = NSStackView()
    private let tabsScroll = NSScrollView()
    private let header = NSStackView()
    private let volumeBadge = NSTextField(labelWithString: "")
    private let volumeBox = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let upButton = plainButton(LegacyIcons.goUp, tip: "上の階層へ（⌘↑）", target: nil, action: #selector(goUp))
    private let ancestorsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var rootVolume: VolumeInfo?
    private var ancestors: [(url: URL, name: String)] = []
    private var checkedRoot: String?

    private static let tabRootsKey = "sidebar.driveTabRoots"

    private var rootURL: URL? {
        browser.listRoot.isEmpty ? nil : URL(fileURLWithPath: browser.listRoot, isDirectory: true)
    }

    override func loadView() {
        let v = NSView()

        // 一覧にいるときの見出し
        let topLabel = NSTextField(labelWithString: "よく使う項目・ドライブ")
        topLabel.font = .boldSystemFont(ofSize: 13)
        topLabel.lineBreakMode = .byTruncatingTail
        topLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        topBar.setViews([NavigationButtons(), topLabel], in: .leading)
        topBar.spacing = 4
        topBar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 4, right: 10)

        // ドライブのタブ（横スクロール）
        tabsStack.spacing = 4
        tabsStack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        tabsStack.translatesAutoresizingMaskIntoConstraints = false
        let tabsDoc = FlippedView()
        tabsDoc.translatesAutoresizingMaskIntoConstraints = false
        tabsDoc.addSubview(tabsStack)
        tabsScroll.documentView = tabsDoc
        tabsScroll.hasHorizontalScroller = false
        tabsScroll.drawsBackground = false
        NSLayoutConstraint.activate([
            tabsStack.leadingAnchor.constraint(equalTo: tabsDoc.leadingAnchor),
            tabsStack.topAnchor.constraint(equalTo: tabsDoc.topAnchor),
            tabsStack.bottomAnchor.constraint(equalTo: tabsDoc.bottomAnchor),
            tabsStack.trailingAnchor.constraint(equalTo: tabsDoc.trailingAnchor),
            tabsDoc.heightAnchor.constraint(equalTo: tabsScroll.contentView.heightAnchor),
            tabsDoc.topAnchor.constraint(equalTo: tabsScroll.contentView.topAnchor),
            tabsDoc.leadingAnchor.constraint(equalTo: tabsScroll.contentView.leadingAnchor),
            tabsScroll.heightAnchor.constraint(equalToConstant: 30),
        ])

        // 起点フォルダの見出し：どのドライブか・戻る/進む・上の階層へ・名前・親フォルダ・一覧へ戻る
        volumeBadge.font = .systemFont(ofSize: 11, weight: .semibold)
        volumeBadge.lineBreakMode = .byTruncatingMiddle
        volumeBadge.translatesAutoresizingMaskIntoConstraints = false
        volumeBox.wantsLayer = true
        volumeBox.layer?.cornerRadius = 8
        volumeBox.addSubview(volumeBadge)
        NSLayoutConstraint.activate([
            volumeBadge.leadingAnchor.constraint(equalTo: volumeBox.leadingAnchor, constant: 6),
            volumeBadge.trailingAnchor.constraint(equalTo: volumeBox.trailingAnchor, constant: -6),
            volumeBadge.topAnchor.constraint(equalTo: volumeBox.topAnchor, constant: 2),
            volumeBadge.bottomAnchor.constraint(equalTo: volumeBox.bottomAnchor, constant: -2),
        ])
        upButton.target = self
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        ancestorsButton.isBordered = false
        ancestorsButton.toolTip = "親フォルダへ移動"
        ancestorsButton.target = self
        ancestorsButton.action = #selector(ancestorChosen(_:))
        (ancestorsButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        ancestorsButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        let listButton = plainButton(LegacyIcons.favorites, tip: "よく使う項目・ドライブの一覧に戻る", target: self,
                                     action: #selector(backToList))
        let row = NSStackView(views: [NavigationButtons(), upButton, titleLabel, ancestorsButton, listButton])
        row.spacing = 4
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        header.addArrangedSubview(volumeBox)
        header.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -20).isActive = true

        let stack = NSStackView(views: [topBar, tabsScroll, Self.separator(), header, treeController.scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for sub in stack.arrangedSubviews {
            sub.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        treeController.scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        view = v
    }

    private static func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        treeController.onSelect = { [weak self] url in self?.browser.open(folder: url) }
        treeController.onEnter = { [weak self] url in self?.enter(url) }
        treeController.menuFor = { [weak self] item in self?.menu(for: item) }
        treeController.onEject = { [weak self] v in self?.eject(v) }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(refresh), name: .browserLocationChanged, object: browser)
        nc.addObserver(self, selector: #selector(refresh), name: .folderTreeChanged, object: tree)
        nc.addObserver(self, selector: #selector(folderChanged), name: .browserFolderChanged, object: browser)
        refresh()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func folderChanged() {
        treeController.currentFolder = browser.currentFolder
    }

    @objc private func refresh() {
        let root = rootURL
        topBar.isHidden = root != nil
        header.isHidden = root == nil
        if browser.listRoot != checkedRoot {
            checkedRoot = browser.listRoot
            checkRoot()
        }
        rebuildTabs()
        treeController.update(root: root, favorites: tree.favorites, favoriteNames: tree.favoriteNames,
                              volumes: tree.volumes)
        treeController.currentFolder = browser.currentFolder
        upButton.isEnabled = root.map { $0.path != "/" } ?? false
    }

    // MARK: 起点の見出し

    /// 起点の確認・名前・親フォルダ・ドライブの情報をバックグラウンドで用意する
    private func checkRoot() {
        guard let root = rootURL else {
            rootVolume = nil
            ancestors = []
            updateHeader()
            return
        }
        titleLabel.stringValue = root.lastPathComponent
        let path = browser.listRoot
        runInBackground({ () -> (Bool, String, [(url: URL, name: String)], VolumeInfo?) in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
            guard exists else { return (false, "", [], nil) }
            return (true, FolderTreeModel.displayName(root),
                    SidebarNavigation.ancestors(of: root).map { ($0, FolderTreeModel.displayName($0)) },
                    VolumeInfo.containing(root))
        }, then: { exists, title, ancestors, volume in
            guard self.browser.listRoot == path else { return }
            guard exists else {
                // フォルダが消えた・ドライブが外されたときは一覧に戻る
                self.browser.listRoot = ""
                return
            }
            self.titleLabel.stringValue = title
            self.ancestors = ancestors
            self.rootVolume = volume
            self.updateHeader()
            self.rebuildTabs()
        })
    }

    private func updateHeader() {
        titleLabel.toolTip = browser.listRoot
        if let v = rootVolume {
            volumeBox.isHidden = false
            let s = NSMutableAttributedString(string: "\(v.name)  ", attributes: [.foregroundColor: v.kind.tint])
            s.append(NSAttributedString(string: v.kind.sectionTitle, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            s.addAttribute(.font, value: NSFont.systemFont(ofSize: 11, weight: .semibold), range: NSRange(location: 0, length: s.length))
            volumeBadge.attributedStringValue = s
            volumeBox.layer?.backgroundColor = v.kind.tint.withAlphaComponent(0.15).cgColor
            volumeBox.toolTip = v.capacityText ?? v.kind.sectionTitle
        } else {
            volumeBox.isHidden = true
        }
        ancestorsButton.removeAllItems()
        ancestorsButton.addItem(withTitle: "")
        ancestorsButton.lastItem?.image = NSImage(named: NSImage.actionTemplateName)
        for a in ancestors {
            ancestorsButton.addItem(withTitle: a.name)
            let icon = a.url.path == "/" ? LegacyIcons.drive(.internal) : LegacyIcons.folder
            icon.size = NSSize(width: 16, height: 16)
            ancestorsButton.lastItem?.image = icon
            ancestorsButton.lastItem?.representedObject = a.url
        }
    }

    @objc private func ancestorChosen(_ sender: NSPopUpButton) {
        if let url = sender.selectedItem?.representedObject as? URL { enter(url) }
    }

    @objc private func goUp() {
        SidebarNavigation.goUp(browser: browser, volumes: tree.volumes)
    }

    @objc private func backToList() {
        browser.listRoot = ""
    }

    private func enter(_ url: URL) {
        browser.navigate(listRoot: url.standardizedFileURL.path, folder: url)
    }

    // MARK: ドライブのタブ

    private func savedRoot(for volume: URL) -> String? {
        (UserDefaults.standard.dictionary(forKey: Self.tabRootsKey) as? [String: String])?[volume.path]
    }

    private func rememberCurrentRoot() {
        guard !browser.listRoot.isEmpty, let v = rootVolume else { return }
        var d = (UserDefaults.standard.dictionary(forKey: Self.tabRootsKey) as? [String: String]) ?? [:]
        d[v.url.path] = browser.listRoot
        UserDefaults.standard.set(d, forKey: Self.tabRootsKey)
    }

    private func rebuildTabs() {
        tabsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let topIcon = LegacyIcons.star(filled: true, color: .systemYellow, size: 13)
        let top = DriveTab(title: "よく使う項目", icon: topIcon, tint: .systemYellow, emphasized: false,
                           help: "よく使う項目・ドライブの一覧")
        top.isActive = browser.listRoot.isEmpty
        top.onClick = { [weak self] in
            self?.rememberCurrentRoot()
            self?.browser.listRoot = ""
        }
        tabsStack.addArrangedSubview(top)
        let active = browser.listRoot.isEmpty ? nil : rootVolume?.url.standardizedFileURL
        for v in tree.volumes {
            let tab = DriveTab(title: v.name, icon: LegacyIcons.drive(v.kind, size: 13), tint: v.kind.tint,
                               emphasized: v.kind == .external,
                               help: "\(v.name)（\(v.kind.sectionTitle)）" + (v.capacityText.map { "\n\($0)" } ?? ""))
            tab.isActive = active == v.url.standardizedFileURL
            tab.onClick = { [weak self] in self?.selectDriveTab(v) }
            tabsStack.addArrangedSubview(tab)
        }
    }

    /// タブを押すと、そのドライブで最後にいたフォルダに戻る。表示中のタブをもう一度押すとドライブの一番上へ
    private func selectDriveTab(_ v: VolumeInfo) {
        let isActive = !browser.listRoot.isEmpty && rootVolume?.url.standardizedFileURL == v.url.standardizedFileURL
        rememberCurrentRoot()
        guard !isActive, let saved = savedRoot(for: v.url) else {
            enter(v.url)
            return
        }
        runInBackground({ () -> Bool in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: saved, isDirectory: &isDir) && isDir.boolValue
        }, then: { exists in
            self.enter(exists ? URL(fileURLWithPath: saved, isDirectory: true) : v.url)
        })
    }

    // MARK: 右クリック・取り出し

    private func menu(for item: FolderItem) -> NSMenu? {
        guard let url = item.url else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("このフォルダに入る") { [weak self] in self?.enter(url) })
        menu.addItem(.separator())
        if tree.isFavorite(url) {
            menu.addItem(ClosureMenuItem("よく使う項目から削除") { [tree] in tree.removeFavorite(url) })
        } else {
            menu.addItem(ClosureMenuItem("よく使う項目に追加") { [tree] in tree.addFavorite(url) })
        }
        menu.addItem(ClosureMenuItem("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        if let v = item.volume, v.kind.isEjectable {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("「\(v.name)」を取り出す") { [weak self] in self?.eject(v) })
        }
        return menu
    }

    private func eject(_ v: VolumeInfo) {
        tree.eject(v) { [weak self] error in
            guard let error, let window = self?.view.window else { return }
            let alert = NSAlert()
            alert.messageText = "取り出せませんでした"
            alert.informativeText = "「\(v.name)」：\(error)\n使用中のファイルがあれば閉じてから、もう一度試してください。"
            alert.beginSheetModal(for: window)
        }
    }
}

// MARK: - アイコン表示

/// アイコン表示：クリックでそのフォルダを表示、ダブルクリックで中に入る
final class FolderIconViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private let browser = BrowserModel.shared
    private let tree = FolderTreeModel.shared
    /// 中身を表示しているフォルダ（nil = よく使う項目・ドライブの一覧）
    private var location: URL?
    private var entries: [(url: URL, name: String, kind: VolumeKind?)] = []
    private let titleLabel = NSTextField(labelWithString: "場所")
    private let upButton = plainButton(NSImage(named: NSImage.goBackTemplateName)!, tip: "上のフォルダへ", target: nil,
                                       action: #selector(goUp))
    private let collection = FolderIconCollectionView()
    private var loadGeneration = 0

    override func loadView() {
        let v = NSView()
        upButton.target = self
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [upButton, titleLabel])
        bar.spacing = 4
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 4, right: 8)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 76, height: 84)
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.backgroundColors = [.clear]
        collection.register(FolderIconItem.self, forItemWithIdentifier: FolderIconItem.identifier)
        collection.dataSource = self
        collection.delegate = self
        collection.onDoubleClick = { [weak self] index in self?.enterEntry(at: index) }
        collection.menuProvider = { [weak self] index in self?.menu(at: index) }
        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(bar)
        v.addSubview(sep)
        v.addSubview(scroll)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: v.topAnchor),
            bar.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            sep.topAnchor.constraint(equalTo: bar.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        location = browser.currentFolder
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .folderTreeChanged, object: tree)
        NotificationCenter.default.addObserver(self, selector: #selector(syncSelection), name: .browserFolderChanged,
                                               object: browser)
        reload()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func reload() {
        upButton.isEnabled = location != nil
        titleLabel.stringValue = location?.lastPathComponent ?? "場所"
        guard let location else {
            entries = tree.favorites.map { ($0, tree.favoriteNames[$0] ?? $0.lastPathComponent, nil) }
                + tree.volumes.map { ($0.url, $0.name, $0.kind) }
            collection.reloadData()
            syncSelection()
            return
        }
        loadGeneration += 1
        let gen = loadGeneration
        runInBackground({ FolderScanner.subfolders(of: location) }, then: { urls in
            guard gen == self.loadGeneration else { return }
            self.entries = urls.map { ($0, $0.lastPathComponent, nil) }
            self.collection.reloadData()
            self.syncSelection()
        })
    }

    @objc private func syncSelection() {
        let cur = browser.currentFolder?.standardizedFileURL
        let index = entries.firstIndex { $0.url.standardizedFileURL == cur }
        collection.selectionIndexPaths = index.map { [IndexPath(item: $0, section: 0)] } ?? []
    }

    @objc private func goUp() {
        guard let loc = location else { return }
        let roots = Set((tree.favorites + tree.volumes.map(\.url)).map(\.standardizedFileURL))
        location = roots.contains(loc.standardizedFileURL) || loc.path == "/" ? nil : loc.deletingLastPathComponent()
        reload()
    }

    private func enterEntry(at index: Int) {
        guard entries.indices.contains(index) else { return }
        location = entries[index].url
        reload()
    }

    private func menu(at index: Int) -> NSMenu? {
        guard entries.indices.contains(index) else { return nil }
        let url = entries[index].url
        let menu = NSMenu()
        if tree.isFavorite(url) {
            menu.addItem(ClosureMenuItem("よく使う項目から削除") { [tree] in tree.removeFavorite(url) })
        } else {
            menu.addItem(ClosureMenuItem("よく使う項目に追加") { [tree] in tree.addFavorite(url) })
        }
        menu.addItem(ClosureMenuItem("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        return menu
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FolderIconItem.identifier, for: indexPath)
        if let cell = item as? FolderIconItem {
            let e = entries[indexPath.item]
            cell.configure(name: e.name, kind: e.kind)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let i = indexPaths.first?.item, entries.indices.contains(i) else { return }
        browser.open(folder: entries[i].url)
    }
}

/// ダブルクリック・右クリックを扱うコレクションビュー
final class FolderIconCollectionView: NSCollectionView {
    var onDoubleClick: ((Int) -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            onDoubleClick?(path.item)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return menuProvider?(path.item)
    }
}

/// アイコン表示の 1 マス（ディスクに触らない共通のアイコン）
final class FolderIconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FolderIconItem")
    private let icon = NSImageView()
    private let badge = NSImageView()
    private let name = NSTextField(labelWithString: "")

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        icon.frame = NSRect(x: 14, y: 32, width: 48, height: 48)
        icon.imageScaling = .scaleProportionallyUpOrDown
        badge.frame = NSRect(x: 46, y: 30, width: 18, height: 18)
        name.frame = NSRect(x: 2, y: 2, width: 72, height: 28)
        name.font = .systemFont(ofSize: 11)
        name.alignment = .center
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingMiddle
        v.addSubview(icon)
        v.addSubview(badge)
        v.addSubview(name)
        view = v
    }

    func configure(name: String, kind: VolumeKind?) {
        self.name.stringValue = name
        icon.image = kind != nil ? NSImage(named: NSImage.computerName) : LegacyIcons.folder
        badge.image = kind.map { LegacyIcons.drive($0, size: 18) }
        badge.isHidden = kind == nil
        view.toolTip = (kind.map { "\($0.sectionTitle)：" } ?? "") + "クリックで表示、ダブルクリックで中に入る"
    }

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = isSelected ? accentColor.withAlphaComponent(0.25).cgColor : nil }
    }
}
