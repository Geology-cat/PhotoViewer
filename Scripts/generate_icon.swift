// アプリアイコンの生成
// 使い方: swift Scripts/generate_icon.swift docs/icon_source.png PhotoViewer/Resources/Assets.xcassets/AppIcon.appiconset
// 元画像（Codex で生成した正方形いっぱいの絵）を、macOS アイコンの形（1024 の中に 824 の角丸四角＋影）に整え、各サイズを書き出す
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let source = NSImage(contentsOfFile: args[1]) else {
    print("使い方: swift Scripts/generate_icon.swift <元画像> <AppIcon.appiconset>")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[2])

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // Apple のテンプレートに合わせる：1024 のうち 824 を本体、角の半径は約 185
    let body = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let radius = s * 185 / 1024
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    // 影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 20 / 1024,
                  color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    // 本体（元画像を角丸で切り抜く）
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    var rect = CGRect(origin: .zero, size: source.size)
    let cg = source.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
    ctx.draw(cg, in: body)
    ctx.restoreGState()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base).png" : "icon_\(base)@2x.png"
        try! render(size: base * scale).write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(base)x\(base)", "filename": name])
    }
}
let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("Contents.json"))
print("書き出し完了: \(outDir.path)")
