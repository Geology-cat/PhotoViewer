import Foundation
import ImageIO
import Testing
@testable import PhotoViewer

struct XMPSidecarTests {
    /// Lightroom Classic が書くサイドカーに近い形（属性形式のレーティング、crs 名前空間、rdf:Seq を含む）
    static let lightroomStyle = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        ">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
       xmp:Rating="3"
       xmp:MetadataDate="2024-01-01T10:00:00+09:00"
       tiff:Make="Canon"
       crs:Version="16.0"
       crs:Exposure2012="+0.35"
       crs:Contrast2012="+12">
       <crs:ToneCurvePV2012>
        <rdf:Seq>
         <rdf:li>0, 0</rdf:li>
         <rdf:li>255, 255</rdf:li>
        </rdf:Seq>
       </crs:ToneCurvePV2012>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    """

    /// 子要素形式のレーティング、Description が複数ある形
    static let elementStyle = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
       <dc:subject><rdf:Bag><rdf:li>星空</rdf:li></rdf:Bag></dc:subject>
      </rdf:Description>
      <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
       <xmp:Rating>4</xmp:Rating>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """

    @Test func 属性形式のレーティングを読む() throws {
        let t = try XMPSidecar.parse(Data(Self.lightroomStyle.utf8))
        #expect(t.rating == 3)
        #expect(t.developed == false)
    }

    @Test func 子要素形式のレーティングを読む() throws {
        let t = try XMPSidecar.parse(Data(Self.elementStyle.utf8))
        #expect(t.rating == 4)
    }

    @Test func 書き換えても現像設定が残る() throws {
        let out = try XMPSidecar.updated(Data(Self.lightroomStyle.utf8),
                                         with: PhotoTags(rating: 5, developed: true))
        let s = String(decoding: out, as: UTF8.self)
        // 他の項目が残っている
        #expect(s.contains("crs:Exposure2012=\"+0.35\""))
        #expect(s.contains("crs:Contrast2012=\"+12\""))
        #expect(s.contains("tiff:Make=\"Canon\""))
        #expect(s.contains("<rdf:li>255, 255</rdf:li>"))
        // レーティングは 1 つだけで、新しい値になっている
        #expect(s.components(separatedBy: "Rating").count == 2)
        let t = try XMPSidecar.parse(out)
        #expect(t.rating == 5)
        #expect(t.developed == true)
    }

    @Test func 子要素形式を書き換えると重複しない() throws {
        let out = try XMPSidecar.updated(Data(Self.elementStyle.utf8), with: PhotoTags(rating: 2))
        let s = String(decoding: out, as: UTF8.self)
        #expect(!s.contains("<xmp:Rating>4</xmp:Rating>"))
        #expect(s.contains("星空"))
        #expect(try XMPSidecar.parse(out).rating == 2)
    }

    @Test func レーティングなしにすると項目を消す() throws {
        let out = try XMPSidecar.updated(Data(Self.lightroomStyle.utf8), with: PhotoTags(rating: 0))
        let s = String(decoding: out, as: UTF8.self)
        #expect(!s.contains("Rating"))
        #expect(try XMPSidecar.parse(out) == PhotoTags())
    }

    @Test func リジェクトを扱える() throws {
        let out = try XMPSidecar.updated(nil, with: PhotoTags(rating: -1))
        #expect(try XMPSidecar.parse(out).rating == -1)
    }

    @Test func 新規作成と現像済みの解除() throws {
        let created = try XMPSidecar.updated(nil, with: PhotoTags(rating: 1, developed: true))
        #expect(try XMPSidecar.parse(created) == PhotoTags(rating: 1, developed: true))
        let cleared = try XMPSidecar.updated(created, with: PhotoTags(rating: 1, developed: false))
        #expect(try XMPSidecar.parse(cleared) == PhotoTags(rating: 1, developed: false))
    }

    @Test func 壊れたファイルは上書きしない() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("IMG_0001.xmp")
        let broken = Data("<x:xmpmeta><rdf:RDF>壊れている".utf8)
        try broken.write(to: url)
        #expect(throws: XMPError.self) {
            try XMPSidecar.write(PhotoTags(rating: 3), to: url)
        }
        #expect(try Data(contentsOf: url) == broken)
    }

    @Test func ファイルへの書き込みと読み込み() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("IMG_0001.xmp")
        #expect(try XMPSidecar.read(from: url) == nil)
        try XMPSidecar.write(PhotoTags(rating: 4, developed: true), to: url)
        #expect(try XMPSidecar.read(from: url) == PhotoTags(rating: 4, developed: true))
    }
}

/// ファイル内の XMP に★があり、サイドカーがまだ無い JPEG の扱い
struct EmbeddedRatingTests {
    @Test func サイドカー作成時にファイル内の星を引き継ぐ() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // ★3 をファイル内の XMP に持つ JPEG を作る
        let jpg = dir.appendingPathComponent("IMG_9.JPG")
        let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = try #require(ctx.makeImage())
        let meta = CGImageMetadataCreateMutable()
        #expect(CGImageMetadataRegisterNamespaceForPrefix(meta, XMPSidecar.xmpNS as CFString, "xmp" as CFString, nil))
        #expect(CGImageMetadataSetValueWithPath(meta, nil, "xmp:Rating" as CFString, "3" as CFString))
        let dest = try #require(CGImageDestinationCreateWithURL(jpg as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(dest, image, meta, nil)
        #expect(CGImageDestinationFinalize(dest))

        let embedded = try #require(MetadataReader.read(url: jpg).embeddedRating)
        #expect(embedded == 3)

        // 現像済みだけを付けても★3 が残る
        let sidecar = dir.appendingPathComponent("IMG_9.xmp")
        let result = try XMPSidecar.update(at: sidecar, base: PhotoTags(rating: embedded)) { $0.developed = true }
        #expect(result == PhotoTags(rating: 3, developed: true))
        #expect(try XMPSidecar.read(from: sidecar) == PhotoTags(rating: 3, developed: true))
    }

    @Test func レーティング条件では撮影情報を読み込む() {
        var f = PhotoFilter()
        #expect(!f.needsMetadata)
        f.rating = .atLeast(3)
        #expect(f.needsMetadata)
        #expect(!f.usesExifConditions)
    }
}

extension EmbeddedRatingTests {
    @Test func 書き込み処理が画像からファイル内の星を読む() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpg = dir.appendingPathComponent("IMG_8.JPG")
        let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let meta = CGImageMetadataCreateMutable()
        _ = CGImageMetadataRegisterNamespaceForPrefix(meta, XMPSidecar.xmpNS as CFString, "xmp" as CFString, nil)
        _ = CGImageMetadataSetValueWithPath(meta, nil, "xmp:Rating" as CFString, "4" as CFString)
        let dest = try #require(CGImageDestinationCreateWithURL(jpg as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(dest, try #require(ctx.makeImage()), meta, nil)
        #expect(CGImageDestinationFinalize(dest))

        let sidecar = dir.appendingPathComponent("IMG_8.xmp")
        let failed = await SidecarWriter.shared.update([sidecar], images: [sidecar: jpg]) { $0.developed = true }
        #expect(failed.isEmpty)
        #expect(try XMPSidecar.read(from: sidecar) == PhotoTags(rating: 4, developed: true))
    }
}
