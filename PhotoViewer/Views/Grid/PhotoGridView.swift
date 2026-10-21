import AppKit
import Quartz
import SwiftUI

/// グリッドのレイアウト設定（SwiftUI 側から渡す値）
struct GridLayoutConfig: Equatable {
    var mode: GridLayoutMode
    var thumbnailSize: Double
    var columns: Int
    var showNames: Bool
}

/// サムネイルグリッド（NSCollectionView をラップ）
struct PhotoGridView: NSViewRepresentable {
    var items: [PhotoItem]
    /// 一覧が変わるたびに増える番号（数千件の中身を毎回比べないため）
    var itemsVersion: Int
    var selection: Set<URL>
    var layoutConfig: GridLayoutConfig
    var onSelectionChange: (Set<URL>, URL?) -> Void
    var onOpen: ([URL]) -> Void
    /// レーティング・現像済みの取得と、変更の合図
    var tagsFor: (URL) -> PhotoTags
    var tagsVersion: Int
    /// 数字キー 0〜5 でレーティング
    var onRate: ([URL], Int) -> Void
    /// D キーで現像済みを切り替え
    var onToggleDeveloped: ([URL]) -> Void
    /// ⌘⌫ でゴミ箱へ（グリッドにフォーカスがあるときだけ。検索欄での ⌘⌫ と区別するため）
    var onTrash: ([URL]) -> Void
    /// 右クリックメニュー（対象のファイルを受け取って作る）
    var contextMenu: ([URL]) -> NSMenu?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = GridLayout()
        let cv = PhotoCollectionView()
        cv.collectionViewLayout = layout
        cv.isSelectable = true
        cv.allowsMultipleSelection = true
        cv.allowsEmptySelection = true
        cv.backgroundColors = [.clear]
        cv.register(PhotoGridItem.self, forItemWithIdentifier: PhotoGridItem.identifier)
        cv.delegate = context.coordinator

        let coordinator = context.coordinator
        coordinator.collectionView = cv
        coordinator.layout = layout
        coordinator.dataSource = GridDataSource(collectionView: cv) {
            [weak coordinator] collectionView, indexPath, url in
            let item = collectionView.makeItem(withIdentifier: PhotoGridItem.identifier, for: indexPath)
            if let cell = item as? PhotoGridItem, let coordinator, let photo = coordinator.itemsByURL[url] {
                cell.configure(photo, pixelSize: coordinator.pixelSize,
                               showName: coordinator.layout?.config?.showNames ?? true,
                               tags: coordinator.parent?.tagsFor(url) ?? .empty)
            }
            return item
        }
        cv.onOpen = { [weak coordinator] urls in coordinator?.parent?.onOpen(urls) }
        cv.menuProvider = { [weak coordinator] urls in coordinator?.parent?.contextMenu(urls) }
        cv.onRate = { [weak coordinator] urls, r in coordinator?.parent?.onRate(urls, r) }
        cv.onToggleDeveloped = { [weak coordinator] urls in coordinator?.parent?.onToggleDeveloped(urls) }
        cv.onTrash = { [weak coordinator] urls in coordinator?.parent?.onTrash(urls) }
        cv.onClickSelectionChange = { [weak coordinator] added in coordinator?.selectionChangedByClick(added) }
        cv.urlsForIndexPaths = { [weak coordinator] paths in
            guard let ds = coordinator?.dataSource else { return [] }
            return paths.sorted().compactMap { ds.itemIdentifier(for: $0) }
        }

        let scroll = NSScrollView()
        scroll.documentView = cv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let cv = c.collectionView, let layout = c.layout, let ds = c.dataSource else { return }

        // レイアウト設定の変更
        if layout.config != layoutConfig {
            let namesChanged = layout.config?.showNames != layoutConfig.showNames
            layout.config = layoutConfig
            layout.invalidateLayout()
            cv.layoutSubtreeIfNeeded()
            c.refreshVisibleIfPixelSizeChanged(force: namesChanged)
        }

