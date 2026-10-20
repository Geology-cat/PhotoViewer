import AppKit
import SwiftUI

/// サイドバーのツリーの 1 行（NSOutlineView の項目。同じ場所には常に同じインスタンスを使う）
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

/// サイドバーのフォルダツリー（Finder のサイドバー・リスト表示と同じ NSOutlineView を使う）
/// SwiftUI の List で開閉グループを入れ子にすると、子を後から読み込んだときに行が重なって表示されることがあるため
struct FolderOutlineView: NSViewRepresentable {
    /// 起点フォルダ（nil = 最上位：よく使う項目・ボリューム）
    var root: URL?
    var favorites: [URL]
    var volumes: [VolumeInfo]
    var currentFolder: URL?
    var onSelect: (URL) -> Void
    var onEnter: (URL) -> Void
    var menuFor: (FolderItem) -> NSMenu?
    var onEject: (VolumeInfo) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = FolderOutline()
        outline.style = .sourceList
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = true
        outline.indentationPerLevel = 14
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let c = context.coordinator
        c.outline = outline
        outline.dataSource = c
        outline.delegate = c
        outline.target = c
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.onReturn = { [weak c] in c?.enterSelected() }
        outline.menuProvider = { [weak c] row in
            guard let c, let item = c.outline?.item(atRow: row) as? FolderItem, !item.isSection else { return nil }
            return c.parent?.menuFor(item)
        }

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.rebuildIfNeeded()
        c.syncSelection()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: FolderOutlineView?
        weak var outline: FolderOutline?
        private var roots: [FolderItem] = []
        private var cache: [String: FolderItem] = [:]
        private var signature = ""
        private var isApplyingSelection = false

        // MARK: 項目の組み立て

        private func item(key: String, kind: FolderItem.Kind, url: URL?, title: String) -> FolderItem {
            if let existing = cache[key] {
                existing.kind = kind
                existing.title = title
                return existing
            }
            let it = FolderItem(key: key, kind: kind, url: url, title: title)
            cache[key] = it
            return it
        }

        private func folderItem(_ url: URL, parentKey: String) -> FolderItem {
            item(key: "\(parentKey)>\(url.path)", kind: .folder, url: url, title: FolderTree.displayName(url))
        }

