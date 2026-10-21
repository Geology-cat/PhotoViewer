import AppKit
import Quartz

// グリッドの AppKit 部品（通常版とレガシー版で共有する。SwiftUI・Swift の並行処理は使わない）

/// グリッドのレイアウト設定（SwiftUI 側から渡す値）
struct GridLayoutConfig: Equatable {
    var mode: GridLayoutMode
    var thumbnailSize: Double
    var columns: Int
    var showNames: Bool
}

/// クロージャで動作を指定できるメニュー項目
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, image: NSImage? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        self.target = self
        self.image = image
    }

    required init(coder: NSCoder) { fatalError("未対応") }

    @objc private func run() { handler() }
}

/// 列数指定・サイズ指定に応じてセルを並べるレイアウト
/// 並べ方はすべてここで計算する（NSCollectionViewFlowLayout は余った幅をセルの間に振り分けるうえ、
/// 行に入る数を独自に決めるため、間隔を固定しようとすると中途半端な幅で計算が食い違ってセルが重なった）
final class GridLayout: NSCollectionViewLayout {
    var config: GridLayoutConfig?
    static let labelHeight: CGFloat = 20
    static let spacing: CGFloat = 8

    /// セルの大きさ（サムネイルの読み込みサイズの計算にも使う）
    private(set) var itemSize = NSSize(width: 160, height: 160 + labelHeight)
    private(set) var columns = 1
    private var count = 0
    private var width: CGFloat = 0

    /// 列数とセルの幅
    /// セルの間隔は常に spacing に固定し、横幅の余りはセルを少し大きくして埋める
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
        super.prepare()
        guard let cv = collectionView else { return }
        width = cv.enclosingScrollView?.contentView.bounds.width ?? cv.bounds.width
        count = cv.numberOfSections > 0 ? cv.numberOfItems(inSection: 0) : 0
        let config = self.config ?? GridLayoutConfig(mode: .size, thumbnailSize: GridSettings.defaultSize,
                                                     columns: GridSettings.defaultColumns, showNames: true)
        let available = max(width - Self.spacing * 2, 40)
        let (n, side) = Self.columnsAndSide(available: available, mode: config.mode,
                                            thumbnailSize: CGFloat(config.thumbnailSize),
                                            columns: config.columns, spacing: Self.spacing)
        columns = n
        itemSize = NSSize(width: side, height: side + (config.showNames ? Self.labelHeight : 0))
    }

    private var rows: Int { count == 0 ? 0 : (count + columns - 1) / columns }

    override var collectionViewContentSize: NSSize {
        let height = rows == 0 ? 0 : Self.spacing + CGFloat(rows) * (itemSize.height + Self.spacing)
        return NSSize(width: width, height: height)
    }

    private func frame(ofItem item: Int) -> NSRect {
        let row = item / columns, column = item % columns
        return NSRect(x: Self.spacing + CGFloat(column) * (itemSize.width + Self.spacing),
                      y: Self.spacing + CGFloat(row) * (itemSize.height + Self.spacing),
                      width: itemSize.width, height: itemSize.height)
    }

    private func attributes(ofItem item: Int) -> NSCollectionViewLayoutAttributes {
        let a = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: item, section: 0))
        a.frame = frame(ofItem: item)
        return a
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard count > 0 else { return [] }
        let rowHeight = itemSize.height + Self.spacing
        let firstRow = max(0, Int(floor((rect.minY - Self.spacing) / rowHeight)))
        let lastRow = min(rows - 1, Int(floor((rect.maxY - Self.spacing) / rowHeight)))
        guard firstRow <= lastRow else { return [] }
        let first = firstRow * columns, last = min(count - 1, (lastRow + 1) * columns - 1)
        return (first...last).map(attributes(ofItem:)).filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section == 0, (0..<count).contains(indexPath.item) else { return nil }
        return attributes(ofItem: indexPath.item)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != width
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
            moveSelection(event.keyCode == 124 ? 1 : -1, vertical: false, extend: event.modifierFlags.contains(.shift))
        } else if plain, event.keyCode == 125 || event.keyCode == 126 { // ↓ ↑：1 行下・上の同じ列へ
            // 標準の動作は自分が最後に選んだ位置から動くため、←→ で動かした後だとずれる。←→ と同じ位置から動かす
            moveSelection(event.keyCode == 125 ? 1 : -1, vertical: true, extend: event.modifierFlags.contains(.shift))
        } else {
            super.keyDown(with: event)
        }
    }

    /// ←→ キーの移動先（並び順で 1 つ前後。先頭・末尾では止まる。何も選んでいなければ先頭か末尾）
    nonisolated static func horizontalTarget(from current: Int?, delta: Int, count: Int) -> Int {
        guard let current else { return delta > 0 ? 0 : count - 1 }
        return min(max(current + delta, 0), count - 1)
    }

    /// ↑↓ キーの移動先（1 行下・上の同じ列。下の行が短ければその行の最後。上下に行がなければ止まる）
    nonisolated static func verticalTarget(from current: Int?, delta: Int, columns: Int, count: Int) -> Int {
        guard let current else { return delta > 0 ? 0 : count - 1 }
        let cols = max(columns, 1)
        if delta > 0 {
            if current + cols < count { return current + cols }
            // 下に行があれば（最後の行が短いとき）その行の最後へ
            return current / cols < (count - 1) / cols ? count - 1 : current
        }
        return current - cols >= 0 ? current - cols : current
    }

    /// 矢印キーで移動する
    /// - ←→：標準の動作は行の端で止まるため、Finder と同じように行の右端の次は次の行の左端、左端の前は前の行の右端へ進める
    /// - ↑↓：1 行下・上へ
    /// - Parameter extend: Shift を押しているとき。起点から移動先までを選択する
    private func moveSelection(_ delta: Int, vertical: Bool, extend: Bool) {
        let count = numberOfSections > 0 ? numberOfItems(inSection: 0) : 0
        guard count > 0 else { return }
        let current = cursor.flatMap { selectionIndexPaths.contains($0) ? $0 : nil }
            ?? (delta > 0 ? selectionIndexPaths.max() : selectionIndexPaths.min())
        let columns = (collectionViewLayout as? GridLayout)?.columns ?? 1
        let item = vertical
            ? Self.verticalTarget(from: current?.item, delta: delta, columns: columns, count: count)
            : Self.horizontalTarget(from: current?.item, delta: delta, count: count)
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
        #if LEGACY
        panel.dataSource = self
        panel.delegate = self
        #else
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
        #endif
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        #if LEGACY
        panel.dataSource = nil
        panel.delegate = nil
        #else
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
        #endif
    }
}

#if LEGACY
extension PhotoCollectionView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {}
#else
extension PhotoCollectionView: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {}
#endif

extension PhotoCollectionView {
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
