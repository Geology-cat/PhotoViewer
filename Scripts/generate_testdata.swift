#!/usr/bin/env swift
// テスト用の写真を生成するスクリプト
// 使い方: swift Scripts/generate_testdata.swift <出力先> [大量フォルダの枚数(既定 3000)]
//
// 生成するもの:
//   <出力先>/基本/            EXIF・GPS（北東／南西）・縦位置・EXIF なし・日本語名・同名ペアなど
//   <出力先>/基本/サブフォルダ/ フォルダツリー確認用
//   <出力先>/大量/            性能計測用（既定 3000 枚）

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("使い方: swift Scripts/generate_testdata.swift <出力先> [大量フォルダの枚数]")
    exit(1)
}
let root = URL(fileURLWithPath: args[1])
let largeCount = args.count >= 3 ? Int(args[2]) ?? 3000 : 3000

struct Spec {
    var name: String
    var type: UTType = .jpeg
    var width = 1200
    var height = 800
    var orientation = 1
    var date: String? = "2025:08:15 10:30:00"
    var iso = 200
    var fNumber = 5.6
    var exposure = 1.0 / 250.0
    var focal = 35.0
    var make = "Canon"
    var model = "EOS R5"
    var lens = "RF24-70mm F2.8 L IS USM"
    var gps: (lat: Double, lon: Double)? = nil
    var withExif = true
    var embedThumbnail = true
}

/// 番号と色付きのグラデーション画像を描く
func makeImage(width: Int, height: Int, label: String, hue: CGFloat) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let c1 = NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor
    let c2 = NSColor(hue: fmod(hue + 0.15, 1), saturation: 0.8, brightness: 0.4, alpha: 1).cgColor
    let gradient = CGGradient(colorsSpace: cs, colors: [c1, c2] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])

    // 上向きの矢印（向きの確認用）
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.8).cgColor)
    let cx = CGFloat(width) / 2, top = CGFloat(height) * 0.85, base = CGFloat(height) * 0.6
    ctx.move(to: CGPoint(x: cx, y: top))
    ctx.addLine(to: CGPoint(x: cx - 60, y: base))
    ctx.addLine(to: CGPoint(x: cx + 60, y: base))
    ctx.fillPath()

    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: CGFloat(min(width, height)) / 8),
        .foregroundColor: NSColor.white,
    ]
    let str = NSAttributedString(string: label, attributes: attrs)
    let size = str.size()
    str.draw(at: CGPoint(x: (CGFloat(width) - size.width) / 2, y: CGFloat(height) * 0.3))
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func write(_ spec: Spec, to dir: URL, index: Int) {
    let url = dir.appendingPathComponent(spec.name)
    let image = makeImage(width: spec.width, height: spec.height,
                          label: "\(index) " + (spec.name as NSString).deletingPathExtension,
                          hue: CGFloat(index % 24) / 24)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, spec.type.identifier as CFString, 1, nil) else {
        print("作成失敗: \(url.path)")
        return
    }
    var props: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.8,
        kCGImagePropertyOrientation: spec.orientation,
    ]
    if spec.embedThumbnail {
        props[kCGImageDestinationEmbedThumbnail] = true
    }
    if spec.withExif {
        var exif: [CFString: Any] = [
            kCGImagePropertyExifISOSpeedRatings: [spec.iso],
            kCGImagePropertyExifFNumber: spec.fNumber,
            kCGImagePropertyExifExposureTime: spec.exposure,
            kCGImagePropertyExifFocalLength: spec.focal,
            kCGImagePropertyExifLensModel: spec.lens,
        ]
        if let d = spec.date {
            exif[kCGImagePropertyExifDateTimeOriginal] = d
            exif[kCGImagePropertyExifOffsetTimeOriginal] = "+09:00"
        }
        props[kCGImagePropertyExifDictionary] = exif
        props[kCGImagePropertyTIFFDictionary] = [
            kCGImagePropertyTIFFMake: spec.make,
            kCGImagePropertyTIFFModel: spec.model,
        ]
        if let g = spec.gps {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(g.lat),
                kCGImagePropertyGPSLatitudeRef: g.lat >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(g.lon),
                kCGImagePropertyGPSLongitudeRef: g.lon >= 0 ? "E" : "W",
                kCGImagePropertyGPSAltitude: 40.0,
            ]
        }
    }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    if !CGImageDestinationFinalize(dest) {
        print("書き込み失敗: \(url.path)")
    }
}

let fm = FileManager.default
let basic = root.appendingPathComponent("基本")
let sub = basic.appendingPathComponent("サブフォルダ")
let large = root.appendingPathComponent("大量")
for d in [basic, sub, large] {
    try? fm.createDirectory(at: d, withIntermediateDirectories: true)
}

