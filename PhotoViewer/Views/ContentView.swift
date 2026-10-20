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
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 400)
        } detail: {
            gridArea
                .inspector(isPresented: $showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 260, ideal: 340, max: 700)
                }
        }
        .navigationTitle(browser.currentFolder?.lastPathComponent ?? "PhotoViewer")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
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
                contextMenu: { urls in
                    GridContextMenu.make(for: urls, settings: settings,
                                         onRename: { browser.renameTargets = urls })
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
