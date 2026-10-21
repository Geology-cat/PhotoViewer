import AppKit
import Quartz
import SwiftUI

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
