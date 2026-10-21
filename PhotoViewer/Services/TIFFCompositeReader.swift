import Foundation
import ImageIO

/// 大きな TIF から必要な部分だけを読み出して、メモリ上に小さな TIF を作る
///
/// Photoshop で保存した TIF には、表示用の統合画像のほかにレイヤー情報（数百 MB）が入っていることがある。
/// ImageIO はサムネイルを作るときも撮影情報を読むときもファイル全体を読むため、外付け HDD では 1 枚に数秒〜20 秒かかる。
/// - 表示用：1 枚目の画像データと、色・形の情報だけを読む（844MB のファイルで 121MB）
/// - 撮影情報用：EXIF・GPS・XMP などのタグだけを読み、画像データは読まない
enum TIFFCompositeReader {
    /// 表示用の小さな TIF（画像データを含む）
    static func compositeData(of url: URL) -> Data? {
        guard let file = TIFFFile(url: url) else { return nil }
        return file.build(includePixels: true)
    }

    /// 撮影情報用の小さな TIF（画像データを含まない）
    static func metadataData(of url: URL) -> Data? {
        guard let file = TIFFFile(url: url) else { return nil }
        return file.build(includePixels: false)
    }

    /// 画像データの部分だけを読んでサムネイルを作る
    /// 無圧縮で、作る画像が元の行数よりずっと小さいときは、必要な行だけを飛び飛びに読む（HDD で 4〜5 倍速い）
    static func thumbnail(of url: URL, maxPixel: Int) -> CGImage? {
        if let file = TIFFFile(url: url), let image = file.subsampledThumbnail(maxPixel: maxPixel) {
            return image
        }
        guard let data = compositeData(of: url),
              let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// 撮影情報だけを読むための CGImageSource
    static func metadataSource(of url: URL) -> CGImageSource? {
        guard let data = metadataData(of: url) else { return nil }
        return CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// 撮影情報（プロパティ辞書と XMP）。画像データを読まないので画素数は TIF のタグから補う
    static func metadata(of url: URL) -> (properties: [CFString: Any], xmp: CGImageMetadata?)? {
        guard let file = TIFFFile(url: url), let data = file.build(includePixels: false),
              let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        if props[kCGImagePropertyPixelWidth] == nil, let w = file.width { props[kCGImagePropertyPixelWidth] = w }
        if props[kCGImagePropertyPixelHeight] == nil, let h = file.height { props[kCGImagePropertyPixelHeight] = h }
        return (props, CGImageSourceCopyMetadataAtIndex(src, 0, nil))
    }

    /// この方法で読むべきファイルか（大きな TIF だけ。小さなファイルは通常の方法のほうが速い）
    static func shouldUse(_ url: URL, fileSize: Int64) -> Bool {
        ["tif", "tiff"].contains(url.pathExtension.lowercased()) && fileSize >= ThumbnailLoader.largeFileThreshold
    }
}

/// TIF の 1 枚目の IFD を読み、必要なタグだけで新しい TIF を組み立てる
private struct TIFFFile {
    struct Entry {
        var tag: UInt32
        var type: UInt32
        var count: UInt32
        var raw: Data
    }

    let bigEndian: Bool
    let ifd0: [Entry]
    let exif: [Entry]?
    let gps: [Entry]?
    private let handle: FileHandle

    private static let typeSize: [UInt32: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8]
    /// これより大きな値（Photoshop のレイヤー情報など）は読まない
    private static let maxValueBytes = 16 * 1024 * 1024
    /// 新しい TIF に入れないタグ：レイヤー情報（37724）・Photoshop 情報（34377）・次の画像（330 SubIFDs）など
    private static let droppedTags: Set<UInt32> = [37724, 34377, 330, 34665, 34853, 40965, 273, 279, 324, 325]

    init?(url: URL) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        handle = fh
        guard let header = Self.read(fh, 0, 8) else { return nil }
        switch (header[0], header[1]) {
        case (0x49, 0x49): bigEndian = false
        case (0x4D, 0x4D): bigEndian = true
        default: return nil
        }
        let be = bigEndian
        // 42 以外（BigTIFF の 43 など）は対象外
        guard Self.u16(header, 2, be) == 42 else { return nil }
        guard let ifd0 = Self.readIFD(fh, UInt64(Self.u32(header, 4, be)), be) else { return nil }
        self.ifd0 = ifd0
        func subIFD(_ tag: UInt32) -> [Entry]? {
            guard let e = ifd0.first(where: { $0.tag == tag }), e.raw.count >= 4 else { return nil }
            return Self.readIFD(fh, UInt64(Self.u32(e.raw, 0, be)), be)
        }
        exif = subIFD(34665)
        gps = subIFD(34853)
    }

    // MARK: 読み込み

    /// 指定位置から count バイト読む（足りなければ nil）
    /// pread を使う（FileHandle の新しい API は macOS 10.15 以降で、古い API は読み取りエラーで例外を投げて落ちるため）
    private static func read(_ fh: FileHandle, _ offset: UInt64, _ count: Int) -> Data? {
        guard count >= 0 else { return nil }
        var d = Data(count: count)
        var done = 0
        let ok = d.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Bool in
            while done < count {
                let n = pread(fh.fileDescriptor, buf.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                done += n
            }
            return true
        }
        return ok ? d : nil
    }

    private static func u16(_ d: Data, _ i: Int, _ be: Bool) -> UInt32 {
        let a = UInt32(d[d.startIndex + i]), b = UInt32(d[d.startIndex + i + 1])
        return be ? (a << 8 | b) : (b << 8 | a)
    }

    private static func u32(_ d: Data, _ i: Int, _ be: Bool) -> UInt32 {
        let b = (0..<4).map { UInt32(d[d.startIndex + i + $0]) }
        return be ? (b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]) : (b[3] << 24 | b[2] << 16 | b[1] << 8 | b[0])
    }

