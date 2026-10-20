import Foundation

/// 緯度経度（10 進度。南緯・西経はマイナス）
struct GPSCoordinate: Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    /// 「35.681236, 139.767125」形式
    var text: String { "\(Self.format(latitude)), \(Self.format(longitude))" }
    var latitudeText: String { Self.format(latitude) }
    var longitudeText: String { Self.format(longitude) }

    static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    /// Google マップで開く URL
    var googleMapsURL: URL {
        URL(string: "https://www.google.com/maps/search/?api=1&query=\(latitudeText),\(longitudeText)")!
    }

    /// 地理院地図で開く URL
    func gsiMapsURL(zoom: Int = 16) -> URL {
        URL(string: "https://maps.gsi.go.jp/#\(zoom)/\(latitudeText)/\(longitudeText)/")!
    }
}

/// 撮影情報（EXIF・TIFF・GPS から読み取る）
struct PhotoMetadata: Hashable, Sendable {
    var captureDate: Date?
    var iso: Int?
    var fNumber: Double?
    /// 露出時間（秒）
    var exposureTime: Double?
    var focalLength: Double?
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var coordinate: GPSCoordinate?
    var altitude: Double?
    /// ファイル内の XMP に書かれたレーティング（サイドカーが無いときに使う）
    var embeddedRating: Int?

    static let empty = PhotoMetadata()

    /// 「Canon EOS R5」のような表示用カメラ名（機種名にメーカー名が含まれていれば重複させない）
    var cameraName: String? {
        switch (cameraMake, cameraModel) {
        case let (make?, model?):
            let firstWord = make.split(separator: " ").first.map(String.init) ?? make
            if model.localizedCaseInsensitiveContains(firstWord) { return model }
            return "\(make) \(model)"
        case let (nil, model?): return model
        case let (make?, nil): return make
        default: return nil
        }
    }
}

/// 撮影情報の表示用フォーマット
enum ExifFormat {
    static func fNumber(_ v: Double) -> String {
        v == v.rounded() ? String(format: "f/%.0f", v) : String(format: "f/%.1f", v)
    }

    /// 1 秒未満は「1/250」、1 秒以上は「2"」
    static func exposure(_ t: Double) -> String {
        guard t > 0 else { return "-" }
        if t >= 1 {
            return t == t.rounded() ? String(format: "%.0f\"", t) : String(format: "%.1f\"", t)
        }
        let denom = 1 / t
        // 1/3 秒や 1/1.3 秒のような値を自然に表示する
        if denom < 10 && abs(denom - denom.rounded()) > 0.05 {
            return String(format: "1/%.1f", denom)
        }
        return "1/\(Int(denom.rounded()))"
    }

    static func focal(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f mm", v) : String(format: "%.1f mm", v)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return f
    }()

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
