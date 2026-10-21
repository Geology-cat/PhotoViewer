import Foundation
import ImageIO
import Testing
@testable import PhotoViewer

struct MetadataTests {
    @Test func 南緯と西経はマイナスになる() throws {
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 22.951916, kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 43.210487, kCGImagePropertyGPSLongitudeRef: "W",
        ]
        let c = try #require(MetadataReader.gpsCoordinate(from: gps))
        #expect(c.latitude == -22.951916)
        #expect(c.longitude == -43.210487)
        #expect(c.text == "-22.951916, -43.210487")
    }

    @Test func 北緯と東経はプラスのまま() throws {
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 35.681236, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 139.767125, kCGImagePropertyGPSLongitudeRef: "E",
        ]
        let c = try #require(MetadataReader.gpsCoordinate(from: gps))
        #expect(c.latitude == 35.681236)
        #expect(c.longitude == 139.767125)
    }

    @Test func 地図URLの形式() {
        let c = GPSCoordinate(latitude: 35.681236, longitude: 139.767125)
        #expect(c.googleMapsURL.absoluteString
            == "https://www.google.com/maps/search/?api=1&query=35.681236,139.767125")
        #expect(c.gsiMapsURL().absoluteString == "https://maps.gsi.go.jp/#16/35.681236/139.767125/")
    }

    @Test func 緯度経度ゼロは位置情報なし扱い() {
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 0.0, kCGImagePropertyGPSLongitude: 0.0]
        #expect(MetadataReader.gpsCoordinate(from: gps) == nil)
    }

    @Test func シャッタースピードの表示() {
        #expect(ExifFormat.exposure(1.0 / 250) == "1/250")
        #expect(ExifFormat.exposure(1.0 / 8000) == "1/8000")
        #expect(ExifFormat.exposure(2) == "2\"")
        #expect(ExifFormat.exposure(0.5) == "1/2")
        #expect(ExifFormat.exposure(1.0 / 1.3) == "1/1.3")
        #expect(ExifFormat.exposure(1.5) == "1.5\"")
    }

    @Test func F値の表示() {
        #expect(ExifFormat.fNumber(2.8) == "f/2.8")
        #expect(ExifFormat.fNumber(8) == "f/8")
    }

    @Test func EXIF日時をオフセット付きで解釈() throws {
        let d = try #require(MetadataReader.parseExifDate("2025:08:15 10:30:00", offset: "+09:00"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        #expect(cal.component(.hour, from: d) == 1)
    }

    @Test func カメラ名の重複を避ける() {
        var m = PhotoMetadata()
        m.cameraMake = "Canon"
        m.cameraModel = "Canon EOS R5"
        #expect(m.cameraName == "Canon EOS R5")
        m.cameraMake = "NIKON CORPORATION"
        m.cameraModel = "Z 8"
        #expect(m.cameraName == "NIKON CORPORATION Z 8")
        m.cameraMake = "SONY"
        m.cameraModel = "ILCE-7RM5"
        #expect(m.cameraName == "SONY ILCE-7RM5")
    }

    @Test func 生成した画像から撮影情報を読む() throws {
        // 一時フォルダに EXIF・GPS 付き JPEG を作って読み戻す
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pv_meta_test.jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifISOSpeedRatings: [1600],
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifExposureTime: 1.0 / 60,
                kCGImagePropertyExifDateTimeOriginal: "2024:01:02 03:04:05",
                kCGImagePropertyExifLensModel: "Test Lens",
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "EOS R5"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 33.856784, kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 151.215297, kCGImagePropertyGPSLongitudeRef: "E",
            ],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        let m = MetadataReader.read(url: url)
        #expect(m.iso == 1600)
        #expect(m.fNumber == 2.8)
        #expect(m.lensModel == "Test Lens")
        #expect(m.cameraName == "Canon EOS R5")
        #expect(m.pixelWidth == 64)
        let c = try #require(m.coordinate)
        #expect(abs(c.latitude + 33.856784) < 1e-6)
        #expect(m.captureDate != nil)
    }
}

extension MetadataTests {
    @Test func F値や焦点距離が0なら不明として扱う() {
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifFNumber: 0.0,
                kCGImagePropertyExifFocalLength: 0.0,
                kCGImagePropertyExifExposureTime: 80.0,
            ],
        ]
        let m = MetadataReader.parse(properties: props)
        #expect(m.fNumber == nil)
        #expect(m.focalLength == nil)
        #expect(m.exposureTime == 80)
    }
}

