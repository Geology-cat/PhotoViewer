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
