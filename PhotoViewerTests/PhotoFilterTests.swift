import Foundation
import Testing
@testable import PhotoViewer

struct PhotoFilterTests {
    private func item(_ name: String, size: Int64 = 100, mod: TimeInterval = 0) -> PhotoItem {
        PhotoItem(url: URL(fileURLWithPath: "/tmp/pv/\(name)"), fileSize: size,
                  modificationDate: Date(timeIntervalSince1970: mod))
    }

    private func date(_ s: String) -> Date {
        MetadataReader.parseExifDate(s, offset: nil)!
    }

    private var items: [PhotoItem] {
        [item("A.CR3", size: 300), item("A.JPG", size: 100), item("B.JPG", size: 200), item("C.HEIC", size: 50)]
    }

    private var metadata: [URL: PhotoMetadata] {
        var a = PhotoMetadata()
        a.cameraMake = "Canon"; a.cameraModel = "Canon EOS R5"; a.lensModel = "RF24-70mm F2.8"
        a.iso = 100; a.fNumber = 2.8; a.exposureTime = 1.0 / 250; a.focalLength = 50
        a.captureDate = date("2025:08:15 10:00:00")
        a.coordinate = GPSCoordinate(latitude: 35, longitude: 139)
        var b = PhotoMetadata()
        b.cameraMake = "SONY"; b.cameraModel = "ILCE-7RM5"; b.lensModel = "FE 24-70mm F2.8 GM II"
        b.iso = 3200; b.fNumber = 8; b.exposureTime = 2; b.focalLength = 24
        b.captureDate = date("2025:08:20 23:59:00")
        var c = PhotoMetadata()
        c.iso = 800
        c.captureDate = date("2024:01:01 00:00:00")
        let base = items
        return [base[0].url: a, base[1].url: a, base[2].url: b, base[3].url: c]
    }

    private func names(_ f: PhotoFilter, tags: [String: PhotoTags] = [:]) -> [String] {
        f.apply(to: items, metadata: metadata) { tags[$0.lastPathComponent] ?? .empty }.map(\.name)
    }

    @Test func 条件なしはそのまま() {
        #expect(names(PhotoFilter()) == ["A.CR3", "A.JPG", "B.JPG", "C.HEIC"])
        #expect(!PhotoFilter().isFiltering)
    }

    @Test func 拡張子で絞り込む() {
        var f = PhotoFilter()
        f.extensions = ["jpg"]
        #expect(names(f) == ["A.JPG", "B.JPG"])
    }

    @Test func フリーワードはファイル名とカメラとレンズに一致() {
        var f = PhotoFilter()
        f.text = "sony"
        #expect(names(f) == ["B.JPG"])
        f.text = "rf24 canon"
        #expect(names(f) == ["A.CR3", "A.JPG"])
        f.text = "heic"
        #expect(names(f) == ["C.HEIC"])
    }

    @Test func レーティングと現像済み() {
        let tags = ["A.CR3": PhotoTags(rating: 3, developed: true), "B.JPG": PhotoTags(rating: 5),
                    "C.HEIC": PhotoTags(rating: -1)]
        var f = PhotoFilter()
        f.rating = .atLeast(3)
        #expect(names(f, tags: tags) == ["A.CR3", "B.JPG"])
        f.rating = .exactly(5)
        #expect(names(f, tags: tags) == ["B.JPG"])
        f.rating = .unrated
        #expect(names(f, tags: tags) == ["A.JPG"])
        f.rating = .rejected
        #expect(names(f, tags: tags) == ["C.HEIC"])
        f.rating = .all
        f.developed = .yes
        #expect(names(f, tags: tags) == ["A.CR3"])
        f.developed = .no
        #expect(names(f, tags: tags) == ["A.JPG", "B.JPG", "C.HEIC"])
    }

    @Test func 撮影日の範囲は終了日の終わりまで含む() {
        var f = PhotoFilter()
        f.dateFrom = date("2025:08:20 12:00:00")
        f.dateTo = date("2025:08:20 12:00:00")
        #expect(names(f) == ["B.JPG"])
        #expect(f.needsMetadata)
    }

    @Test func カメラとレンズ() {
        var f = PhotoFilter()
        f.cameras = ["Canon EOS R5"]
        #expect(names(f) == ["A.CR3", "A.JPG"])
        f.cameras = []
        f.lenses = ["FE 24-70mm F2.8 GM II"]
        #expect(names(f) == ["B.JPG"])
    }

    @Test func 撮影条件の範囲() {
        var f = PhotoFilter()
        f.iso = NumberRange(min: 800, max: nil)
        #expect(names(f) == ["B.JPG", "C.HEIC"])
        f.iso = NumberRange()
        f.fNumber = NumberRange(min: nil, max: 4)
        #expect(names(f) == ["A.CR3", "A.JPG"])
        f.fNumber = NumberRange()
        f.exposure = NumberRange(min: 1, max: nil)
        #expect(names(f) == ["B.JPG"])
        f.exposure = NumberRange()
        f.focalLength = NumberRange(min: 24, max: 24)
        #expect(names(f) == ["B.JPG"])
    }

    @Test func 位置情報の有無() {
        var f = PhotoFilter()
        f.gps = .yes
        #expect(names(f) == ["A.CR3", "A.JPG"])
        f.gps = .no
        #expect(names(f) == ["B.JPG", "C.HEIC"])
    }

    @Test func 撮影情報が未読み込みのファイルは撮影情報の条件に一致しない() {
        var f = PhotoFilter()
        f.iso = NumberRange(min: 0, max: nil)
        let result = f.apply(to: items, metadata: [:]) { _ in .empty }
        #expect(result.isEmpty)
    }

    @Test func 並べ替え() {
        var f = PhotoFilter()
        f.sortKey = .fileSize
        #expect(names(f) == ["C.HEIC", "A.JPG", "B.JPG", "A.CR3"])
        f.ascending = false
        #expect(names(f) == ["A.CR3", "B.JPG", "A.JPG", "C.HEIC"])
        f.sortKey = .captureDate
        f.ascending = true
        #expect(names(f) == ["C.HEIC", "A.CR3", "A.JPG", "B.JPG"])
        f.sortKey = .name
        f.ascending = false
        #expect(names(f) == ["C.HEIC", "B.JPG", "A.JPG", "A.CR3"])
    }

    @Test func シャッタースピードの入力を秒にする() {
        #expect(ExposureParser.seconds(from: "1/250") == 1.0 / 250)
        #expect(ExposureParser.seconds(from: "2\"") == 2)
        #expect(ExposureParser.seconds(from: " 0.5 ") == 0.5)
        #expect(ExposureParser.seconds(from: "1/0") == nil)
        #expect(ExposureParser.seconds(from: "") == nil)
    }
}
