import AppKit
import Foundation
import Observation

/// サイドバーのルート（よく使う項目・ボリューム）
@MainActor
@Observable
final class FolderTree {
    private(set) var favorites: [URL] = []
    /// よく使う項目の表示名（ピクチャ・デスクトップなど。取得はディスクに触るのでバックグラウンドで用意する）
    private(set) var favoriteNames: [URL: String] = [:]
    private(set) var volumes: [VolumeInfo] = []

    private static let favoritesKey = "sidebar.favorites"

    init() {
        loadFavorites()
        reloadVolumes()
        observeVolumeChanges()
    }

    nonisolated static func displayName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
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
        // まずはそのまま表示し、存在の確認と表示名の取得はバックグラウンドで行う
        // （外付け HDD のフォルダを登録していると、HDD が止まっているときに起動が数秒止まるため）
        let urls = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        favorites = urls
        Task {
            let checked = await Task.detached(priority: .utility) { () -> [(URL, String)] in
                urls.filter { FileManager.default.fileExists(atPath: $0.path) }.map { ($0, Self.displayName($0)) }
            }.value
            let existing = Set(checked.map(\.0))
            self.favorites = self.favorites.filter { existing.contains($0) || !urls.contains($0) }
            for (u, name) in checked { self.favoriteNames[u] = name }
        }
    }

    private func loadFavoriteName(_ url: URL) {
        Task {
            let name = await Task.detached(priority: .utility) { Self.displayName(url) }.value
            self.favoriteNames[url] = name
        }
    }

    private func saveFavorites() {
        UserDefaults.standard.set(favorites.map(\.path), forKey: Self.favoritesKey)
    }

    func isFavorite(_ url: URL) -> Bool {
        favorites.contains { $0.standardizedFileURL == url.standardizedFileURL }
    }

    func addFavorite(_ url: URL) {
        guard !isFavorite(url) else { return }
        favorites.append(url.standardizedFileURL)
        loadFavoriteName(url.standardizedFileURL)
        saveFavorites()
    }

    func removeFavorite(_ url: URL) {
        favorites.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        saveFavorites()
    }

    /// ドライブの一覧と空き容量・種類をバックグラウンドで読む
    /// （応答しないネットワークドライブや止まっている HDD に触ると、数秒〜数十秒かかることがあるため）
    func reloadVolumes() {
        Task {
            let loaded = await Task.detached(priority: .utility) { () -> [VolumeInfo] in
                let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey]
                let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                                 options: [.skipHiddenVolumes]) ?? []
                return urls.compactMap { u in
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    guard v?.volumeIsBrowsable != false else { return nil }
                    return VolumeInfo.load(u, name: v?.volumeName)
                }
                .sorted { ($0.kind, $0.name) < ($1.kind, $1.name) }
            }.value
            if loaded != self.volumes { self.volumes = loaded }
        }
    }

    /// 取り出す（時間がかかることがあるのでバックグラウンドで行う）。失敗したら理由を返す
    func eject(_ volume: VolumeInfo) async -> String? {
        let url = volume.url
        let error: String? = await Task.detached(priority: .userInitiated) {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        reloadVolumes()
        return error
    }

    private func observeVolumeChanges() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadVolumes() }
            }
        }
    }
}
