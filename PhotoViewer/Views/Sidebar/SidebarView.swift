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
    @AppStorage("sidebar.style") private var style: SidebarStyle = .list
    @AppStorage("sidebar.listRoot") private var listRoot = ""

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
        // ドライブが外されたら、そのドライブ上のフォルダを表示し続けない
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { note in
            guard let vol = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            let prefix = vol.standardizedFileURL.path
            func isOn(_ path: String) -> Bool { path == prefix || path.hasPrefix(prefix + "/") }
            if !listRoot.isEmpty && isOn(listRoot) { listRoot = "" }
            if let cur = browser.currentFolder, isOn(cur.standardizedFileURL.path) { browser.closeFolder() }
        }
    }
}

// MARK: - リスト表示（ツリー）

/// Finder のリスト表示のように、フォルダをダブルクリック（または Return）するとその中に入り、
/// そのフォルダから下の階層だけをツリーで表示する
private struct FolderListView: View {
    @Environment(BrowserState.self) private var browser
    @Environment(FolderTree.self) private var tree
    /// ツリーの起点にしているフォルダのパス（空 = 最上位の「よく使う項目」・ボリューム）
    @AppStorage("sidebar.listRoot") private var rootPath = ""
    @State private var rootVolume: VolumeInfo?
    @State private var ejectError: String?

    private var rootURL: URL? {
        rootPath.isEmpty ? nil : URL(fileURLWithPath: rootPath, isDirectory: true)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let root = rootURL {
                header(root)
                Divider()
            }
            FolderOutlineView(
                root: rootURL,
                favorites: tree.favorites,
                volumes: tree.volumes,
                currentFolder: browser.currentFolder,
                onSelect: { browser.open(folder: $0) },
                onEnter: { enter($0) },
                menuFor: { menu(for: $0) },
                onEject: { eject($0) }
            )
        }
        .task(id: rootPath) { checkRoot() }
        .alert("取り出せませんでした", isPresented: Binding(
            get: { ejectError != nil }, set: { if !$0 { ejectError = nil } }
        )) {
            Button("OK") { ejectError = nil }
        } message: {
            Text(ejectError ?? "")
        }
    }

    /// 起点フォルダの見出し：どのドライブか・上の階層へ・親フォルダのメニュー・一覧へ戻る
    private func header(_ root: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let v = rootVolume {
                // どのドライブの中にいるかを色付きで示す（外付けはオレンジ）
                HStack(spacing: 4) {
                    Image(systemName: v.kind.symbolName)
                    Text(v.name).lineLimit(1).truncationMode(.middle)
                    Text(v.kind.sectionTitle).foregroundStyle(.secondary)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(nsColor: v.kind.tint))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(nsColor: v.kind.tint).opacity(0.15), in: Capsule())
                .help(v.capacityText ?? v.kind.sectionTitle)
            }
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
                Text(FolderTree.displayName(root))
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
                            Label(FolderTree.displayName(url),
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
                .help("よく使う項目・ドライブの一覧に戻る")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func menu(for item: FolderItem) -> NSMenu? {
        guard let url = item.url else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("このフォルダに入る") { enter(url) })
        menu.addItem(.separator())
        if tree.isFavorite(url) {
            menu.addItem(ClosureMenuItem("よく使う項目から削除") { tree.removeFavorite(url) })
        } else {
            menu.addItem(ClosureMenuItem("よく使う項目に追加") { tree.addFavorite(url) })
        }
        menu.addItem(ClosureMenuItem("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        if let v = item.volume, v.kind.isEjectable {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("「\(v.name)」を取り出す") { eject(v) })
        }
        return menu
    }

    private func eject(_ v: VolumeInfo) {
        Task {
            if let error = await tree.eject(v) {
                ejectError = "「\(v.name)」：\(error)\n使用中のファイルがあれば閉じてから、もう一度試してください。"
            }
        }
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

    private func checkRoot() {
        guard let root = rootURL else {
            rootVolume = nil
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            // フォルダが消えた・ドライブが外されたときは最上位に戻る
            rootPath = ""
            return
        }
        rootVolume = VolumeInfo.containing(root)
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
                        ForEach(tree.favorites, id: \.self) { url in
                            FolderIconCell(url: url, name: FolderTree.displayName(url),
                                           isSelected: browser.currentFolder == url,
                                           onSelect: { browser.open(folder: url) },
                                           onEnter: { location = url })
                        }
                        ForEach(tree.volumes, id: \.url) { v in
                            FolderIconCell(url: v.url, name: v.name, volumeKind: v.kind,
                                           isSelected: browser.currentFolder == v.url,
                                           onSelect: { browser.open(folder: v.url) },
                                           onEnter: { location = v.url })
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
        let roots = Set((tree.favorites + tree.volumes.map(\.url)).map(\.standardizedFileURL))
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
    var volumeKind: VolumeKind?
    let isSelected: Bool
    let onSelect: () -> Void
    let onEnter: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 48, height: 48)
                .overlay(alignment: .bottomTrailing) {
                    // ボリュームは種類の印を付ける（外付けはオレンジ）
                    if let k = volumeKind {
                        Image(systemName: k.symbolName)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(nsColor: k.tint))
                            .padding(3)
                            .background(.regularMaterial, in: Circle())
                    }
                }
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
        .help(volumeKind.map { "\($0.sectionTitle)：クリックで表示、ダブルクリックで中に入る" }
              ?? "クリックで表示、ダブルクリックで中に入る")
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
