import AppKit
import Quartz

/// グリッドのデータソース（一覧が変わったら丸ごと読み直す。通常版の GridDataSource と同じ）
final class GridDataSource: NSObject, NSCollectionViewDataSource {
    typealias CellProvider = (NSCollectionView, IndexPath, URL) -> NSCollectionViewItem
    private weak var collectionView: NSCollectionView?
    private let cellProvider: CellProvider
    private(set) var ids: [URL] = []
    private var indexByURL: [URL: Int] = [:]

    init(collectionView: NSCollectionView, cellProvider: @escaping CellProvider) {
        self.collectionView = collectionView
        self.cellProvider = cellProvider
        super.init()
        collectionView.dataSource = self
    }

    func apply(_ newIDs: [URL]) {
        ids = newIDs
        indexByURL = Dictionary(newIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        collectionView?.reloadData()
    }

    func itemIdentifier(for indexPath: IndexPath) -> URL? {
        ids.indices.contains(indexPath.item) ? ids[indexPath.item] : nil
    }

    func indexPath(for url: URL) -> IndexPath? {
        indexByURL[url].map { IndexPath(item: $0, section: 0) }
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        ids.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        cellProvider(collectionView, indexPath, ids[indexPath.item])
    }
}

/// 中央のサムネイルグリッド
final class GridViewController: NSViewController, NSCollectionViewDelegate {
    private let browser = BrowserModel.shared
    private let settings = AppSettings.shared
    private(set) var collectionView: PhotoCollectionView!
    private var layout: GridLayout!
    private var dataSource: GridDataSource!
    private var itemsByURL: [URL: PhotoItem] = [:]
    private var isApplyingSelection = false
    private var lastPixelBucket = 0
    private var observers: [NSObjectProtocol] = []

    /// フォルダ未選択・写真なしなどの案内と、読み込み中の印
    private let messageLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func loadView() {
        layout = GridLayout()
        layout.config = Self.currentConfig()
        let cv = PhotoCollectionView()
        cv.collectionViewLayout = layout
        cv.isSelectable = true
        cv.allowsMultipleSelection = true
        cv.allowsEmptySelection = true
        cv.backgroundColors = [.clear]
        cv.register(PhotoGridItem.self, forItemWithIdentifier: PhotoGridItem.identifier)
        cv.delegate = self
        collectionView = cv

        dataSource = GridDataSource(collectionView: cv) { [weak self] collectionView, indexPath, url in
            let item = collectionView.makeItem(withIdentifier: PhotoGridItem.identifier, for: indexPath)
            if let cell = item as? PhotoGridItem, let self = self, let photo = self.itemsByURL[url] {
                cell.configure(photo, pixelSize: self.pixelSize, showName: self.layout.config?.showNames ?? true,
                               tags: self.browser.tags(for: url))
            }
            return item
        }
        cv.onOpen = { [weak self] urls in self?.settings.open(urls) }
        cv.menuProvider = { [weak self] urls in self?.contextMenu(for: urls) }
        cv.onRate = { [weak self] urls, r in self?.browser.setRating(r, for: urls) }
        cv.onToggleDeveloped = { [weak self] urls in self?.browser.toggleDeveloped(for: urls) }
        cv.onTrash = { [weak self] urls in self?.browser.moveToTrash(urls, undoManager: self?.undoManager) }
        cv.onClickSelectionChange = { [weak self] added in self?.notifySelection(lastAddedPaths: added) }
        cv.urlsForIndexPaths = { [weak self] paths in
            guard let ds = self?.dataSource else { return [] }
            return paths.sorted().compactMap { ds.itemIdentifier(for: $0) }
        }

        let scroll = NSScrollView()
        scroll.documentView = cv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let container = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.maximumNumberOfLines = 0
        container.addSubview(messageLabel)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(spinner)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            // 中央のグリッドはサムネイル 1 列分まで狭くできる
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let nc = NotificationCenter.default
        func on(_ name: Notification.Name, object: Any? = nil, _ handler: @escaping () -> Void) {
            observers.append(nc.addObserver(forName: name, object: object, queue: .main) { _ in handler() })
        }
        on(.browserDisplayedChanged, object: browser) { [weak self] in self?.reloadItems() }
        on(.browserSelectionChanged, object: browser) { [weak self] in self?.syncSelection() }
        on(.browserTagsChanged, object: browser) { [weak self] in self?.refreshBadges() }
        on(.browserFolderChanged, object: browser) { [weak self] in self?.updateMessage() }
        on(UserDefaults.didChangeNotification) { [weak self] in self?.applyLayoutSettings() }
        reloadItems()
    }

    // MARK: レイアウト設定

    static func currentConfig() -> GridLayoutConfig {
        let d = UserDefaults.standard
        let mode = GridLayoutMode(rawValue: d.string(forKey: GridSettings.modeKey) ?? "") ?? .size
        let size = d.object(forKey: GridSettings.thumbnailSizeKey) as? Double ?? GridSettings.defaultSize
        let columns = d.object(forKey: GridSettings.columnsKey) as? Int ?? GridSettings.defaultColumns
        let showNames = d.object(forKey: GridSettings.showNamesKey) as? Bool ?? true
        return GridLayoutConfig(mode: mode, thumbnailSize: size, columns: columns, showNames: showNames)
    }