    private static func readIFD(_ fh: FileHandle, _ offset: UInt64, _ be: Bool) -> [Entry]? {
        guard let countData = read(fh, offset, 2) else { return nil }
        let n = Int(u16(countData, 0, be))
        guard n > 0, n < 1000, let entries = read(fh, offset + 2, n * 12) else { return nil }
        var result: [Entry] = []
        for i in 0..<n {
            let base = i * 12
            let tag = u16(entries, base, be), type = u16(entries, base + 2, be), count = u32(entries, base + 4, be)
            guard let size = typeSize[type] else { continue }
            let total = size * Int(count)
            if total <= 4 {
                let start = entries.startIndex + base + 8
                result.append(Entry(tag: tag, type: type, count: count, raw: entries.subdata(in: start..<(start + total))))
            } else if total <= maxValueBytes, let raw = read(fh, UInt64(u32(entries, base + 8, be)), total) {
                result.append(Entry(tag: tag, type: type, count: count, raw: raw))
            }
        }
        return result
    }

    var width: Int? { values(256)?.first.map(Int.init) }
    var height: Int? { values(257)?.first.map(Int.init) }

    // MARK: 行を飛び飛びに読む

    /// サムネイルに必要な行だけを読んで縮小画像を作る。条件に合わなければ nil
    /// 条件：無圧縮・チャンネルが並んで格納（PlanarConfiguration 1）・8/16bit・グレーか RGB・ストリップ形式・回転なし
    func subsampledThumbnail(maxPixel: Int) -> CGImage? {
        guard let w = width, let h = height, w > 0, h > 0,
              (values(259)?.first ?? 1) == 1,                 // 無圧縮
              (values(284)?.first ?? 1) == 1,                 // チャンネルが並んで格納
              (values(274)?.first ?? 1) == 1,                 // 回転なし
              !ifd0.contains(where: { $0.tag == 324 }),        // タイル形式ではない
              let photometric = values(262)?.first, [1, 2].contains(photometric),
              let spp = values(277)?.first.map(Int.init) ?? Optional(1), [1, 3, 4].contains(spp),
              let bps = values(258)?.first.map(Int.init), [8, 16].contains(bps),
              let offsets = values(273), !offsets.isEmpty
        else { return nil }
        // 縦方向に何行おきに読むか。元の行数がサムネイルの 4 倍以上あるときだけ使う
        let step = h / max(maxPixel, 1)
        guard step >= 4 else { return nil }
        let rowsPerStrip = Int(values(278)?.first ?? UInt32(h))
        let rowBytes = w * spp * bps / 8
        guard rowsPerStrip > 0, offsets.count * rowsPerStrip >= h else { return nil }

        let rows = Array(stride(from: 0, to: h, by: step))
        var buffer = Data(capacity: rows.count * rowBytes)
        for r in rows {
            let offset = UInt64(offsets[r / rowsPerStrip]) + UInt64((r % rowsPerStrip) * rowBytes)
            guard let d = Self.read(handle, offset, rowBytes) else { return nil }
            buffer.append(d)
        }

        // 読んだ行で、縦だけ縮んだ画像を作る
        let space: CGColorSpace
        if let icc = ifd0.first(where: { $0.tag == 34675 })?.raw, let cs = CGColorSpace(iccData: icc as CFData),
           cs.numberOfComponents == (photometric == 1 ? 1 : 3) {
            space = cs
        } else {
            space = photometric == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        }
        var info: UInt32 = (spp == 4 || (photometric == 1 && spp == 2)) ? CGImageAlphaInfo.last.rawValue
                                                                         : CGImageAlphaInfo.none.rawValue
        if bps == 16 {
            info |= bigEndian ? CGBitmapInfo.byteOrder16Big.rawValue : CGBitmapInfo.byteOrder16Little.rawValue
        }
        guard let provider = CGDataProvider(data: buffer as CFData),
              let squashed = CGImage(width: w, height: rows.count, bitsPerComponent: bps, bitsPerPixel: bps * spp,
                                     bytesPerRow: rowBytes, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                                     provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }

        // 元の縦横比に戻しながら、長辺が maxPixel になるよう縮小する
        let scale = Double(maxPixel) / Double(max(w, h))
        let outW = max(1, Int((Double(w) * scale).rounded())), outH = max(1, Int((Double(h) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(squashed, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage()
    }

    private func values(_ tag: UInt32) -> [UInt32]? {
        guard let e = ifd0.first(where: { $0.tag == tag }) else { return nil }
        switch e.type {
        case 3: return (0..<Int(e.count)).map { Self.u16(e.raw, $0 * 2, bigEndian) }
        case 4: return (0..<Int(e.count)).map { Self.u32(e.raw, $0 * 4, bigEndian) }
        default: return nil
        }
    }

    // MARK: 書き出し

    private func p16(_ v: UInt32) -> Data {
        let x = UInt16(truncatingIfNeeded: v)
        return bigEndian ? Data([UInt8(x >> 8), UInt8(x & 0xFF)]) : Data([UInt8(x & 0xFF), UInt8(x >> 8)])
    }

    private func p32(_ v: UInt32) -> Data {
        bigEndian ? Data([UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
                  : Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)])
    }

    /// IFD とそこからはみ出す値の大きさ
    private func ifdSize(_ entries: [Entry]) -> Int {
        var extra = 0
        for e in entries where e.raw.count > 4 { extra += e.raw.count + (e.raw.count % 2) }
        return 2 + entries.count * 12 + 4 + extra
    }

    /// IFD を base の位置に置いたときのバイト列（はみ出す値は IFD の直後に置く）
    private func serializeIFD(_ entries: [Entry], at base: Int) -> Data {
        let sorted = entries.sorted { $0.tag < $1.tag }
        var head = Data()
        var extra = Data()
        let extraBase = base + 2 + sorted.count * 12 + 4
        head.append(p16(UInt32(sorted.count)))
        for e in sorted {
            head.append(p16(e.tag))
            head.append(p16(e.type))
            head.append(p32(e.count))
            if e.raw.count > 4 {
                head.append(p32(UInt32(extraBase + extra.count)))
                extra.append(e.raw)
                if e.raw.count % 2 == 1 { extra.append(0) }
            } else {
                var inline = e.raw
                while inline.count < 4 { inline.append(0) }
                head.append(inline)
            }
        }
        head.append(p32(0))  // 次の IFD なし
        return head + extra
    }

    private func longEntry(_ tag: UInt32, _ values: [UInt32]) -> Entry {
        Entry(tag: tag, type: 4, count: UInt32(values.count), raw: values.reduce(into: Data()) { $0.append(p32($1)) })
    }

    /// 新しい TIF を組み立てる
    /// - Parameter includePixels: true なら画像データを含める。false なら撮影情報だけ（画像データは 2 バイトのダミー）
    func build(includePixels: Bool) -> Data? {
        let tiled = ifd0.contains { $0.tag == 324 }
        let offsetTag: UInt32 = tiled ? 324 : 273
        let countTag: UInt32 = tiled ? 325 : 279
        guard ifd0.contains(where: { $0.tag == 256 }), ifd0.contains(where: { $0.tag == 257 }) else { return nil }

        // 画像データ（表示用のときだけ読む）
        var pixelData = Data([0, 0])
        var relOffsets: [UInt32] = [0]
        var counts: [UInt32] = [2]
        if includePixels {
            guard let offsets = values(offsetTag), let c = values(countTag), offsets.count == c.count, !offsets.isEmpty
            else { return nil }
            counts = c
            let starts = offsets.map(UInt64.init)
            let minStart = starts.min()!
            let maxEnd = zip(starts, c).map { $0 + UInt64($1) }.max()!
            let total = c.reduce(UInt64(0)) { $0 + UInt64($1) }
            // 1 か所にまとまっていれば一度に読む（HDD では何度も位置を移動するより速い）
            if maxEnd - minStart <= total + total / 5 {
                guard let d = Self.read(handle, minStart, Int(maxEnd - minStart)) else { return nil }
                pixelData = d
                relOffsets = starts.map { UInt32($0 - minStart) }
            } else {
                pixelData = Data(capacity: Int(total))
                relOffsets = []
                for (s, n) in zip(starts, c) {
                    guard let d = Self.read(handle, s, Int(n)) else { return nil }
                    relOffsets.append(UInt32(pixelData.count))
                    pixelData.append(d)
                }
            }
        }

        // IFD0 に残すタグ（画像データの位置・サブ IFD の位置は後で入れ直す）
        var base0 = ifd0.filter { !Self.droppedTags.contains($0.tag) }
        if !includePixels {
            // ダミーの画像データ 1 本にするので、1 ストリップに全行が入る設定にする
            base0.removeAll { [278, 322, 323].contains($0.tag) }
            if let h = values(257)?.first { base0.append(longEntry(278, [h])) }
        }
        // EXIF の中の互換性 IFD（40965）は使わないので外す
        let exifEntries = exif?.filter { $0.tag != 40965 }
        let hasExif = exifEntries != nil, hasGPS = gps != nil
        let pointerTags = (hasExif ? [UInt32(34665)] : []) + (hasGPS ? [UInt32(34853)] : [])
        let dataTags: [UInt32] = includePixels ? [offsetTag, countTag] : [273, 279]
        // 大きさを決めるために、仮の値で IFD0 の大きさを計算する
        let placeholder = base0 + pointerTags.map { longEntry($0, [0]) }
            + dataTags.map { longEntry($0, [UInt32](repeating: 0, count: relOffsets.count)) }
        let ifd0Pos = 8
        let exifPos = ifd0Pos + ifdSize(placeholder)
        let gpsPos = exifPos + (exifEntries.map(ifdSize) ?? 0)
        let pixelPos = gpsPos + (gps.map(ifdSize) ?? 0)

        var final0 = base0
        if hasExif { final0.append(longEntry(34665, [UInt32(exifPos)])) }
        if hasGPS { final0.append(longEntry(34853, [UInt32(gpsPos)])) }
        final0.append(longEntry(dataTags[0], relOffsets.map { $0 + UInt32(pixelPos) }))
        final0.append(longEntry(dataTags[1], counts))

        var result = Data(capacity: pixelPos + pixelData.count)
        result.append(bigEndian ? Data([0x4D, 0x4D]) : Data([0x49, 0x49]))
        result.append(p16(42))
        result.append(p32(UInt32(ifd0Pos)))
        result.append(serializeIFD(final0, at: ifd0Pos))
        if let exifEntries { result.append(serializeIFD(exifEntries, at: exifPos)) }
        if let gps { result.append(serializeIFD(gps, at: gpsPos)) }
        guard result.count == pixelPos else { return nil }
        result.append(pixelData)
        return result
    }
}