        // ファイル一覧の変更（番号が変わったときだけ中身を見る）
        if itemsVersion != c.currentVersion {
            c.currentVersion = itemsVersion
        }
        let ids = c.currentVersion == c.appliedVersion ? c.currentIDs : items.map(\.url)
        if c.currentVersion != c.appliedVersion {
            c.appliedVersion = c.currentVersion
        }
        if ids != c.currentIDs {
            let folderChanged = items.first?.url.deletingLastPathComponent()
                != c.currentIDs.first?.deletingLastPathComponent()
            c.itemsByURL = Dictionary(items.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
            c.currentIDs = ids
            ds.apply(ids)
            if folderChanged {
                cv.scroll(.zero)
            }
        }

        // レーティング等の変更：見えているセルのバッジだけ更新する
        if c.lastTagsVersion != tagsVersion {
            c.lastTagsVersion = tagsVersion
            for case let cell as PhotoGridItem in cv.visibleItems() {
                if let url = cell.representedURL { cell.updateBadges(tagsFor(url)) }
            }
        }

        // 選択状態の同期（ユーザー操作で変わった場合は一致しているので何もしない）
        let current = Set(cv.selectionIndexPaths.compactMap { ds.itemIdentifier(for: $0) })
        if current != selection {
            c.isApplyingSelection = true
            cv.selectionIndexPaths = Set(selection.compactMap { ds.indexPath(for: $0) })
            c.isApplyingSelection = false
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegate {
        var parent: PhotoGridView?
        weak var collectionView: PhotoCollectionView?
        var layout: GridLayout?
        var dataSource: GridDataSource?
        var itemsByURL: [URL: PhotoItem] = [:]
        var currentIDs: [URL] = []
        var currentVersion = -1
        var appliedVersion = -2
        var isApplyingSelection = false
        var lastTagsVersion = -1
        private var lastPixelBucket = 0

        /// サムネイルとして要求するピクセルサイズ
        var pixelSize: Int {
            let scale = collectionView?.window?.backingScaleFactor ?? 2
            return Int((layout?.itemSize.width ?? 160) * scale)
        }

        /// 表示サイズが別の段階に変わったら、見えているセルを読み直す
        func refreshVisibleIfPixelSizeChanged(force: Bool) {
            let bucket = ThumbnailLoader.bucket(for: pixelSize)
            guard force || bucket != lastPixelBucket, let cv = collectionView else { return }
            lastPixelBucket = bucket
            let showNames = layout?.config?.showNames ?? true
            for case let cell as PhotoGridItem in cv.visibleItems() {
                if let url = cell.representedURL, let photo = itemsByURL[url] {
                    cell.configure(photo, pixelSize: pixelSize, showName: showNames,
                                   tags: parent?.tagsFor(url) ?? .empty)
                }
            }
        }

        private func notifySelection(lastAddedPaths: Set<IndexPath>) {
            guard !isApplyingSelection, let cv = collectionView, let ds = dataSource else { return }
            let urls = Set(cv.selectionIndexPaths.compactMap { ds.itemIdentifier(for: $0) })
            let last = lastAddedPaths.max().flatMap { ds.itemIdentifier(for: $0) }
            parent?.onSelectionChange(urls, last)
            // Quick Look を表示中なら選択に合わせて切り替える
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().reloadData()
            }
        }

        func selectionChangedByClick(_ added: Set<IndexPath>) {
            notifySelection(lastAddedPaths: added)
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            (collectionView as? PhotoCollectionView)?.resetAnchor(to: indexPaths.max())
            notifySelection(lastAddedPaths: indexPaths)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            notifySelection(lastAddedPaths: [])
        }
    }
}

/// グリッドのデータソース
/// 差分を計算して 1 件ずつ移動させる方式（NSCollectionViewDiffableDataSource）は、
/// 数千件の並べ替え・絞り込みのたびに重くなるため、一覧が変わったら丸ごと読み直す方式にした
@MainActor
final class GridDataSource: NSObject, NSCollectionViewDataSource {
    typealias CellProvider = (NSCollectionView, IndexPath, URL) -> NSCollectionViewItem
    private weak var collectionView: NSCollectionView?
    private let cellProvider: CellProvider
    private var ids: [URL] = []
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

/// 列数指定・サイズ指定に応じてセルの大きさを決めるレイアウト
final class GridLayout: NSCollectionViewFlowLayout {
    var config: GridLayoutConfig?
    private var lastWidth: CGFloat = 0
    /// 1 行に並べる数（セルの左端の位置を揃えるのに使う）
    private var columns = 1
    static let labelHeight: CGFloat = 20
    static let spacing: CGFloat = 8

