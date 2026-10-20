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

    var body: some View {
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
        .onAppear { browser.restoreLastFolder() }
    }

    private var subtitle: String {
        guard browser.currentFolder != nil else { return "" }
        let n = browser.displayedItems.count
        return browser.selection.count > 1 ? "\(n) 枚（\(browser.selection.count) 枚選択）" : "\(n) 枚"
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
                contextMenu: { urls in GridContextMenu.make(for: urls, settings: settings) }
            )
            .overlay {
                if browser.isScanning && browser.items.isEmpty {
                    ProgressView()
                } else if !browser.isScanning && browser.displayedItems.isEmpty {
                    Text("写真がありません").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
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
