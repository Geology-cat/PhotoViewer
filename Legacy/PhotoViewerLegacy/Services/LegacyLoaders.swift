import AppKit
import AVFoundation
import Foundation

// 10.12 では Swift の並行処理（async/await・Task・actor）が使えないため、
// 通常版で async になっている読み込みを GCD（DispatchQueue・OperationQueue）で行う

// MARK: - 取り消しできる要求

/// 読み込み要求（取り消すと、まだ始まっていなければ読まずに終わり、終わっていても結果を渡さない）
final class LoadRequest {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

// MARK: - サムネイル

extension ThumbnailLoader {
    /// 画像の読み込み用キュー（古い Mac は 2〜4 コアなので、同時に読む数を絞る）
    private static let decodeQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.geologycat.PhotoViewerLegacy.decode"
        q.maxConcurrentOperationCount = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount))
        q.qualityOfService = .userInitiated
        return q
    }()

    /// 画像を用意して、メインスレッドで completion を呼ぶ（キャッシュにあればすぐ呼ぶ）
    /// 通常版の `load(_:pixelSize:allowFullDecode:) async` と同じ手順（メモリ → 大きい画像の縮小 → ディスク → ファイル）
    @discardableResult
    func request(_ url: URL, pixelSize: Int, allowFullDecode: Bool,
                 completion: @escaping (CGImage?) -> Void) -> LoadRequest {
        let req = LoadRequest()
        if let hit = cached(url, pixelSize: pixelSize) {
            completion(hit)
            return req
        }
        let bucket = Self.bucket(for: pixelSize)
        let finish: (CGImage?) -> Void = { image in
            DispatchQueue.main.async { if !req.isCancelled { completion(image) } }
        }
        Self.decodeQueue.addOperation { [self] in
            guard !req.isCancelled else { return }
            // プレビュー用に読んだ大きな画像があれば、それを縮小する
            for b in Self.buckets where b > bucket {
                if let larger = cached(url, pixelSize: b), let small = Self.downscale(larger, maxPixel: bucket) {
                    store(small, url, bucket)
                    finish(small)
                    return
                }
            }
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
            if fileSize >= Self.diskCacheThreshold, let disk = ThumbnailDiskCache.shared.read(url, bucket: bucket) {
                store(disk, url, bucket)
                finish(disk)
                return
            }
            let work = { [self] () -> CGImage? in
                guard !req.isCancelled else { return nil }
                let start = Date()
                let image: CGImage?
                if SupportedFormats.isVideo(url) {
                    image = VideoSupport.thumbnailSync(of: url, maxPixel: bucket)
                } else {
                    image = Self.makeImage(url: url, maxPixel: bucket, allowFullDecode: allowFullDecode)
                }
                guard let image else { return nil }
                store(image, url, bucket)
                if fileSize >= Self.diskCacheThreshold, Date().timeIntervalSince(start) > Self.slowDecodeSeconds {
                    ThumbnailDiskCache.shared.write(image, for: url, bucket: bucket)
                    for b in [256, 384, 512] where b < bucket {
                        if let small = Self.downscale(image, maxPixel: b) {
                            store(small, url, b)
                            ThumbnailDiskCache.shared.write(small, for: url, bucket: b)
                        }
                    }
                }
                return image
            }
            // 大きなファイルは 1 枚ずつ読む（HDD の読み取り位置の移動を減らす）
            if fileSize >= Self.largeFileThreshold && !SupportedFormats.isVideo(url) {
                largeFileQueue.async { finish(work()) }
            } else {
                finish(work())
            }
        }
        return req
    }

    /// 大きさを指定して読む（拡大表示用。キャッシュには入れない）
    static func requestDetail(_ url: URL, maxPixel: Int, completion: @escaping (CGImage?) -> Void) -> LoadRequest {
        let req = LoadRequest()
        DispatchQueue.global(qos: .userInitiated).async {
            guard !req.isCancelled else { return }
            let image = makeImage(url: url, maxPixel: maxPixel, allowFullDecode: true)
            DispatchQueue.main.async { if !req.isCancelled { completion(image) } }
        }
        return req
    }
}

// MARK: - 撮影情報

extension MetadataReader {
    /// 写真でも動画でも読む（同期。バックグラウンドで呼ぶこと）
    static func readAnySync(url: URL) -> PhotoMetadata {
        SupportedFormats.isVideo(url) ? VideoSupport.metadataSync(of: url) : read(url: url)
    }
}