    override init() {
        super.init()
        minimumInteritemSpacing = Self.spacing
        minimumLineSpacing = Self.spacing
        sectionInset = NSEdgeInsets(top: Self.spacing, left: Self.spacing, bottom: Self.spacing, right: Self.spacing)
    }

    required init?(coder: NSCoder) { fatalError("未対応") }

    /// 列数とセルの幅
    /// セルの間隔は常に spacing に固定し、横幅の余りはセルを少し大きくして埋める
    /// （大きさをそのまま使うと、余りが全部セルの間に振り分けられ、大きさを変えるたびに間隔が大きく広がるため）
    nonisolated static func columnsAndSide(available: CGFloat, mode: GridLayoutMode, thumbnailSize: CGFloat,
                                           columns: Int, spacing: CGFloat) -> (columns: Int, side: CGFloat) {
        let n: Int
        switch mode {
        case .size:
            n = max(1, Int(floor((available + spacing) / (max(thumbnailSize, 1) + spacing))))
        case .columns:
            n = max(columns, 1)
        }
        let side = floor((available - spacing * CGFloat(n - 1)) / CGFloat(n))
        return (n, max(side, 1))
    }

    override func prepare() {
        if let cv = collectionView, let config {
            let width = cv.enclosingScrollView?.contentView.bounds.width ?? cv.bounds.width
            lastWidth = width
            let available = max(width - sectionInset.left - sectionInset.right, 40)
            let (n, side) = Self.columnsAndSide(available: available, mode: config.mode,
                                                thumbnailSize: CGFloat(config.thumbnailSize),
                                                columns: config.columns, spacing: Self.spacing)
            columns = n
            itemSize = NSSize(width: side, height: side + (config.showNames ? Self.labelHeight : 0))
        }
        super.prepare()
    }

    // 最後の行など列が埋まらない行も、間隔を広げずに左から詰めて並べる
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        super.layoutAttributesForElements(in: rect).map(aligned)
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        super.layoutAttributesForItem(at: indexPath).map(aligned)
    }

    private func aligned(_ attributes: NSCollectionViewLayoutAttributes) -> NSCollectionViewLayoutAttributes {
        guard attributes.representedElementCategory == .item, let path = attributes.indexPath else { return attributes }
        let copy = attributes.copy() as! NSCollectionViewLayoutAttributes
        let column = path.item % max(columns, 1)
        copy.frame.origin.x = sectionInset.left + CGFloat(column) * (itemSize.width + Self.spacing)
        return copy
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != lastWidth || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
}

/// ダブルクリック・キー操作を扱うためのサブクラス
final class PhotoCollectionView: NSCollectionView {
    var onOpen: (([URL]) -> Void)?
    var urlsForIndexPaths: ((Set<IndexPath>) -> [URL])?
    var menuProvider: (([URL]) -> NSMenu?)?
    var onRate: (([URL], Int) -> Void)?
    var onToggleDeveloped: (([URL]) -> Void)?
    var onTrash: (([URL]) -> Void)?

