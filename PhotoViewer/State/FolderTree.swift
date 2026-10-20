import AppKit
import Foundation
import Observation

/// フォルダツリーの 1 ノード。子フォルダは展開されたときに初めて読み込む
@MainActor
@Observable
final class FolderNode: Identifiable {
    let url: URL
    let displayName: String
    /// nil = 未読み込み
    private(set) var children: [FolderNode]?
    /// サブフォルダを持つか（未確認の間は true とみなして開閉ボタンを出す）
    private(set) var hasChildren: Bool
    var isExpanded = false {
        didSet {
            if isExpanded && children == nil { loadChildren() }
        }
    }

    nonisolated var id: URL { url }

    init(url: URL, displayName: String? = nil, hasChildren: Bool = true) {
        self.url = url
        self.displayName = displayName ?? FileManager.default.displayName(atPath: url.path)
        self.hasChildren = hasChildren
    }

    /// 子フォルダを読む。孫フォルダの有無は先に調べない（Finder と同じく開いたときに分かる）
    /// 先に中を調べると、デスクトップや書類などのアクセス許可ダイアログが、開いてもいないのに出てしまうため
    func loadChildren() {
        let url = url
        Task {
            let found: [URL] = await Task.detached(priority: .userInitiated) {
                FolderScanner.subfolders(of: url)
            }.value
            self.children = found.map { FolderNode(url: $0) }
            self.hasChildren = !found.isEmpty
        }
    }

    /// 子フォルダを読み直す（フォルダ追加・削除の反映用）
    func refresh() {
        children = nil
        if isExpanded { loadChildren() }
    }
}

/// サイドバーのルート（よく使う項目・ボリューム）
@MainActor
@Observable
final class FolderTree {
    private(set) var favorites: [FolderNode] = []
    private(set) var volumes: [FolderNode] = []

    private static let favoritesKey = "sidebar.favorites"

    init() {
        loadFavorites()
        reloadVolumes()
        observeVolumeChanges()
    }

    private func loadFavorites() {
        let paths: [String]
        if let saved = UserDefaults.standard.stringArray(forKey: Self.favoritesKey) {
            paths = saved
        } else {
            let fm = FileManager.default
            paths = [
                fm.urls(for: .picturesDirectory, in: .userDomainMask).first,
                fm.urls(for: .desktopDirectory, in: .userDomainMask).first,
                fm.homeDirectoryForCurrentUser,
            ].compactMap { $0?.path }
        }
        favorites = paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { FolderNode(url: URL(fileURLWithPath: $0, isDirectory: true)) }
    }

    private func saveFavorites() {
        UserDefaults.standard.set(favorites.map(\.url.path), forKey: Self.favoritesKey)
    }

    func isFavorite(_ url: URL) -> Bool {
        favorites.contains { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    func addFavorite(_ url: URL) {
        guard !isFavorite(url) else { return }
        favorites.append(FolderNode(url: url.standardizedFileURL))
        saveFavorites()
    }

    func removeFavorite(_ url: URL) {
        favorites.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }
        saveFavorites()
    }

    func moveFavorites(from source: IndexSet, to destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
        saveFavorites()
    }

    func reloadVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            guard v?.volumeIsBrowsable != false else { return nil }
            return FolderNode(url: u, displayName: v?.volumeName ?? u.lastPathComponent)
        }
    }

    private func observeVolumeChanges() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadVolumes() }
            }
        }
    }
}