/// サイドバーの「親フォルダ」一覧が必ず終わること（macOS 15 で「/」の親が「/..」になり無限ループした不具合の再発防止）
struct SidebarNavigationTests {
    @Test func ルートの親フォルダは空() {
        #expect(SidebarNavigation.ancestors(of: URL(fileURLWithPath: "/", isDirectory: true)).isEmpty)
    }

    @Test func 普通のフォルダは近い順にルートまで() {
        let paths = SidebarNavigation.ancestors(of: URL(fileURLWithPath: "/Users/someone/Pictures", isDirectory: true))
            .map(\.path)
        #expect(paths == ["/Users/someone", "/Users", "/"])
    }

    @Test func 外付けドライブ() {
        let paths = SidebarNavigation.ancestors(of: URL(fileURLWithPath: "/Volumes/LaCie_d2/写真", isDirectory: true))
            .map(\.path)
        #expect(paths == ["/Volumes/LaCie_d2", "/Volumes", "/"])
    }

    @Test func 親を表すドットを含むパスでも終わる() {
        let result = SidebarNavigation.ancestors(of: URL(fileURLWithPath: "/../..", isDirectory: true))
        #expect(result.count < 64)
    }
}

struct PreviewRotationTests {
    @Test @MainActor func 回転後も枠に収まる() {
        let box = CGSize(width: 400, height: 300)
        // 横長 3:2 をそのまま
        #expect(PreviewView.fittedSize(CGSize(width: 1500, height: 1000), rotation: 0, in: box) == CGSize(width: 400, height: 400.0 * 1000 / 1500))
        // 90° 回すと縦長になるので高さ 300 に合わせる（回転前の幅が 300）
        let r = PreviewView.fittedSize(CGSize(width: 1500, height: 1000), rotation: 90, in: box)
        #expect(abs(r.width - 300) < 0.001)
        #expect(abs(r.height - 200) < 0.001)
        #expect(PreviewView.fittedSize(.zero, rotation: 90, in: box) == .zero)
    }
}

extension PreviewRotationTests {
    @Test @MainActor func 左回りの角度でも縦横を入れ替える() {
        let box = CGSize(width: 400, height: 300)
        #expect(PreviewView.fittedSize(CGSize(width: 1500, height: 1000), rotation: -90, in: box)
            == PreviewView.fittedSize(CGSize(width: 1500, height: 1000), rotation: 270, in: box))
        #expect(PreviewView.fittedSize(CGSize(width: 1500, height: 1000), rotation: -180, in: box)
            == PreviewView.fittedSize(CGSize(width: 1500, height: 1000), rotation: 0, in: box))
    }
}

struct ThumbnailDiskCacheTests {
    private func image(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    @Test func 保存して読み戻せて元ファイルを更新すると別扱い() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ThumbnailDiskCache(directory: dir.appendingPathComponent("cache"))
        let src = dir.appendingPathComponent("big.tif")
        try Data("dummy".utf8).write(to: src)
        #expect(cache.read(src, bucket: 512) == nil)
        cache.write(image(512, 341), for: src, bucket: 512)
        let back = try #require(cache.read(src, bucket: 512))
        #expect(back.width == 512 && back.height == 341)
        // 元ファイルを書き換えると（サイズ・更新日が変わると）、保存済みのものは使わない
        try Data("dummy-changed".utf8).write(to: src)
        #expect(cache.read(src, bucket: 512) == nil)
    }

    @Test func 上限を超えたら古いものから消す() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ThumbnailDiskCache(directory: dir)
        for i in 0..<10 {
            let f = dir.appendingPathComponent("f\(i).jpg")
            try Data(count: 1000).write(to: f)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(i))],
                                                  ofItemAtPath: f.path)
        }
        cache.prune(limit: 5000)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left.count == 4)
        #expect(left.first == "f6.jpg")
    }

    @Test func 縮小は長辺を合わせる() throws {
        let small = try #require(ThumbnailLoader.downscale(image(2048, 1365), maxPixel: 256))
        #expect(small.width == 256)
        #expect(ThumbnailLoader.downscale(image(200, 100), maxPixel: 256) == nil)
    }
}