    /// 右クリック：未選択のセルならそのセルだけを選択してからメニューを出す
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let path = indexPathForItem(at: p) else { return nil }
        if !selectionIndexPaths.contains(path) {
            deselectAll(nil)
            selectItems(at: [path], scrollPosition: [])
            delegate?.collectionView?(self, didSelectItemsAt: [path])
        }
        guard let urls = urlsForIndexPaths?(selectionIndexPaths), !urls.isEmpty else { return nil }
        return menuProvider?(urls)
    }

    /// クリックで選択を変えたときの通知（引数は新しく選択に加わったセル）
    var onClickSelectionChange: ((Set<IndexPath>) -> Void)?

    /// 直前にクリックしたセル（別のセルを素早く続けてクリックしたときにダブルクリック扱いしないため）
    private var lastClickedPath: IndexPath?
    /// Shift＋クリックの範囲選択の起点と、起点を決めたときの選択（⌘ で選んでいたものを残すため）
    private var anchor: IndexPath?
    private var anchorBase: Set<IndexPath> = []

    /// キー操作などクリック以外で選択が変わったときは、Shift＋クリックの起点もそこに合わせる
    func resetAnchor(to path: IndexPath?) {
        anchor = path
        anchorBase = selectionIndexPaths
        cursor = path
    }
    /// ←→ キーで最後に移動した位置（Shift で範囲を広げているときの先端）
    private var cursor: IndexPath?
    /// 複数選択中の選択済みセルをクリックしたとき、ダブルクリックでなければ少し後で 1 つにする
    private var pendingCollapse: DispatchWorkItem?

    /// Finder と同じクリック操作
    /// - クリック：その 1 枚だけを選択（複数選択中の選択済みをクリックしたときは、ダブルクリックに備えて少し待つ）
    /// - ⌘＋クリック：その 1 枚を選択に加える／外す（飛び飛びに選べる）
    /// - Shift＋クリック：起点からクリックしたセルまでの間をすべて選択
    /// - ダブルクリック：選択中のセルをダブルクリックしたら、選択中のファイルをすべて開く
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let path = indexPathForItem(at: point) else {
            // 何もない所：範囲をドラッグして選ぶ操作などは標準のまま
            lastClickedPath = nil
            pendingCollapse?.cancel()
            super.mouseDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .shift])
        let previous = lastClickedPath
        lastClickedPath = path
        cursor = path

        if event.clickCount >= 2 {
            pendingCollapse?.cancel()
            pendingCollapse = nil
            guard flags.isEmpty, path == previous else { return }
            let targets = selectionIndexPaths.contains(path) ? selectionIndexPaths : [path]
            if let urls = urlsForIndexPaths?(targets), !urls.isEmpty { onOpen?(urls) }
            return
        }
        pendingCollapse?.cancel()
        pendingCollapse = nil

