import AppKit
import SwiftUI

/// メインウィンドウ：サイドバー／グリッド／インスペクタ（プレビュー＋情報）
struct ContentView: View {
    @Environment(BrowserState.self) private var browser
    @Environment(AppSettings.self) private var settings
    @AppStorage("inspector.visible") private var showInspector = true
    @AppStorage(GridSettings.modeKey) private var gridMode: GridLayoutMode = .size
    @AppStorage(GridSettings.thumbnailSizeKey) private var thumbnailSize = GridSettings.defaultSize
    @AppStorage(GridSettings.columnsKey) private var columns = GridSettings.defaultColumns
    @AppStorage(GridSettings.showNamesKey) private var showNames = true
    @State private var showFilter = false
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var browser = browser
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 600)
        } detail: {
            // 右列（プレビュー＋情報）は分割ビューで並べる
            // SwiftUI 標準の .inspector は、ウインドウに収まらないほど広げられる設定にすると
            // レイアウト更新が繰り返されて AppKit の例外でクラッシュするため使わない
            HSplitView {
                // ZStack で包んで、フォルダの有無で中身が切り替わっても分割の位置が変わらないようにする
                ZStack { gridArea }
                    // 中央のグリッドはサムネイル 1 列分まで狭くできる（右列を広げてプレビューを大きく見るため）
                    .frame(minWidth: 120, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                if showInspector {
                    InspectorView()
                        .frame(minWidth: 240, idealWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(browser.currentFolder?.lastPathComponent ?? "PhotoViewer")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .background(ToolbarDisplayModeSetter())
        .searchable(text: $browser.filter.text, placement: .toolbar, prompt: "ファイル名・カメラ・レンズ")
        .onAppear { browser.restoreLastFolder() }
        .sheet(isPresented: Binding(
            get: { browser.renameTargets != nil },
            set: { if !$0 { browser.renameTargets = nil } }
        )) {
            if let targets = browser.renameTargets {
                RenameSheet(targets: targets, undoManager: undoManager)
            }
        }
        .alert("エラー", isPresented: Binding(
            get: { browser.alertMessage != nil },
            set: { if !$0 { browser.alertMessage = nil } }
        )) {
            Button("OK") { browser.alertMessage = nil }
        } message: {
            Text(browser.alertMessage ?? "")
        }
    }

    private var subtitle: String {
        guard browser.currentFolder != nil else { return "" }
        let n = browser.displayedItems.count
        var s = browser.filter.isFiltering ? "\(n) / \(browser.items.count) 枚" : "\(n) 枚"
        if browser.selection.count > 1 { s += "（\(browser.selection.count) 枚選択）" }
        if let p = browser.metadataProgress { s += " ・撮影情報を読み込み中 \(p.done)/\(p.total)" }
        return s
    }

    @ViewBuilder
    private var gridArea: some View {
        if browser.currentFolder == nil {
            ContentUnavailableView {
                Label("フォルダを選択してください", systemImage: "photo.on.rectangle")
            } description: {
                Text("左のサイドバーからフォルダを選ぶか、⇧⌘O でフォルダを開きます。")
            }
        } else {
            PhotoGridView(
                items: browser.displayedItems,
                selection: browser.selection,
                layoutConfig: GridLayoutConfig(mode: gridMode, thumbnailSize: thumbnailSize,
                                               columns: columns, showNames: showNames),
                onSelectionChange: { browser.updateSelection($0, lastAdded: $1) },
                onOpen: { settings.open($0) },
                tagsFor: { browser.tags(for: $0) },
                tagsVersion: browser.tagsVersion,
                onRate: { browser.setRating($1, for: $0) },
                onToggleDeveloped: { browser.toggleDeveloped(for: $0) },
                onTrash: { browser.moveToTrash($0, undoManager: undoManager) },
                contextMenu: { urls in
                    GridContextMenu.make(for: urls, settings: settings,
                                         onRename: { browser.renameTargets = urls },
                                         onTrash: { browser.moveToTrash(urls, undoManager: undoManager) })
                }
            )
            .overlay {
                if browser.isScanning && browser.items.isEmpty {
                    ProgressView()
                } else if !browser.isScanning && browser.displayedItems.isEmpty {
                    if browser.filter.isFiltering && !browser.items.isEmpty {
                        ContentUnavailableView.search
                    } else {
                        Text("写真がありません").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                browser.goBack()
            } label: {
                Label("戻る", systemImage: "chevron.left")
            }
            .disabled(!browser.canGoBack)
            .help("前に表示していた階層へ戻る（⌘[）")
            Button {
                browser.goForward()
            } label: {
                Label("進む", systemImage: "chevron.right")
            }
            .disabled(!browser.canGoForward)
            .help("戻る前の階層へ進む（⌘]）")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showFilter.toggle()
            } label: {
                Label("絞り込み", systemImage: browser.filter.isFiltering
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .help("絞り込み・詳細検索")
            .popover(isPresented: $showFilter, arrowEdge: .bottom) {
                FilterPanel()
            }

            Menu {
                let b = Bindable(browser)
                Picker("並べ替え", selection: b.filter.sortKey) {
                    ForEach(SortKey.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("順序", selection: b.filter.ascending) {
                    Text("昇順").tag(true)
                    Text("降順").tag(false)
                }
                .pickerStyle(.inline)
            } label: {
                Label("並べ替え", systemImage: "arrow.up.arrow.down")
            }
            .help("並べ替え：\(browser.filter.sortKey.label)")

            Picker("並べ方", selection: $gridMode) {
                ForEach(GridLayoutMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("サムネイルの並べ方")

            switch gridMode {
            case .size:
                Slider(value: $thumbnailSize, in: GridSettings.sizeRange) {
                    Text("サイズ")
                } minimumValueLabel: {
                    Image(systemName: "photo").imageScale(.small)
                } maximumValueLabel: {
                    Image(systemName: "photo").imageScale(.large)
                }
                .frame(width: 140)
                .help("サムネイルの大きさ")
            case .columns:
                Stepper(value: $columns, in: GridSettings.columnsRange) {
                    Text("\(columns) 列").monospacedDigit()
                }
                .help("列数")
            }

            Toggle(isOn: $showNames) {
                Label("ファイル名", systemImage: "textformat")
            }
            .help("ファイル名を表示")

            Button {
                showInspector.toggle()
            } label: {
                Label("プレビューと情報", systemImage: "sidebar.right")
            }
            .help("右列（プレビューと情報）の表示／非表示（⌃⌘I）")
        }
    }
}

/// 右列：プレビュー（上）と画像情報（下）
private struct InspectorView: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        VSplitView {
            PreviewView(item: browser.primaryItem, selectionCount: browser.selection.count)
                .frame(minHeight: 160, idealHeight: 360)
            InfoPanelView(item: browser.primaryItem)
                .frame(minHeight: 140, idealHeight: 300)
        }
    }
}

/// ツールバーを「アイコンとテキスト」で表示する（SwiftUI には表示方式を指定する API がないため、ウインドウのツールバーに直接設定する）
private struct ToolbarDisplayModeSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ToolbarModeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ToolbarModeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // ツールバーはビューより後に作られることがあるので、少し後にもう一度設定する
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            guard let toolbar = window?.toolbar, toolbar.displayMode != .iconAndLabel else { return }
            toolbar.displayMode = .iconAndLabel
        }
    }
}
