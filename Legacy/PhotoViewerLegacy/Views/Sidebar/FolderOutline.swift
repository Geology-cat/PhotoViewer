import AppKit

/// サイドバーのツリーの 1 行（同じ場所には常に同じインスタンスを使う）
final class FolderItem: NSObject {
    enum Kind {
        case section(String)
        case folder
        case volume(VolumeInfo)
    }

    /// 親からの経路を含む一意なキー（同じフォルダがお気に入りとボリュームの中に出ても別の項目にするため）
    let key: String
    var kind: Kind
    let url: URL?
    var title: String
    /// nil = 子フォルダ未読み込み
    var children: [FolderItem]?
    var isLoading = false

    init(key: String, kind: Kind, url: URL?, title: String) {
        self.key = key
        self.kind = kind
        self.url = url
        self.title = title
    }

    var isSection: Bool {
        if case .section = kind { return true }
        return false
    }

    var volume: VolumeInfo? {
        if case .volume(let v) = kind { return v }
        return nil
    }
}

/// Return キー・右クリックを扱う NSOutlineView
final class FolderOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?

    /// 列の幅をツリーの幅に合わせる
    override func layout() {
        super.layout()
        if let column = tableColumns.first, abs(column.width - bounds.width) > 1, bounds.width > 0 {
            sizeLastColumnToFit()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        return menuProvider?(row)
    }
}

