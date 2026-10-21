import AppKit
import Foundation

extension Notification.Name {
    /// よく使う項目・ドライブの一覧が変わった（object は FolderTreeModel）
    static let folderTreeChanged = Notification.Name("FolderTreeModel.changed")
}

/// サイドバーのルート（よく使う項目・ボリューム）。通常版の FolderTree と同じ内容
final class FolderTreeModel {
    static let shared = FolderTreeModel()

    private(set) var favorites: [URL] = []
    /// よく使う項目の表示名（ディスクに触るのでバックグラウンドで用意する）
    private(set) var favoriteNames: [URL: String] = [:]
    private(set) var volumes: [VolumeInfo] = []

    private static let favoritesKey = "sidebar.favorites"

    init() {
        loadFavorites()
        reloadVolumes()
        observeVolumeChanges()
    }

    private func changed() {
        NotificationCenter.default.post(name: .folderTreeChanged, object: self)
    }

    static func displayName(_ url: URL) -> String {
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
        let urls = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        favorites = urls
        // 存在の確認と表示名の取得はバックグラウンドで（外付け HDD が止まっていると時間がかかる）
        runInBackground(qos: .utility, {
            urls.filter { FileManager.default.fileExists(atPath: $0.path) }.map { ($0, Self.displayName($0)) }
        }, then: { checked in
            let existing = Set(checked.map(\.0))
            self.favorites = self.favorites.filter { existing.contains($0) || !urls.contains($0) }
            for (u, name) in checked { self.favoriteNames[u] = name }
            self.changed()
        })
    }

    private func saveFavorites() {
        UserDefaults.standard.set(favorites.map(\.path), forKey: Self.favoritesKey)
    }

    func isFavorite(_ url: URL) -> Bool {
        favorites.contains { $0.standardizedFileURL == url.standardizedFileURL }
    }

    func addFavorite(_ url: URL) {
        guard !isFavorite(url) else { return }
        let u = url.standardizedFileURL
        favorites.append(u)
        saveFavorites()
        changed()
        runInBackground(qos: .utility, { Self.displayName(u) }, then: { name in
            self.favoriteNames[u] = name
            self.changed()
        })
    }

    func removeFavorite(_ url: URL) {
        favorites.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        saveFavorites()
        changed()
    }

    /// ドライブの一覧と空き容量・種類をバックグラウンドで読む
    func reloadVolumes() {
        runInBackground(qos: .utility, { () -> [VolumeInfo] in
            let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey]
            let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                             options: [.skipHiddenVolumes]) ?? []
            return urls.compactMap { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                guard v?.volumeIsBrowsable != false else { return nil }
                return VolumeInfo.load(u, name: v?.volumeName)
            }
            .sorted { ($0.kind, $0.name) < ($1.kind, $1.name) }
        }, then: { loaded in
            if loaded != self.volumes {
                self.volumes = loaded
                self.changed()
            }
        })
    }

    /// 取り出す（バックグラウンドで行う）。失敗したら理由をメインスレッドで返す
    func eject(_ volume: VolumeInfo, completion: @escaping (String?) -> Void) {
        let url = volume.url
        runInBackground({ () -> String? in
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                return nil
            } catch {
                return error.localizedDescription
            }
        }, then: { error in
            self.reloadVolumes()
            completion(error)
        })
    }

    private func observeVolumeChanges() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reloadVolumes() }
        }
    }
}
