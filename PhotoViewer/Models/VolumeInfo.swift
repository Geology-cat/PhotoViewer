import AppKit
import DiskArbitration
import Foundation

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
        var keys: Set<URLResourceKey> = [.volumeNameKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey]
        if #available(macOS 10.13, *) { keys.insert(.volumeAvailableCapacityForImportantUsageKey) }
        let v = try? url.resourceValues(forKeys: keys)
        var available = v?.volumeAvailableCapacity.map(Int64.init)
        // 「重要な用途に使える空き」は macOS 10.13 以降（レガシー版と共有するため分ける）
        if #available(macOS 10.13, *), let important = v?.volumeAvailableCapacityForImportantUsage { available = important }
        return VolumeInfo(url: url, name: name ?? v?.volumeName ?? url.lastPathComponent, kind: classify(url),
                          availableBytes: available, totalBytes: v?.volumeTotalCapacity.map(Int64.init))
    }

    /// 指定したフォルダを含むボリューム
    static func containing(_ url: URL) -> VolumeInfo? {
        guard let vol = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume else { return nil }
        return load(vol)
    }
}
