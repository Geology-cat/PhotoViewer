import Foundation
import ImageIO

/// ImageIO で撮影情報を読み取る（UI に依存しない。どのスレッドからでも呼べる）
enum MetadataReader {
    static func read(url: URL) -> PhotoMetadata {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return .empty }
        guard let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            return .empty
        }
        var meta = parse(properties: raw)
        if let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            meta.embeddedRating = embeddedRating(from: xmp)
        }
        return meta
    }

    /// プロパティ辞書から撮影情報を組み立てる（テストしやすいよう分離）
    static func parse(properties p: [CFString: Any]) -> PhotoMetadata {
        var m = PhotoMetadata()
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exifAux = p[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]

        if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String
            ?? tiff[kCGImagePropertyTIFFDateTime] as? String {
            m.captureDate = parseExifDate(s, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
        }
        if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let first = isos.first {
            m.iso = first.intValue
        }
        // 電子接点のないレンズや望遠鏡では 0 が入るので「不明」として扱う
        m.fNumber = positive(exif[kCGImagePropertyExifFNumber])
        m.exposureTime = positive(exif[kCGImagePropertyExifExposureTime])
        m.focalLength = positive(exif[kCGImagePropertyExifFocalLength])
        m.cameraMake = trimmed(tiff[kCGImagePropertyTIFFMake] as? String)
        m.cameraModel = trimmed(tiff[kCGImagePropertyTIFFModel] as? String)
        m.lensModel = trimmed(exif[kCGImagePropertyExifLensModel] as? String)
            ?? trimmed(exifAux[kCGImagePropertyExifAuxLensModel] as? String)

        var w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        var h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        // 回転タグが 5〜8 なら縦横を入れ替えて表示する
        if let o = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(o) {
            swap(&w, &h)
        }
        m.pixelWidth = w
        m.pixelHeight = h

        if let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            m.coordinate = gpsCoordinate(from: gps)
            if let alt = (gps[kCGImagePropertyGPSAltitude] as? NSNumber)?.doubleValue {
                let below = (gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue == 1
                m.altitude = below ? -alt : alt
            }
        }
        return m
    }

    /// GPS 辞書から 10 進度の緯度経度を作る。Ref が S / W のときはマイナスにする
    static func gpsCoordinate(from gps: [CFString: Any]) -> GPSCoordinate? {
        guard var lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
              var lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue else { return nil }
        if let ref = gps[kCGImagePropertyGPSLatitudeRef] as? String, ref.uppercased() == "S" { lat = -abs(lat) }
        if let ref = gps[kCGImagePropertyGPSLongitudeRef] as? String, ref.uppercased() == "W" { lon = -abs(lon) }
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        // 0,0 は「未取得」を意味することが多いので除外する
        if lat == 0 && lon == 0 { return nil }
        return GPSCoordinate(latitude: lat, longitude: lon)
    }

    /// 「2025:08:15 10:30:00」形式の EXIF 日時を Date にする。オフセットがなければローカル時刻とみなす
    static func parseExifDate(_ s: String, offset: String?) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let trimmedDate = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        if let offset, !offset.isEmpty {
            f.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let d = f.date(from: trimmedDate + offset) { return d }
        }
        f.timeZone = .current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: trimmedDate)
    }

    /// ファイル内 XMP の xmp:Rating
    static func embeddedRating(from metadata: CGImageMetadata) -> Int? {
        guard let value = CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:Rating" as CFString) else {
            return nil
        }
        guard let d = Double(value as String), d.isFinite else { return nil }
        return Int(d)
    }

    private static func positive(_ v: Any?) -> Double? {
        guard let d = (v as? NSNumber)?.doubleValue, d > 0, d.isFinite else { return nil }
        return d
    }

    private static func trimmed(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
              !t.isEmpty else { return nil }
        return t
    }
}
