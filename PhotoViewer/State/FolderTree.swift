import AppKit
import DiskArbitration
import Foundation
import Observation

/// ボリュームの種類
enum VolumeKind: Int, Comparable, Sendable {
    case `internal`, external, diskImage, network

    static func < (a: VolumeKind, b: VolumeKind) -> Bool { a.rawValue < b.rawValue }

    var sectionTitle: String {
        switch self {
        case .internal: "内蔵ディスク"
        case .external: "外付けドライブ"
        case .diskImage: "ディスクイメージ"
        case .network: "ネットワーク"
        }
    }

    var symbolName: String {
        switch self {
        case .internal: "internaldrive"
        case .external: "externaldrive.fill"
        case .diskImage: "opticaldiscdrive"
        case .network: "network"
        }
    }

    /// 外付けはオレンジで目立たせる
    var tint: NSColor {
        switch self {
        case .internal: .secondaryLabelColor
        case .external: .systemOrange
        case .diskImage: .systemGray
        case .network: .systemTeal
        }
    }

    /// 取り出しボタンを出すか
    var isEjectable: Bool { self != .internal }
}

/// マウント中のボリューム
struct VolumeInfo: Hashable, Sendable {
    var url: URL
    var name: String
    var kind: VolumeKind
    var availableBytes: Int64?
    var totalBytes: Int64?

    /// 「空き 3.1 TB / 10 TB」
    var capacityText: String? {
        guard let a = availableBytes, let t = totalBytes, t > 0 else { return nil }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return "空き \(f.string(fromByteCount: a)) / \(f.string(fromByteCount: t))"
    }

    // MARK: 種類の判定

    /// ボリュームの種類を判定する
    /// DiskArbitration のデバイス情報（diskutil と同じ情報源）を優先し、取れなければ URL の情報で推定する
    static func classify(_ url: URL) -> VolumeKind {
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey]
        let v = try? url.resourceValues(forKeys: keys)
        if v?.volumeIsRootFileSystem == true { return .internal }
        if v?.volumeIsLocal == false { return .network }
        if let session = DASessionCreate(kCFAllocatorDefault),
           let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
           let desc = DADiskCopyDescription(disk) as? [CFString: Any] {
            let proto = desc[kDADiskDescriptionDeviceProtocolKey] as? String
            if proto == "Disk Image" || desc[kDADiskDescriptionDeviceModelKey] as? String == "Disk Image" {
                return .diskImage
            }
            if let internalFlag = desc[kDADiskDescriptionDeviceInternalKey] as? Bool {
                return internalFlag ? .internal : .external
            }
        }
        // 推定：内蔵の判定が取れないボリュームは、ディスクイメージであることが多い
        switch v?.volumeIsInternal {
        case true?: return .internal
        case false?: return .external
        case nil: return .diskImage
        }
    }

    static func load(_ url: URL, name: String? = nil) -> VolumeInfo {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey, .volumeTotalCapacityKey]
        let v = try? url.resourceValues(forKeys: keys)
        let available = v?.volumeAvailableCapacityForImportantUsage ?? v?.volumeAvailableCapacity.map(Int64.init)
        return VolumeInfo(url: url, name: name ?? v?.volumeName ?? url.lastPathComponent, kind: classify(url),
                          availableBytes: available, totalBytes: v?.volumeTotalCapacity.map(Int64.init))
    }

    /// 指定したフォルダを含むボリューム
    static func containing(_ url: URL) -> VolumeInfo? {
        guard let vol = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume else { return nil }
        return load(vol)
    }
}

/// サイドバーのルート（よく使う項目・ボリューム）
@MainActor
@Observable
final class FolderTree {
    private(set) var favorites: [URL] = []
    private(set) var volumes: [VolumeInfo] = []

    private static let favoritesKey = "sidebar.favorites"

    init() {
        loadFavorites()
        reloadVolumes()
        observeVolumeChanges()
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
        favorites = paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
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
        saveFavorites()
    }

    func removeFavorite(_ url: URL) {
        favorites.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        saveFavorites()
    }

    func reloadVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            guard v?.volumeIsBrowsable != false else { return nil }
            return VolumeInfo.load(u, name: v?.volumeName)
        }
        .sorted { ($0.kind, $0.name) < ($1.kind, $1.name) }
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