/// サイドバーのフォルダツリー（通常版の FolderOutlineView.Coordinator と同じ動き）
/// - 子フォルダは開いたときに読む（Finder と同じ）
/// - 表示中の起点以下を FSEvents で監視し、フォルダの追加・削除をすぐに反映する
final class FolderTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = FolderOutlineView()
    let scrollView = NSScrollView()

    /// 起点フォルダ（nil = 最上位：よく使う項目・ボリューム）
    private(set) var root: URL?
    private var favorites: [URL] = []
    private var favoriteNames: [URL: String] = [:]
    private var volumes: [VolumeInfo] = []
    var currentFolder: URL? { didSet { syncSelection() } }

    var onSelect: ((URL) -> Void)?
    var onEnter: ((URL) -> Void)?
    var menuFor: ((FolderItem) -> NSMenu?)?
    var onEject: ((VolumeInfo) -> Void)?

    private var roots: [FolderItem] = []
    private var cache: [String: FolderItem] = [:]
    private var itemsByPath: [String: [FolderItem]] = [:]
    private var rootItem: FolderItem?
    private lazy var directoryWatcher = DirectoryEventWatcher { [weak self] paths in self?.directoriesChanged(paths) }
    private var signature = ""
    private var isApplyingSelection = false

    override init() {
        super.init()
        outline.selectionHighlightStyle = .sourceList
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = true
        outline.indentationPerLevel = 14
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.onReturn = { [weak self] in self?.enterSelected() }
        outline.menuProvider = { [weak self] row in
            guard let self = self, let item = self.outline.item(atRow: row) as? FolderItem, !item.isSection else { return nil }
            return self.menuFor?(item)
        }
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
    }

    // MARK: 項目の組み立て

    private func item(key: String, kind: FolderItem.Kind, url: URL?, title: String) -> FolderItem {
        if let existing = cache[key] {
            existing.kind = kind
            existing.title = title
            return existing
        }
        let it = FolderItem(key: key, kind: kind, url: url, title: title)
        cache[key] = it
        if let path = url?.standardizedFileURL.path { itemsByPath[path, default: []].append(it) }
        return it
    }

    private func folderItem(_ url: URL, parentKey: String, title: String? = nil) -> FolderItem {
        item(key: "\(parentKey)>\(url.path)", kind: .folder, url: url, title: title ?? url.lastPathComponent)
    }

    /// 起点・お気に入り・ボリュームを設定する（変わったときだけ作り直す）
    func update(root: URL?, favorites: [URL], favoriteNames: [URL: String], volumes: [VolumeInfo]) {
        self.root = root
        self.favorites = favorites
        self.favoriteNames = favoriteNames
        self.volumes = volumes
        let sig = [root?.path ?? "<top>",
                   favorites.map { "\($0.path)=\(favoriteNames[$0] ?? "")" }.joined(separator: "|"),
                   volumes.map { "\($0.url.path)#\($0.kind.rawValue)#\($0.name)" }.joined(separator: "|")]
            .joined(separator: "\n")
        guard sig != signature else {
            // 空き容量の表示だけ更新する
            for v in volumes {
                if let it = cache["vol>\(v.url.path)"] {
                    it.kind = .volume(v)
                    let row = outline.row(forItem: it)
                    if row >= 0 { outline.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
                }
            }
            return
        }
        let rootChanged = signature.components(separatedBy: "\n").first != sig.components(separatedBy: "\n").first
        signature = sig
        let expanded = rootChanged ? [] : expandedKeys()

        if let root {
            let rootItem = item(key: "root>\(root.path)", kind: .folder, url: root, title: root.lastPathComponent)
            self.rootItem = rootItem
            roots = rootItem.children ?? []
            load(rootItem, isRoot: true)
        } else {
            rootItem = nil
            var sections: [FolderItem] = []
            let fav = item(key: "sec>fav", kind: .section("よく使う項目"), url: nil, title: "よく使う項目")
            fav.children = favorites.map { folderItem($0, parentKey: "fav", title: favoriteNames[$0]) }
            sections.append(fav)
            let grouped = Dictionary(grouping: volumes, by: \.kind)
            for kind in grouped.keys.sorted() {
                let sec = item(key: "sec>vol\(kind.rawValue)", kind: .section(kind.sectionTitle), url: nil,
                               title: kind.sectionTitle)
                sec.children = grouped[kind]!.map { v in
                    item(key: "vol>\(v.url.path)", kind: .volume(v), url: v.url, title: v.name)
                }
                sections.append(sec)
            }
            roots = sections
        }
        outline.reloadData()
        for r in roots where r.isSection { outline.expandItem(r) }
        restoreExpanded(expanded)
        syncSelection()
        directoryWatcher.watch(root.map { [$0.path] } ?? (favorites.map(\.path) + volumes.map(\.url.path)))
    }

    /// 中身が変わったフォルダを読み直す（子を読み込み済みの項目だけ）
    private func directoriesChanged(_ paths: [String]) {
        for raw in paths {
            var path = raw
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            for item in itemsByPath[path] ?? [] {
                if item === rootItem {
                    load(item, isRoot: true)
                } else if item.children != nil {
                    load(item)
                }
            }
        }
    }

    private func expandedKeys() -> [String] {
        (0..<outline.numberOfRows).compactMap { row in
            guard let it = outline.item(atRow: row) as? FolderItem, !it.isSection, outline.isItemExpanded(it)
            else { return nil }
            return it.key
        }
    }

    private func restoreExpanded(_ keys: [String]) {
        for k in keys {
            if let it = cache[k], outline.row(forItem: it) >= 0 { outline.expandItem(it) }
        }
    }

    /// 子フォルダを読む。読み終わったらその項目だけを描き直す
    private func load(_ item: FolderItem, isRoot: Bool = false) {
        guard let url = item.url, !item.isLoading || isRoot else { return }
        item.isLoading = true
        let parentKey = item.key
        runInBackground({
            FolderScanner.subfolders(of: url).map { ($0, FolderTreeModel.displayName($0)) }
        }, then: { entries in
            item.isLoading = false
            let newChildren = entries.map { self.folderItem($0.0, parentKey: parentKey, title: $0.1) }
            let changed = item.children.map { $0.map(\.key) != newChildren.map(\.key) } ?? true
            item.children = newChildren
            if isRoot {
                guard self.root == url, changed || self.roots.isEmpty else { return }
                self.roots = newChildren
                self.outline.reloadData()
                self.syncSelection()
            } else if changed || newChildren.isEmpty {
                self.outline.reloadItem(item, reloadChildren: true)
                self.syncSelection()
            }
        })
    }

    // MARK: 選択

    /// 表示中のフォルダの行を選択状態にする（見えていなければ選択を外す。自動では開かない）
    func syncSelection() {
        var target = -1
        if let cur = currentFolder?.standardizedFileURL {
            for row in 0..<outline.numberOfRows {
                if let it = outline.item(atRow: row) as? FolderItem, it.url?.standardizedFileURL == cur {
                    target = row
                    break
                }
            }
        }
        guard outline.selectedRow != target else { return }
        isApplyingSelection = true
        if target >= 0 {
            outline.selectRowIndexes([target], byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
        isApplyingSelection = false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection, let it = outline.item(atRow: outline.selectedRow) as? FolderItem,
              let url = it.url else { return }
        onSelect?(url)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard outline.clickedRow >= 0, let it = outline.item(atRow: outline.clickedRow) as? FolderItem,
              let url = it.url else { return }
        onEnter?(url)
    }

    private func enterSelected() {
        guard let it = outline.item(atRow: outline.selectedRow) as? FolderItem, let url = it.url else { return }
        onEnter?(url)
    }

    // MARK: データソース

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let it = item as? FolderItem else { return roots.count }
        return it.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let it = item as? FolderItem else { return roots[index] }
        return it.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let it = item as? FolderItem else { return false }
        if it.isSection { return true }
        return it.children.map { !$0.isEmpty } ?? true
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let it = notification.userInfo?["NSObject"] as? FolderItem, !it.isSection else { return }
        load(it)
    }

    // MARK: 表示

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? FolderItem)?.isSection ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !((item as? FolderItem)?.isSection ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        !((item as? FolderItem)?.isSection ?? false)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let it = item as? FolderItem else { return nil }
        if it.isSection {
            let id = NSUserInterfaceItemIdentifier("section")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = id
                let tf = NSTextField(labelWithString: "")
                tf.font = .systemFont(ofSize: 11, weight: .semibold)
                tf.textColor = .secondaryLabelColor
                tf.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(tf)
                c.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    tf.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = it.title
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: FolderCellView.identifier, owner: nil) as? FolderCellView
            ?? FolderCellView()
        cell.configure(it, onEject: { [weak self] v in self?.onEject?(v) })
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let it = item as? FolderItem else { return 24 }
        if it.isSection { return 26 }
        return it.volume?.capacityText != nil ? 36 : 24
    }
}