        /// 起点・お気に入り・ボリュームが変わったときだけ作り直す（他の再描画では何もしない）
        func rebuildIfNeeded() {
            guard let p = parent, let outline else { return }
            let sig = [p.root?.path ?? "<top>", p.favorites.map(\.path).joined(separator: "|"),
                       p.volumes.map { "\($0.url.path)#\($0.kind.rawValue)#\($0.name)" }.joined(separator: "|")]
                .joined(separator: "\n")
            guard sig != signature else {
                // 空き容量の表示だけ更新する
                for v in p.volumes {
                    if let it = cache["vol>\(v.url.path)"] { it.kind = .volume(v) }
                }
                return
            }
            let rootChanged = signature.components(separatedBy: "\n").first != sig.components(separatedBy: "\n").first
            signature = sig
            // 開いていた項目を覚えておき、作り直した後に開き直す
            let expanded = rootChanged ? [] : expandedKeys()

            if let root = p.root {
                let rootItem = item(key: "root>\(root.path)", kind: .folder, url: root, title: FolderTree.displayName(root))
                roots = rootItem.children ?? []
                // 前に読んだ子があればまず表示し、読み直して変化があれば差し替える
                load(rootItem, isRoot: true)
            } else {
                var sections: [FolderItem] = []
                let fav = item(key: "sec>fav", kind: .section("よく使う項目"), url: nil, title: "よく使う項目")
                fav.children = p.favorites.map { folderItem($0, parentKey: "fav") }
                sections.append(fav)
                let grouped = Dictionary(grouping: p.volumes, by: \.kind)
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
        }

        private func expandedKeys() -> [String] {
            guard let outline else { return [] }
            return (0..<outline.numberOfRows).compactMap { row in
                guard let it = outline.item(atRow: row) as? FolderItem, !it.isSection, outline.isItemExpanded(it)
                else { return nil }
                return it.key
            }
        }

        private func restoreExpanded(_ keys: [String]) {
            guard let outline else { return }
            for k in keys {
                if let it = cache[k], outline.row(forItem: it) >= 0 { outline.expandItem(it) }
            }
        }

        /// 子フォルダを読む。読み終わったらその項目だけを描き直す
        private func load(_ item: FolderItem, isRoot: Bool = false) {
            guard let url = item.url, !item.isLoading || isRoot else { return }
            item.isLoading = true
            let parentKey = item.key
            Task {
                let urls = await Task.detached(priority: .userInitiated) { FolderScanner.subfolders(of: url) }.value
                item.isLoading = false
                let newChildren = urls.map { self.folderItem($0, parentKey: parentKey) }
                let changed = item.children.map { $0.map(\.key) != newChildren.map(\.key) } ?? true
                item.children = newChildren
                guard let outline = self.outline else { return }
                if isRoot {
                    // 起点が変わっていなければ一覧を差し替える
                    guard self.parent?.root == url, changed || self.roots.isEmpty else { return }
                    self.roots = newChildren
                    outline.reloadData()
                    self.syncSelection()
                } else if changed || newChildren.isEmpty {
                    outline.reloadItem(item, reloadChildren: true)
                    self.syncSelection()
                }
            }
        }

        // MARK: 選択

        /// 表示中のフォルダの行を選択状態にする（見えていなければ選択を外す。自動では開かない）
        func syncSelection() {
            guard let outline else { return }
            var target = -1
            if let cur = parent?.currentFolder?.standardizedFileURL {
                for row in 0..<outline.numberOfRows {
                    if let it = outline.item(atRow: row) as? FolderItem, it.url?.standardizedFileURL == cur {
                        target = row
                        break
                    }
                }
            }
            let current = outline.selectedRow
            guard current != target else { return }
            isApplyingSelection = true
            if target >= 0 {
                outline.selectRowIndexes([target], byExtendingSelection: false)
            } else {
                outline.deselectAll(nil)
            }
            isApplyingSelection = false
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let outline,
                  let it = outline.item(atRow: outline.selectedRow) as? FolderItem, let url = it.url else { return }
            parent?.onSelect(url)
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let outline, outline.clickedRow >= 0,
                  let it = outline.item(atRow: outline.clickedRow) as? FolderItem, let url = it.url else { return }
            parent?.onEnter(url)
        }

        func enterSelected() {
            guard let outline, let it = outline.item(atRow: outline.selectedRow) as? FolderItem,
                  let url = it.url else { return }
            parent?.onEnter(url)
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
            // 未読み込みなら開閉ボタンを出しておき、開いたときに読む（Finder と同じ）
            return it.children.map { !$0.isEmpty } ?? true
        }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let it = notification.userInfo?["NSObject"] as? FolderItem, !it.isSection else { return }
            // 開くたびに読み直して、フォルダの追加・削除を反映する
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
            // 見出しの「表示／非表示」は出さない
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
            cell.configure(it, onEject: { [weak self] v in self?.parent?.onEject(v) })
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let it = item as? FolderItem else { return 24 }
            if it.isSection { return 26 }
            return it.volume?.capacityText != nil ? 36 : 24
        }
    }
}

/// Return キー・右クリックを扱う NSOutlineView
final class FolderOutline: NSOutlineView {
    var onReturn: (() -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?

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

/// フォルダ・ボリュームの行（アイコン・名前・空き容量・取り出しボタン）
final class FolderCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("folder")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let ejectButton = NSButton()
    private var volume: VolumeInfo?
    private var onEject: ((VolumeInfo) -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        imageView = icon
        textField = title

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ejectButton.translatesAutoresizingMaskIntoConstraints = false
        ejectButton.bezelStyle = .inline
        ejectButton.isBordered = false
        ejectButton.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "取り出す")
        ejectButton.contentTintColor = .secondaryLabelColor
        ejectButton.toolTip = "取り出す"
        ejectButton.target = self
        ejectButton.action = #selector(eject)

        let texts = NSStackView(views: [title, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        texts.translatesAutoresizingMaskIntoConstraints = false
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(icon)
        addSubview(texts)
        addSubview(ejectButton)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            texts.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: ejectButton.leadingAnchor, constant: -4),
            ejectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            ejectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ejectButton.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("未対応") }

    func configure(_ item: FolderItem, onEject: @escaping (VolumeInfo) -> Void) {
        self.onEject = onEject
        title.stringValue = item.title
        toolTip = item.url?.path
        if let v = item.volume {
            volume = v
            icon.image = NSImage(systemSymbolName: v.kind.symbolName, accessibilityDescription: v.kind.sectionTitle)
            icon.contentTintColor = v.kind.tint
            title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: v.kind == .external ? .semibold : .regular)
            detail.stringValue = v.capacityText ?? ""
            detail.isHidden = v.capacityText == nil
            ejectButton.isHidden = !v.kind.isEjectable
        } else {
            volume = nil
            icon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "フォルダ")
            icon.contentTintColor = .controlAccentColor
            title.font = .systemFont(ofSize: NSFont.systemFontSize)
            detail.isHidden = true
            ejectButton.isHidden = true
        }
    }

    @objc private func eject() {
        if let volume { onEject?(volume) }
    }
}
