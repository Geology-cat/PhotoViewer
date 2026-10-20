import AppKit
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
    var selection: Set<URL>
    var layoutConfig: GridLayoutConfig
    var onSelectionChange: (Set<URL>, URL?) -> Void
    var onOpen: ([URL]) -> Void

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
        coordinator.dataSource = NSCollectionViewDiffableDataSource<Int, URL>(collectionView: cv) {
            [weak coordinator] collectionView, indexPath, url in
            let item = collectionView.makeItem(withIdentifier: PhotoGridItem.identifier, for: indexPath)
            if let cell = item as? PhotoGridItem, let coordinator, let photo = coordinator.itemsByURL[url] {
                cell.configure(photo, pixelSize: coordinator.pixelSize, showName: coordinator.layout?.config?.showNames ?? true)
            }
            return item
        }
        cv.onOpen = { [weak coordinator] urls in coordinator?.parent?.onOpen(urls) }
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

        // ファイル一覧の変更
        let ids = items.map(\.url)
        if ids != c.currentIDs {
            let folderChanged = items.first?.url.deletingLastPathComponent()
                != c.currentIDs.first?.deletingLastPathComponent()
            c.itemsByURL = Dictionary(items.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
            c.currentIDs = ids
            var snapshot = NSDiffableDataSourceSnapshot<Int, URL>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids, toSection: 0)
            ds.apply(snapshot, animatingDifferences: false)
            if folderChanged {
                cv.scroll(.zero)
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
        var dataSource: NSCollectionViewDiffableDataSource<Int, URL>?
        var itemsByURL: [URL: PhotoItem] = [:]
        var currentIDs: [URL] = []
        var isApplyingSelection = false
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
                    cell.configure(photo, pixelSize: pixelSize, showName: showNames)
                }
            }
        }

        private func notifySelection(lastAddedPaths: Set<IndexPath>) {
            guard !isApplyingSelection, let cv = collectionView, let ds = dataSource else { return }
            let urls = Set(cv.selectionIndexPaths.compactMap { ds.itemIdentifier(for: $0) })
            let last = lastAddedPaths.max().flatMap { ds.itemIdentifier(for: $0) }
            parent?.onSelectionChange(urls, last)
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            notifySelection(lastAddedPaths: indexPaths)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            notifySelection(lastAddedPaths: [])
        }
    }
}

/// 列数指定・サイズ指定に応じてセルの大きさを決めるレイアウト
final class GridLayout: NSCollectionViewFlowLayout {
    var config: GridLayoutConfig?
    private var lastWidth: CGFloat = 0
    static let labelHeight: CGFloat = 20
    static let spacing: CGFloat = 8

    override init() {
        super.init()
        minimumInteritemSpacing = Self.spacing
        minimumLineSpacing = Self.spacing
        sectionInset = NSEdgeInsets(top: Self.spacing, left: Self.spacing, bottom: Self.spacing, right: Self.spacing)
    }

    required init?(coder: NSCoder) { fatalError("未対応") }

    override func prepare() {
        if let cv = collectionView, let config {
            let width = cv.enclosingScrollView?.contentView.bounds.width ?? cv.bounds.width
            lastWidth = width
            let available = max(width - sectionInset.left - sectionInset.right, 40)
            let side: CGFloat
            switch config.mode {
            case .size:
                side = min(CGFloat(config.thumbnailSize), available)
            case .columns:
                let n = CGFloat(max(config.columns, 1))
                side = floor((available - Self.spacing * (n - 1)) / n)
            }
            itemSize = NSSize(width: side, height: side + (config.showNames ? Self.labelHeight : 0))
        }
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != lastWidth || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
}

/// ダブルクリック・キー操作を扱うためのサブクラス
final class PhotoCollectionView: NSCollectionView {
    var onOpen: (([URL]) -> Void)?
    var urlsForIndexPaths: ((Set<IndexPath>) -> [URL])?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            let p = convert(event.locationInWindow, from: nil)
            if let path = indexPathForItem(at: p), let urls = urlsForIndexPaths?([path]) {
                onOpen?(urls)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return / Enter：選択中のファイルを開く
            if let urls = urlsForIndexPaths?(selectionIndexPaths), !urls.isEmpty {
                onOpen?(urls)
            }
        default:
            super.keyDown(with: event)
        }
    }
}
