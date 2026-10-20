import AppKit
import SwiftUI

/// サイドバーの表示方式
enum SidebarStyle: String, CaseIterable, Identifiable {
    case list
    case icon
    var id: String { rawValue }
    var label: String { self == .list ? "リスト" : "アイコン" }
    var systemImage: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

/// 左列：ディレクトリ選択画面（リスト表示／アイコン表示）
struct SidebarView: View {
    @Environment(BrowserState.self) private var browser
    @Environment(FolderTree.self) private var tree
    @AppStorage("sidebar.style") private var style: SidebarStyle = .list

    var body: some View {
        VStack(spacing: 0) {
            Picker("表示", selection: $style) {
                ForEach(SidebarStyle.allCases) { s in
                    Label(s.label, systemImage: s.systemImage).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            switch style {
            case .list: FolderListView()
            case .icon: FolderIconView()
            }
        }
    }
}

// MARK: - リスト表示（ツリー）

/// Finder のリスト表示のように、フォルダをダブルクリック（または Return）するとその中に入り、
/// そのフォルダから下の階層だけをツリーで表示する
private struct FolderListView: View {
    @Environment(BrowserState.self) private var browser
    @Environment(FolderTree.self) private var tree
    /// ツリーの起点にしているフォルダのパス（空 = 最上位の「よく使う項目」「場所」）
    @AppStorage("sidebar.listRoot") private var rootPath = ""
    @State private var rootNode: FolderNode?

    private var rootURL: URL? {
        rootPath.isEmpty ? nil : URL(fileURLWithPath: rootPath, isDirectory: true)
    }

    var body: some View {
        let selection = Binding<URL?>(
            get: { browser.currentFolder },
            set: { if let u = $0 { browser.open(folder: u) } }
        )
        VStack(spacing: 0) {
            if let root = rootURL {
                header(root)
                Divider()
            }
            List(selection: selection) {
                if let rootNode {
                    if let children = rootNode.children {
                        if children.isEmpty {
                            Text("サブフォルダはありません")
                                .foregroundStyle(.secondary)
                                .selectionDisabled()
                        }
                        ForEach(children) { FolderTreeRow(node: $0) }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Section("よく使う項目") {
                        ForEach(tree.favorites) { node in
                            FolderTreeRow(node: node)
                        }
                        .onMove { tree.moveFavorites(from: $0, to: $1) }
                    }
                    Section("場所") {
                        ForEach(tree.volumes) { node in
                            FolderTreeRow(node: node, systemImage: "externaldrive")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // 起点を変えたら一覧を作り直す（前の一覧の選択表示が残像として残るのを防ぐ）
            .id(rootPath)
            .contextMenu(forSelectionType: URL.self) { urls in
                if let url = urls.first {
                    Button("このフォルダに入る") { enter(url) }
                    Divider()
                    if tree.isFavorite(url) {
                        Button("よく使う項目から削除") { tree.removeFavorite(url) }
                    } else {
                        Button("よく使う項目に追加") { tree.addFavorite(url) }
                    }
                    Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            } primaryAction: { urls in
                // ダブルクリック・Return でそのフォルダの中に入る
                if let url = urls.first { enter(url) }
            }
        }
        .task(id: rootPath) { loadRoot() }
    }

    /// 起点フォルダの見出し：上の階層へ・最上位へ・親フォルダのメニュー
    private func header(_ root: URL) -> some View {
        HStack(spacing: 4) {
            Button {
                goUp(from: root)
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("上の階層へ（⌘↑）")
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(root.path == "/")

            // フォルダ名は長くても省略表示にして、サイドバーの最小幅を変えない
            // （名前の長さで最小幅が変わると、分割ビューのレイアウト更新が繰り返されてクラッシュする）
            Text(FileManager.default.displayName(atPath: root.path))
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .help(root.path)

            Menu {
                // 親フォルダをたどって移動できる（Finder のタイトルの右クリックと同じ）
                ForEach(ancestors(of: root), id: \.self) { url in
                    Button {
                        enter(url)
                    } label: {
                        Label(FileManager.default.displayName(atPath: url.path),
                              systemImage: url.path == "/" ? "internaldrive" : "folder")
                    }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("親フォルダへ移動")

            Button {
                rootPath = ""
            } label: {
                Image(systemName: "star.square.on.square")
            }
            .help("よく使う項目・場所の一覧に戻る")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func enter(_ url: URL) {
        rootPath = url.standardizedFileURL.path
        browser.open(folder: url)
    }

    private func goUp(from root: URL) {
        let parent = root.deletingLastPathComponent()
        rootPath = parent.standardizedFileURL.path
        browser.open(folder: parent)
    }

    /// 自分自身を除く、親フォルダの一覧（近い順）
    private func ancestors(of url: URL) -> [URL] {
        var result: [URL] = []
        var u = url.deletingLastPathComponent()
        while true {
            result.append(u)
            if u.path == "/" { break }
            u = u.deletingLastPathComponent()
        }
        return result
    }

    private func loadRoot() {
        guard let root = rootURL else {
            rootNode = nil
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            // フォルダが消えた・ドライブが外されたときは最上位に戻る
            rootPath = ""
            return
        }
        let node = FolderNode(url: root)
        node.loadChildren()
        rootNode = node
    }
}

private struct FolderTreeRow: View {
    @Bindable var node: FolderNode
    var systemImage = "folder"

    var body: some View {
        if node.hasChildren {
            DisclosureGroup(isExpanded: $node.isExpanded) {
                if let children = node.children {
                    ForEach(children) { FolderTreeRow(node: $0) }
                } else {
                    ProgressView().controlSize(.small)
                }
            } label: {
                label
            }
        } else {
            label
        }
    }

    private var label: some View {
        Label(node.displayName, systemImage: systemImage)
            .lineLimit(1)
            .tag(node.url)
    }
}

// MARK: - アイコン表示

private struct FolderIconView: View {
    @Environment(BrowserState.self) private var browser
    @Environment(FolderTree.self) private var tree
    /// アイコン表示で中身を表示しているフォルダ（nil = ルート一覧）
    @State private var location: URL?
    @State private var subfolders: [URL] = []

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 4)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    goUp()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(location == nil)
                .help("上のフォルダへ")
                Text(location.map { FileManager.default.displayName(atPath: $0.path) } ?? "場所")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    if location == nil {
                        ForEach(tree.favorites + tree.volumes) { node in
                            FolderIconCell(url: node.url, name: node.displayName,
                                           isSelected: browser.currentFolder == node.url,
                                           onSelect: { browser.open(folder: node.url) },
                                           onEnter: { location = node.url })
                        }
                    } else {
                        ForEach(subfolders, id: \.self) { url in
                            FolderIconCell(url: url, name: url.lastPathComponent,
                                           isSelected: browser.currentFolder == url,
                                           onSelect: { browser.open(folder: url) },
                                           onEnter: { location = url })
                        }
                    }
                }
                .padding(8)
            }
        }
        .onAppear {
            if location == nil { location = browser.currentFolder }
        }
        .task(id: location) {
            guard let location else { subfolders = []; return }
            subfolders = await Task.detached { FolderScanner.subfolders(of: location) }.value
        }
    }

    private func goUp() {
        guard let loc = location else { return }
        // よく使う項目・ボリュームの位置まで来たらルート一覧に戻る
        let roots = Set((tree.favorites + tree.volumes).map(\.url.standardizedFileURL))
        if roots.contains(loc.standardizedFileURL) || loc.path == "/" {
            location = nil
        } else {
            location = loc.deletingLastPathComponent()
        }
    }
}

private struct FolderIconCell: View {
    let url: URL
    let name: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onEnter: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 48, height: 48)
            Text(name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
        }
        .frame(width: 76, height: 84)
        .background(isSelected ? Color.accentColor.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onEnter() }
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .help("クリックで表示、ダブルクリックで中に入る")
        .folderContextMenu(url)
    }
}

// MARK: - 右クリックメニュー

private struct FolderContextMenu: ViewModifier {
    @Environment(FolderTree.self) private var tree
    let url: URL

    func body(content: Content) -> some View {
        content.contextMenu {
            if tree.isFavorite(url) {
                Button("よく使う項目から削除") { tree.removeFavorite(url) }
            } else {
                Button("よく使う項目に追加") { tree.addFavorite(url) }
            }
            Button("Finder で表示") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

extension View {
    fileprivate func folderContextMenu(_ url: URL) -> some View {
        modifier(FolderContextMenu(url: url))
    }
}