    private func applyLayoutSettings() {
        let config = Self.currentConfig()
        guard layout.config != config else { return }
        let namesChanged = layout.config?.showNames != config.showNames
        layout.config = config
        layout.invalidateLayout()
        collectionView.layoutSubtreeIfNeeded()
        refreshVisibleIfPixelSizeChanged(force: namesChanged)
    }

    /// サムネイルとして要求するピクセルサイズ
    private var pixelSize: Int {
        let scale = collectionView?.window?.backingScaleFactor ?? 2
        return Int(layout.itemSize.width * scale)
    }

    private func refreshVisibleIfPixelSizeChanged(force: Bool) {
        let bucket = ThumbnailLoader.bucket(for: pixelSize)
        guard force || bucket != lastPixelBucket else { return }
        lastPixelBucket = bucket
        let showNames = layout.config?.showNames ?? true
        for case let cell as PhotoGridItem in collectionView.visibleItems() {
            if let url = cell.representedURL, let photo = itemsByURL[url] {
                cell.configure(photo, pixelSize: pixelSize, showName: showNames, tags: browser.tags(for: url))
            }
        }
    }

    // MARK: 一覧・選択・★

    private func reloadItems() {
        let items = browser.displayedItems
        let folderChanged = items.first?.url.deletingLastPathComponent()
            != dataSource.ids.first?.deletingLastPathComponent()
        itemsByURL = Dictionary(items.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        dataSource.apply(items.map(\.url))
        if folderChanged { collectionView.scroll(.zero) }
        syncSelection()
        updateMessage()
    }

    private func syncSelection() {
        let current = Set(collectionView.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
        guard current != browser.selection else { return }
        isApplyingSelection = true
        collectionView.selectionIndexPaths = Set(browser.selection.compactMap { dataSource.indexPath(for: $0) })
        isApplyingSelection = false
    }

    private func refreshBadges() {
        for case let cell as PhotoGridItem in collectionView.visibleItems() {
            if let url = cell.representedURL { cell.updateBadges(browser.tags(for: url)) }
        }
    }

    private func updateMessage() {
        if browser.currentFolder == nil {
            messageLabel.stringValue = "フォルダを選択してください\n左のサイドバーからフォルダを選ぶか、⇧⌘O でフォルダを開きます。"
            messageLabel.isHidden = false
            spinner.stopAnimation(nil)
        } else if browser.isScanning && browser.items.isEmpty {
            messageLabel.isHidden = true
            spinner.startAnimation(nil)
        } else if !browser.isScanning && browser.displayedItems.isEmpty {
            spinner.stopAnimation(nil)
            messageLabel.stringValue = browser.filter.isFiltering && !browser.items.isEmpty
                ? "条件に一致する写真がありません" : "写真がありません"
            messageLabel.isHidden = false
        } else {
            spinner.stopAnimation(nil)
            messageLabel.isHidden = true
        }
    }

    private func notifySelection(lastAddedPaths: Set<IndexPath>) {
        guard !isApplyingSelection else { return }
        let urls = Set(collectionView.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
        let last = lastAddedPaths.max().flatMap { dataSource.itemIdentifier(for: $0) }
        browser.updateSelection(urls, lastAdded: last)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        (collectionView as? PhotoCollectionView)?.resetAnchor(to: indexPaths.max())
        notifySelection(lastAddedPaths: indexPaths)
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        notifySelection(lastAddedPaths: [])
    }

    /// グリッドにキー操作を向ける
    func focus() {
        view.window?.makeFirstResponder(collectionView)
    }

    // MARK: 右クリックメニュー

    private func contextMenu(for urls: [URL]) -> NSMenu {
        let menu = NSMenu()
        let title = urls.count == 1 ? "開く" : "\(urls.count) 件を開く"
        menu.addItem(ClosureMenuItem(title) { [settings] in settings.open(urls) })

        // 「このアプリで開く」：選択中の拡張子すべてを開けるアプリを候補にする
        let exts = Set(urls.map { $0.pathExtension.lowercased() })
        var candidates: [URL]?
        for e in exts {
            let apps = AppSettings.candidateApps(forExtension: e)
            candidates = candidates.map { c in c.filter { apps.contains($0) } } ?? apps
        }
        let sub = NSMenu()
        for app in candidates ?? [] {
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            sub.addItem(ClosureMenuItem(AppAssociation(appURL: app).name, image: icon) { [settings] in
                settings.open(urls, withApplicationAt: app)
            })
        }
        if sub.items.isEmpty { sub.addItem(NSMenuItem(title: "候補なし", action: nil, keyEquivalent: "")) }
        let openWith = NSMenuItem(title: "このアプリで開く", action: nil, keyEquivalent: "")
        openWith.submenu = sub
        menu.addItem(openWith)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("名前を一括変更…") { [browser] in browser.onRenameRequest?(urls) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting(urls) })
        menu.addItem(ClosureMenuItem("パスをコピー") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("ゴミ箱に入れる") { [weak self] in
            self?.browser.moveToTrash(urls, undoManager: self?.undoManager)
        })
        return menu
    }
}