/// フォルダ・ボリュームの行（アイコン・名前・空き容量・取り出しボタン）
final class FolderCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("folder")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let ejectButton = NSButton(image: LegacyIcons.eject, target: nil, action: nil)
    private var volume: VolumeInfo?
    private var onEject: ((VolumeInfo) -> Void)?
    private var ejectWidth: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        imageView = icon
        textField = title

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ejectButton.translatesAutoresizingMaskIntoConstraints = false
        ejectButton.isBordered = false
        ejectButton.bezelStyle = .regularSquare
        ejectButton.toolTip = "取り出す"
        ejectButton.target = self
        ejectButton.action = #selector(eject)

        let texts = NSStackView(views: [title, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        texts.translatesAutoresizingMaskIntoConstraints = false
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        texts.setHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(icon)
        addSubview(texts)
        addSubview(ejectButton)
        ejectWidth = ejectButton.widthAnchor.constraint(equalToConstant: 16)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            texts.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.trailingAnchor.constraint(equalTo: ejectButton.leadingAnchor, constant: -4),
            ejectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            ejectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ejectWidth,
        ])
    }

    required init?(coder: NSCoder) { fatalError("未対応") }

    func configure(_ item: FolderItem, onEject: @escaping (VolumeInfo) -> Void) {
        self.onEject = onEject
        title.stringValue = item.title
        toolTip = item.url?.path
        if let v = item.volume {
            volume = v
            icon.image = LegacyIcons.drive(v.kind)
            title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: v.kind == .external ? .semibold : .regular)
            detail.stringValue = v.capacityText ?? ""
            detail.isHidden = v.capacityText == nil
            ejectButton.isHidden = !v.kind.isEjectable
            ejectWidth.constant = v.kind.isEjectable ? 16 : 0
        } else {
            volume = nil
            icon.image = LegacyIcons.folder
            title.font = .systemFont(ofSize: NSFont.systemFontSize)
            detail.isHidden = true
            ejectButton.isHidden = true
            ejectWidth.constant = 0
        }
    }

    @objc private func eject() {
        if let volume { onEject?(volume) }
    }
}
