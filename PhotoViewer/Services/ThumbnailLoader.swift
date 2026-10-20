import CoreGraphics
import Foundation
import ImageIO

/// CGImage を NSCache に入れるための箱
private final class ImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// サムネイル・プレビュー画像の生成とメモリキャッシュ
/// NSCache はスレッドセーフなので、どのスレッドからでも使える
final class ThumbnailLoader: @unchecked Sendable {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, ImageBox>()

    init() {
        // 目安：上限 400MB（RGBA 換算）
        cache.totalCostLimit = 400 * 1024 * 1024
    }

    /// 要求サイズを段階に丸め、キャッシュを使い回しやすくする
    static func bucket(for pixelSize: Int) -> Int {
        for b in [128, 256, 384, 512, 768, 1024, 1536, 2048, 3072] where pixelSize <= b {
            return b
        }
        return 4096
    }

    private func key(_ url: URL, _ bucket: Int) -> NSString {
        "\(bucket)|\(url.path)" as NSString
    }

    /// キャッシュにあればすぐ返す（メインスレッドから同期で呼ぶ想定）
    func cached(_ url: URL, pixelSize: Int) -> CGImage? {
        cache.object(forKey: key(url, Self.bucket(for: pixelSize)))?.image
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    func remove(_ url: URL) {
        for b in [128, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096] {
            cache.removeObject(forKey: key(url, b))
        }
    }

    /// 画像を生成してキャッシュする。重い処理なのでバックグラウンドから呼ぶこと
    /// - Parameter allowFullDecode: 埋め込みプレビューが小さすぎるとき、RAW でも本体からデコードし直すか
    func load(_ url: URL, pixelSize: Int, allowFullDecode: Bool) -> CGImage? {
        let bucket = Self.bucket(for: pixelSize)
        let k = key(url, bucket)
        if let hit = cache.object(forKey: k) { return hit.image }
        guard let image = Self.makeThumbnail(url: url, maxPixel: bucket, allowFullDecode: allowFullDecode) else {
            return nil
        }
        cache.setObject(ImageBox(image), forKey: k, cost: image.bytesPerRow * image.height)
        return image
    }

    /// ImageIO でサムネイルを作る
    static func makeThumbnail(url: URL, maxPixel: Int, allowFullDecode: Bool) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

        func make(always: Bool) -> CGImage? {
            let options: [CFString: Any] = [
                always ? kCGImageSourceCreateThumbnailFromImageAlways
                       : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }

        let isRAW = SupportedFormats.raw.contains(url.pathExtension.lowercased())
        let first = make(always: false)
        // 埋め込みサムネイル（160px 程度）が返ってきた場合の作り直し判定
        if let first, max(first.width, first.height) >= maxPixel / 2 {
            return first
        }
        // 元画像自体が小さい場合は作り直しても大きくならない
        if let first, let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           max(first.width, first.height) >= max(w, h) {
            return first
        }
        if isRAW && !allowFullDecode && first != nil {
            return first
        }
        return make(always: true) ?? first
    }
}
