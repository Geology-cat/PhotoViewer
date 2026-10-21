import AVFoundation
import CoreGraphics
import Foundation

/// 動画のサムネイルと撮影情報（AVFoundation を使う）
enum VideoSupport {
    #if !LEGACY
    /// サムネイル：冒頭から少し進んだ所（1 秒、短い動画なら長さの 1/3）の 1 コマ
    static func thumbnail(of url: URL, maxPixel: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true   // 縦向きで撮った動画を正しい向きにする
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let seconds = duration.isFinite && duration > 0 ? min(1, duration / 3) : 0
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// 撮影情報：長さ・解像度・フレームレート・撮影日・カメラ・位置情報
    static func metadata(of url: URL) async -> PhotoMetadata {
        let asset = AVURLAsset(url: url)
        var m = PhotoMetadata()
        if let d = try? await asset.load(.duration) {
            let s = CMTimeGetSeconds(d)
            if s.isFinite, s > 0 { m.duration = s }
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform, fps) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate) {
            // 縦向きの動画は幅と高さを入れ替える
            let rotated = size.applying(transform)
            m.pixelWidth = Int(abs(rotated.width).rounded())
            m.pixelHeight = Int(abs(rotated.height).rounded())
            if fps > 0 { m.frameRate = Double(fps) }
        }

        var items = (try? await asset.load(.commonMetadata)) ?? []
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            items += (try? await asset.loadMetadata(for: format)) ?? []
        }
        func string(_ identifiers: [AVMetadataIdentifier], key: String? = nil) async -> String? {
            for item in items {
                let matches = item.identifier.map(identifiers.contains) ?? false
                    || (key != nil && (item.key as? String) == key)
                if matches, let s = try? await item.load(.stringValue), !s.isEmpty { return s }
            }
            return nil
        }

        // 撮影日：QuickTime の作成日 → 共通メタデータの作成日 → asset.creationDate
        if let s = await string([.quickTimeMetadataCreationDate, .commonIdentifierCreationDate]) {
            m.captureDate = parseISODate(s)
        }
        if m.captureDate == nil, let item = try? await asset.load(.creationDate),
           let d = try? await item.load(.dateValue) {
            m.captureDate = d
        }
        m.cameraMake = await string([.quickTimeMetadataMake, .commonIdentifierMake])
        m.cameraModel = await string([.quickTimeMetadataModel, .commonIdentifierModel])
        if let loc = await string([.quickTimeMetadataLocationISO6709, .commonIdentifierLocation]) {
            m.coordinate = parseISO6709(loc)
        }
        return m
    }
    #endif

    /// 「2023-10-17T14:05:09+0900」などの日時
    static func parseISODate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        var optionList: [ISO8601DateFormatter.Options] = [[.withInternetDateTime]]
        // 小数の秒は macOS 10.13 以降（10.12 では下の DateFormatter で読む）
        if #available(macOS 10.13, *) { optionList.append([.withInternetDateTime, .withFractionalSeconds]) }
        for options in optionList {
            iso.formatOptions = options
            if let d = iso.date(from: s) { return d }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd HH:mm:ss Z"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// ISO 6709 形式の位置（例：「+35.6812+139.7671+012.345/」）を緯度経度にする
    static func parseISO6709(_ s: String) -> GPSCoordinate? {
        var numbers: [Double] = []
        var current = ""
        for ch in s {
            if (ch == "+" || ch == "-") && !current.isEmpty {
                if let v = Double(current) { numbers.append(v) }
                current = String(ch)
            } else if ch == "/" {
                break
            } else {
                current.append(ch)
            }
        }
        if let v = Double(current) { numbers.append(v) }
        guard numbers.count >= 2, (-90...90).contains(numbers[0]), (-180...180).contains(numbers[1]) else { return nil }
        if numbers[0] == 0 && numbers[1] == 0 { return nil }
        return GPSCoordinate(latitude: numbers[0], longitude: numbers[1])
    }
}