// --- 基本セット ---
let basicSpecs: [Spec] = [
    Spec(name: "IMG_0001.JPG", gps: (35.681236, 139.767125)),                       // 東京駅（北緯・東経）
    Spec(name: "IMG_0002.JPG", iso: 3200, fNumber: 1.8, exposure: 1.0 / 30, gps: (-33.856784, 151.215297)), // シドニー（南緯）
    Spec(name: "IMG_0003.JPG", exposure: 2.0, gps: (40.689247, -74.044502)),         // NY（西経）
    Spec(name: "IMG_0004.JPG", exposure: 1.0 / 8000, gps: (-22.951916, -43.210487)), // リオ（南緯・西経）
    Spec(name: "IMG_0005.JPG", width: 800, height: 1200, orientation: 1),           // 縦長の画像
    Spec(name: "IMG_0006.JPG", orientation: 6),                                     // 縦位置（回転タグ）
    Spec(name: "IMG_0007.JPG", withExif: false, embedThumbnail: false),             // EXIF なし
    Spec(name: "富士山_夕景.JPG", date: "2024:01:02 16:45:10", make: "FUJIFILM", model: "X-T5",
         lens: "XF16-55mmF2.8 R LM WR", gps: (35.360556, 138.727778)),              // 日本語ファイル名
    Spec(name: "DSC_1000.JPG", make: "NIKON CORPORATION", model: "Z 8", lens: "NIKKOR Z 24-120mm f/4 S"),
    Spec(name: "DSC_1000.HEIC", type: .heic, make: "NIKON CORPORATION", model: "Z 8",
         lens: "NIKKOR Z 24-120mm f/4 S"),                                          // 同名ペア
    Spec(name: "screenshot.png", type: .png, withExif: false, embedThumbnail: false),
    Spec(name: "scan.tif", type: .tiff, withExif: false, embedThumbnail: false),
]
for (i, s) in basicSpecs.enumerated() {
    write(s, to: basic, index: i + 1)
}
// ファイル内の XMP に★3 を持つ JPEG（カメラや Lightroom が書いた★の再現）
do {
    let url = basic.appendingPathComponent("EMBED_RATING3.JPG")
    let image = makeImage(width: 1200, height: 800, label: "★3 内蔵", hue: 0.1)
    let meta = CGImageMetadataCreateMutable()
    _ = CGImageMetadataRegisterNamespaceForPrefix(meta, "http://ns.adobe.com/xap/1.0/" as CFString, "xmp" as CFString, nil)
    _ = CGImageMetadataSetValueWithPath(meta, nil, "xmp:Rating" as CFString, "3" as CFString)
    if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
        CGImageDestinationAddImageAndMetadata(dest, image, meta, nil)
        _ = CGImageDestinationFinalize(dest)
    }
}
for i in 1...5 {
    write(Spec(name: String(format: "SUB_%04d.JPG", i), date: "2023:05:0\(i) 09:00:00", make: "SONY",
               model: "ILCE-7RM5", lens: "FE 24-70mm F2.8 GM II"), to: sub, index: i)
}

// --- 大量セット ---
let cameras = [("Canon", "EOS R5", "RF24-70mm F2.8 L IS USM"),
               ("SONY", "ILCE-7RM5", "FE 24-70mm F2.8 GM II"),
               ("FUJIFILM", "X-T5", "XF16-55mmF2.8 R LM WR")]
let isos = [100, 200, 400, 800, 1600, 3200, 6400]
let fs = [1.4, 2.0, 2.8, 4.0, 5.6, 8.0, 11.0]
let ss = [1.0 / 4000, 1.0 / 1000, 1.0 / 250, 1.0 / 60, 1.0 / 15, 0.5, 2.0]
for i in 1...largeCount {
    let cam = cameras[i % cameras.count]
    let day = (i / 100) % 28 + 1
    let spec = Spec(name: String(format: "L_%05d.JPG", i), width: 1600, height: 1067,
                    orientation: i % 10 == 0 ? 6 : 1,
                    date: String(format: "2025:09:%02d %02d:%02d:00", day, (i / 60) % 24, i % 60),
                    iso: isos[i % isos.count], fNumber: fs[i % fs.count], exposure: ss[i % ss.count],
                    focal: Double(24 + i % 47), make: cam.0, model: cam.1, lens: cam.2,
                    gps: i % 3 == 0 ? (35.0 + Double(i % 100) / 100, 139.0 + Double(i % 50) / 100) : nil,
                    embedThumbnail: i % 2 == 0)
    write(spec, to: large, index: i)
    if i % 500 == 0 { print("大量: \(i)/\(largeCount)") }
}
print("完了: \(root.path)")