// MARK: - 動画

extension VideoSupport {
    /// サムネイル：冒頭から少し進んだ所（1 秒、短い動画なら長さの 1/3）の 1 コマ
    static func thumbnailSync(of url: URL, maxPixel: Int) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let duration = CMTimeGetSeconds(asset.duration)
        let seconds = duration.isFinite && duration > 0 ? min(1, duration / 3) : 0
        return try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    }

    /// 撮影情報：長さ・解像度・フレームレート・撮影日・カメラ・位置情報
    static func metadataSync(of url: URL) -> PhotoMetadata {
        let asset = AVURLAsset(url: url)
        var m = PhotoMetadata()
        let s = CMTimeGetSeconds(asset.duration)
        if s.isFinite, s > 0 { m.duration = s }
        if let track = asset.tracks(withMediaType: .video).first {
            let rotated = track.naturalSize.applying(track.preferredTransform)
            m.pixelWidth = Int(abs(rotated.width).rounded())
            m.pixelHeight = Int(abs(rotated.height).rounded())
            if track.nominalFrameRate > 0 { m.frameRate = Double(track.nominalFrameRate) }
        }
        var items = asset.commonMetadata
        for format in asset.availableMetadataFormats { items += asset.metadata(forFormat: format) }
        func string(_ identifiers: [AVMetadataIdentifier], key: String? = nil) -> String? {
            for item in items {
                let matches = item.identifier.map(identifiers.contains) ?? false
                    || (key != nil && (item.key as? String) == key)
                if matches, let s = item.stringValue, !s.isEmpty { return s }
            }
            return nil
        }
        if let s = string([.quickTimeMetadataCreationDate, .commonIdentifierCreationDate]) {
            m.captureDate = parseISODate(s)
        }
        m.cameraMake = string([.quickTimeMetadataMake, .commonIdentifierMake])
        m.cameraModel = string([.quickTimeMetadataModel, .commonIdentifierModel])
        if let loc = string([.quickTimeMetadataLocationISO6709, .commonIdentifierLocation]) {
            m.coordinate = parseISO6709(loc)
        }
        return m
    }
}

// MARK: - サイドカーの書き込み

/// サイドカーへの書き込みを 1 件ずつ順番に行う（通常版の actor SidecarWriter と同じ役割）
final class SidecarWriter {
    static let shared = SidecarWriter()
    private let queue = DispatchQueue(label: "com.geologycat.PhotoViewerLegacy.sidecar", qos: .userInitiated)

    /// 各サイドカーに change を適用し、失敗したものの (URL, 理由) をメインスレッドで返す
    func update(_ urls: [URL], images: [URL: URL] = [:], change: @escaping (inout PhotoTags) -> Void,
                completion: @escaping ([(URL, String)]) -> Void) {
        queue.async {
            var failed: [(URL, String)] = []
            for u in urls {
                do {
                    var base = PhotoTags()
                    if !FileManager.default.fileExists(atPath: u.path), let image = images[u],
                       let r = MetadataReader.read(url: image).embeddedRating {
                        base.rating = r
                    }
                    try XMPSidecar.update(at: u, base: base, change: change)
                } catch {
                    failed.append((u, error.localizedDescription))
                }
            }
            DispatchQueue.main.async { completion(failed) }
        }
    }
}

// MARK: - フォルダの監視

/// フォルダの変更（ファイルの追加・削除・名前変更）を監視する。変更が落ち着いてから 1 回だけ知らせる
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void
    private var generation = 0

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit { source?.cancel() }

    func watch(_ folder: URL) {
        stop()
        let gen = generation
        let path = folder.path
        // フォルダを開く処理はバックグラウンドで（止まっている HDD では時間がかかる）
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { return }
            DispatchQueue.main.async {
                guard let self = self, self.generation == gen else {
                    close(fd)
                    return
                }
                let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                                    eventMask: [.write, .rename, .delete], queue: .main)
                src.setEventHandler { [weak self] in self?.schedule() }
                src.setCancelHandler { close(fd) }
                src.resume()
                self.source = src
            }
        }
    }

    func stop() {
        generation += 1
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: item)
    }
}

// MARK: - 少しの補助

/// バックグラウンドで計算して、結果をメインスレッドで受け取る
func runInBackground<T>(qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping () -> T,
                        then: @escaping (T) -> Void) {
    DispatchQueue.global(qos: qos).async {
        let value = work()
        DispatchQueue.main.async { then(value) }
    }
}