        if flags.contains(.shift) {
            let start = anchor ?? selectionIndexPaths.min() ?? path
            let lo = min(start.item, path.item), hi = max(start.item, path.item)
            let range = Set((lo...hi).map { IndexPath(item: $0, section: path.section) })
            if anchor == nil {
                anchor = start
                anchorBase = selectionIndexPaths
            }
            applyClickSelection(anchorBase.union(range), added: [path])
            return
        }
        if flags.contains(.command) {
            var sel = selectionIndexPaths
            let adding = !sel.contains(path)
            if adding { sel.insert(path) } else { sel.remove(path) }
            applyClickSelection(sel, added: adding ? [path] : [])
            anchor = path
            anchorBase = sel
            return
        }
        if selectionIndexPaths.contains(path) && selectionIndexPaths.count > 1 {
            // 複数選択中の選択済みセル：ダブルクリックかもしれないので、すぐには 1 つにしない
            anchor = path
            anchorBase = [path]
            let work = DispatchWorkItem { [weak self] in
                self?.applyClickSelection([path], added: [path])
            }
            pendingCollapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
            return
        }
        super.mouseDown(with: event)
        anchor = path
        anchorBase = selectionIndexPaths
    }

    private func applyClickSelection(_ selection: Set<IndexPath>, added: Set<IndexPath>) {
        guard selection != selectionIndexPaths else { return }
        selectionIndexPaths = selection
        onClickSelectionChange?(added)
    }

    override func keyDown(with event: NSEvent) {
        let urls = urlsForIndexPaths?(selectionIndexPaths) ?? []
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        let chars = event.charactersIgnoringModifiers ?? ""
        if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter：選択中のファイルを開く
            if !urls.isEmpty { onOpen?(urls) }
        } else if plain, let n = Int(chars), (0...5).contains(n) { // 0〜5：レーティング
            if !urls.isEmpty { onRate?(urls, n) }
        } else if plain, chars.lowercased() == "d" { // D：現像済みの切り替え
            if !urls.isEmpty { onToggleDeveloped?(urls) }
        } else if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                  event.keyCode == 51 { // ⌘⌫：ゴミ箱へ
            if !urls.isEmpty { onTrash?(urls) }
        } else if plain, chars == " " { // Space：Quick Look
            toggleQuickLook()
        } else if plain, event.keyCode == 123 || event.keyCode == 124 { // ← →：行の端では前後の行へ回り込む
            moveHorizontally(by: event.keyCode == 124 ? 1 : -1, extend: event.modifierFlags.contains(.shift))
        } else {
            super.keyDown(with: event)
        }
    }

    /// ←→ キーの移動先（並び順で 1 つ前後。先頭・末尾では止まる。何も選んでいなければ先頭か末尾）
    nonisolated static func horizontalTarget(from current: Int?, delta: Int, count: Int) -> Int {
        guard let current else { return delta > 0 ? 0 : count - 1 }
        return min(max(current + delta, 0), count - 1)
    }

    /// ←→ キーで 1 つ前後へ移動する
    /// 標準の動作は行の端で止まるため、Finder と同じように行の右端の次は次の行の左端、左端の前は前の行の右端へ進める
    /// - Parameter extend: Shift を押しているとき。起点から移動先までを選択する
    private func moveHorizontally(by delta: Int, extend: Bool) {
        let count = numberOfSections > 0 ? numberOfItems(inSection: 0) : 0
        guard count > 0 else { return }
        let current = cursor.flatMap { selectionIndexPaths.contains($0) ? $0 : nil }
            ?? (delta > 0 ? selectionIndexPaths.max() : selectionIndexPaths.min())
        let item = Self.horizontalTarget(from: current?.item, delta: delta, count: count)
        let next = IndexPath(item: item, section: 0)
        let newSelection: Set<IndexPath>
        if extend {
            let start = anchor ?? current ?? next
            if anchor == nil {
                anchor = start
                anchorBase = selectionIndexPaths
            }
            let lo = min(start.item, item), hi = max(start.item, item)
            newSelection = anchorBase.union((lo...hi).map { IndexPath(item: $0, section: 0) })
        } else {
            newSelection = [next]
            anchor = next
            anchorBase = [next]
        }
        cursor = next
        pendingCollapse?.cancel()
        pendingCollapse = nil
        scrollToItems(at: [next], scrollPosition: .nearestHorizontalEdge)
        applyClickSelection(newSelection, added: [next])
    }

    // MARK: - Quick Look

    private var quickLookURLs: [URL] = []

    func toggleQuickLook() {
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    // Quick Look のパネルはメインスレッドから呼ばれる
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

extension PhotoCollectionView: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    private var selectedURLs: [URL] { urlsForIndexPaths?(selectionIndexPaths) ?? [] }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = selectedURLs
        return urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    /// Quick Look 表示中の矢印キーなどはグリッドに渡して選択を動かす
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        keyDown(with: event)
        return true
    }
}