/// 大きな TIF の一部だけを読む処理が、通常の読み方と同じ結果になること
struct TIFFCompositeReaderTests {
    /// テスト用の TIF を作る（EXIF・GPS・回転なし、16bit）
    private func makeTIFF(_ url: URL, width: Int = 300, height: Int = 200, bigEndianHint: Bool = false) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        for x in 0..<width {
            ctx.setFillColor(CGColor(red: Double(x) / Double(width), green: 0.3, blue: 0.7, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil))
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings: [3200], kCGImagePropertyExifFNumber: 2.8,
                                             kCGImagePropertyExifDateTimeOriginal: "2025:08:22 01:02:03"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "EOS 6D"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 41.8, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 141.1, kCGImagePropertyGPSLongitudeRef: "E"],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test func 撮影情報が通常の読み方と同じ() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeTIFF(url)
        let tiff = try #require(TIFFCompositeReader.metadata(of: url))
        let fast = MetadataReader.parse(properties: tiff.properties)
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let normal = MetadataReader.parse(properties: try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]))
        #expect(fast == normal)
        #expect(fast.iso == 3200)
        #expect(fast.pixelWidth == 300 && fast.pixelHeight == 200)
        #expect(fast.coordinate != nil)
    }

    @Test func サムネイルが通常の読み方と同じ大きさ() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeTIFF(url)
        let fast = try #require(TIFFCompositeReader.thumbnail(of: url, maxPixel: 128))
        #expect(fast.width == 128)
        #expect(fast.height == 85 || fast.height == 86)
    }

    @Test func TIFでなければ使わない() {
        #expect(!TIFFCompositeReader.shouldUse(URL(fileURLWithPath: "/a.jpg"), fileSize: 1 << 30))
        #expect(!TIFFCompositeReader.shouldUse(URL(fileURLWithPath: "/a.tif"), fileSize: 1 << 20))
        #expect(TIFFCompositeReader.shouldUse(URL(fileURLWithPath: "/a.TIF"), fileSize: 1 << 30))
        #expect(TIFFCompositeReader.metadata(of: URL(fileURLWithPath: "/存在しない.tif")) == nil)
    }
}

extension TIFFCompositeReaderTests {
    /// 無圧縮の縦長 TIF（行を飛び飛びに読む方法が使われる大きさ）
    @Test func 行を飛び飛びに読んでも通常のサムネイルとほぼ同じ() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: url) }
        let w = 400, h = 2400
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        // 上から下へのなめらかな色の変化
        for y in stride(from: 0, to: h, by: 8) {
            ctx.setFillColor(CGColor(red: Double(y) / Double(h), green: 0.5, blue: 1 - Double(y) / Double(h), alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: w, height: 8))
        }
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()),
                                   [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        let fast = try #require(TIFFCompositeReader.thumbnail(of: url, maxPixel: 120))
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let normal = try #require(CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 120,
        ] as CFDictionary))
        #expect(fast.width == normal.width && fast.height == normal.height)
        #expect(Self.meanDifference(fast, normal) < 4)
    }

    static func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
        func pixels(_ img: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
            let ctx = CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8,
                                bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            return buf
        }
        let pa = pixels(a), pb = pixels(b)
        return zip(pa, pb).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(pa.count)
    }
}

struct VideoSupportTests {
    @Test func ISO6709の位置() throws {
        let c = try #require(VideoSupport.parseISO6709("+35.6812+139.7671+012.345/"))
        #expect(abs(c.latitude - 35.6812) < 1e-9 && abs(c.longitude - 139.7671) < 1e-9)
        let s = try #require(VideoSupport.parseISO6709("-33.8568+151.2153/"))
        #expect(s.latitude < 0 && s.longitude > 0)
        let w = try #require(VideoSupport.parseISO6709("+40.6892-074.0445/"))
        #expect(w.longitude < 0)
        #expect(VideoSupport.parseISO6709("壊れた値") == nil)
    }

    @Test func 動画の日時() {
        #expect(VideoSupport.parseISODate("2023-10-17T14:05:09+0900") != nil)
        #expect(VideoSupport.parseISODate("2023-10-17T14:05:09+09:00") != nil)
        #expect(VideoSupport.parseISODate("いつか") == nil)
    }

    @Test func 長さの表示() {
        #expect(ExifFormat.duration(12.34) == "12.3 秒")
        #expect(ExifFormat.duration(83) == "1:23")
        #expect(ExifFormat.duration(3723) == "1:02:03")
    }

    @Test func 動画を対応形式に含める() {
        #expect(SupportedFormats.isSupported(URL(fileURLWithPath: "/a/IMG_0001.MOV")))
        #expect(SupportedFormats.isVideo(URL(fileURLWithPath: "/a/clip.mp4")))
        #expect(!SupportedFormats.isVideo(URL(fileURLWithPath: "/a/photo.jpg")))
    }
}
