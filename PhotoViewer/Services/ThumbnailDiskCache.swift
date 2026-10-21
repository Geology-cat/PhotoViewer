import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 読むのに時間がかかる大きなファイル（数百 MB の TIF など）の縮小画像をディスクに保存する
/// - 場所：~/Library/Caches/com.geologycat.PhotoViewer/Thumbnails
/// - キーはファイルのパス・サイズ・更新日なので、元のファイルを書き換えたら自動で作り直される
/// - 合計が上限を超えたら古いものから消す
final class ThumbnailDiskCache: Sendable {
    static let shared = ThumbnailDiskCache()

    let directory: URL
    /// 合計の上限
    static let limitBytes: Int64 = 1024 * 1024 * 1024

    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.directory = directory
            ?? base.appendingPathComponent("com.geologycat.PhotoViewer/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// 保存先のファイル名（元ファイルのパス・サイズ・更新日のハッシュ＋サイズの段階）
    func fileURL(for url: URL, bucket: Int) -> URL? {
        // URL はサイズ・更新日を一度読むと覚えてしまうので、最新の値を読み直す
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let v = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let source = "\(url.standardizedFileURL.path)|\(v.fileSize ?? 0)|\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let hash = SHA256.hash(data: Data(source.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash)_\(bucket).jpg")
    }

    func read(_ url: URL, bucket: Int) -> CGImage? {
        guard let file = fileURL(for: url, bucket: bucket),
              let src = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    func write(_ image: CGImage, for url: URL, bucket: Int) {
        guard let file = fileURL(for: url, bucket: bucket) else { return }
        let temp = file.appendingPathExtension("tmp")
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: temp)
            return
        }
        _ = try? FileManager.default.replaceItemAt(file, withItemAt: temp)
        if FileManager.default.fileExists(atPath: temp.path) { try? FileManager.default.removeItem(at: temp) }
    }

    /// 合計が上限を超えていたら、更新日の古いものから上限の 8 割まで消す（起動時にバックグラウンドで呼ぶ）
    func prune(limit: Int64 = ThumbnailDiskCache.limitBytes) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        var entries: [(url: URL, size: Int64, date: Date)] = files.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            return (u, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        entries.sort { $0.date < $1.date }
        for e in entries where total > limit * 8 / 10 {
            try? FileManager.default.removeItem(at: e.url)
            total -= e.size
        }
    }
}
