import CoreGraphics
import Foundation
import ImageIO
import os

/// CGImage を NSCache に入れるための箱
private final class ImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

#if !LEGACY
/// 取り消しの印（GCD のキューで待っている間に取り消されたら、読まずに終わるため）
private final class CancelFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}
#endif

/// サムネイル・プレビュー画像の生成とキャッシュ
/// - メモリキャッシュ（NSCache）に加え、読むのに時間がかかる大きなファイルはディスクにも保存する
/// - 大きなファイルは 1 枚ずつ読む（HDD で同時に何枚も読むと、読み取り位置の移動が増えてかえって遅くなる）
/// NSCache はスレッドセーフなので、どのスレッドからでも使える
final class ThumbnailLoader: @unchecked Sendable {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, ImageBox>()
    /// 大きなファイルを順番に読むためのキュー（レガシー版の読み込みでも使う）
    let largeFileQueue = DispatchQueue(label: "com.geologycat.PhotoViewer.largeFile", qos: .userInitiated)

    /// この大きさ以上のファイルは 1 枚ずつ読む
    static let largeFileThreshold: Int64 = 64 * 1024 * 1024
    /// この大きさ以上で、読むのに時間がかかったファイルはディスクにも保存する
    static let diskCacheThreshold: Int64 = 20 * 1024 * 1024
    static let slowDecodeSeconds = 0.2

    static let buckets = [128, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096]

    init() {
        // 目安：上限 400MB（RGBA 換算）
        cache.totalCostLimit = 400 * 1024 * 1024
    }

    /// 要求サイズを段階に丸め、キャッシュを使い回しやすくする
    static func bucket(for pixelSize: Int) -> Int {
        buckets.first { pixelSize <= $0 } ?? 4096
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
        for b in Self.buckets {
            cache.removeObject(forKey: key(url, b))
        }
    }

    func store(_ image: CGImage, _ url: URL, _ bucket: Int) {
        cache.setObject(ImageBox(image), forKey: key(url, bucket), cost: image.bytesPerRow * image.height)
    }

    #if !LEGACY
    /// 画像を用意する（バックグラウンドで呼ぶこと）
    /// 1. メモリキャッシュ → 2. メモリ内のより大きい画像を縮小 → 3. ディスクキャッシュ → 4. ファイルから生成
    /// - Parameter allowFullDecode: 埋め込みプレビューが小さすぎるとき、RAW でも本体からデコードし直すか
    func load(_ url: URL, pixelSize: Int, allowFullDecode: Bool) async -> CGImage? {
        let bucket = Self.bucket(for: pixelSize)
        if let hit = cache.object(forKey: key(url, bucket)) { return hit.image }

        // プレビュー用に読んだ大きな画像があれば、それを縮小する（同じファイルを 2 回読まない）
        for b in Self.buckets where b > bucket {
            if let larger = cache.object(forKey: key(url, b))?.image,
               let small = Self.downscale(larger, maxPixel: bucket) {
                store(small, url, bucket)
                return small
            }
        }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        let start = ContinuousClock.now
        if fileSize >= Self.diskCacheThreshold, let disk = ThumbnailDiskCache.shared.read(url, bucket: bucket) {
            store(disk, url, bucket)
            PerfLog.image(url.lastPathComponent, bucket: bucket, source: "ディスクキャッシュ", since: start)
            return disk
        }
        if Task.isCancelled { return nil }

        let image: CGImage?
        if SupportedFormats.isVideo(url) {
            // 動画は必要な所だけを読むので、大きくても順番待ちにしない
            image = await VideoSupport.thumbnail(of: url, maxPixel: bucket)
        } else if fileSize >= Self.largeFileThreshold {
            image = await runSerially { Self.makeImage(url: url, maxPixel: bucket, allowFullDecode: allowFullDecode) }
        } else {
            image = Self.makeImage(url: url, maxPixel: bucket, allowFullDecode: allowFullDecode)
        }
        guard let image else { return nil }
        store(image, url, bucket)
        if fileSize >= Self.diskCacheThreshold {
            PerfLog.image(url.lastPathComponent, bucket: bucket, source: "ファイル", since: start)
        }

        let elapsed = start.duration(to: .now)
        if fileSize >= Self.diskCacheThreshold, elapsed > .milliseconds(Int(Self.slowDecodeSeconds * 1000)) {
            ThumbnailDiskCache.shared.write(image, for: url, bucket: bucket)
            // プレビュー用の大きな画像から、グリッド用の小さな画像も作って保存しておく
            for b in [256, 384, 512] where b < bucket {
                if let small = Self.downscale(image, maxPixel: b) {
                    store(small, url, b)
                    ThumbnailDiskCache.shared.write(small, for: url, bucket: b)
                }
            }
        }
        return image
    }

    /// 大きなファイル用のキューで 1 件ずつ実行する。待っている間に取り消されたら読まない
    private func runSerially(_ work: @escaping @Sendable () -> CGImage?) async -> CGImage? {
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
                largeFileQueue.async {
                    cont.resume(returning: flag.isCancelled ? nil : work())
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    #endif

    /// 長辺が maxPixel になるよう縮小する（すでに小さければ nil）
    static func downscale(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let longSide = max(image.width, image.height)
        guard longSide > maxPixel else { return nil }
        let scale = Double(maxPixel) / Double(longSide)
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// ファイルの種類に応じて画像を作る
    static func makeImage(url: URL, maxPixel: Int, allowFullDecode: Bool) -> CGImage? {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        // 大きな TIF は表示に使う画像データだけを読む（レイヤー情報まで読むと数倍遅い）
        if TIFFCompositeReader.shouldUse(url, fileSize: fileSize),
           let image = TIFFCompositeReader.thumbnail(of: url, maxPixel: maxPixel) {
            return image
        }
        return makeThumbnail(url: url, maxPixel: maxPixel, allowFullDecode: allowFullDecode)
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
