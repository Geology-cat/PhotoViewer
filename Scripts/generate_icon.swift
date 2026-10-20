// アプリアイコンの生成：swift Scripts/generate_icon.swift icon_1024.png のあと sips で各サイズに縮小して AppIcon.appiconset に入れる
import AppKit
// アプリアイコン（1024px）を描く：青緑のグラデーションに写真と★
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(path); ctx.clip()
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let g = CGGradient(colorsSpace: cs, colors: [NSColor(red: 0.13, green: 0.36, blue: 0.62, alpha: 1).cgColor,
                                             NSColor(red: 0.10, green: 0.62, blue: 0.62, alpha: 1).cgColor] as CFArray,
                   locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
// 写真の枠
let photo = CGRect(x: 230, y: 300, width: 564, height: 420)
ctx.setFillColor(NSColor.white.cgColor)
ctx.addPath(CGPath(roundedRect: photo, cornerWidth: 36, cornerHeight: 36, transform: nil)); ctx.fillPath()
let inner = photo.insetBy(dx: 30, dy: 30)
ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 14, cornerHeight: 14, transform: nil)); ctx.clip()
let sky = CGGradient(colorsSpace: cs, colors: [NSColor(red: 0.98, green: 0.78, blue: 0.45, alpha: 1).cgColor,
                                               NSColor(red: 0.95, green: 0.50, blue: 0.40, alpha: 1).cgColor] as CFArray,
                     locations: [0, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: inner.maxY), end: CGPoint(x: 0, y: inner.minY), options: [])
// 山
ctx.setFillColor(NSColor(red: 0.20, green: 0.30, blue: 0.45, alpha: 1).cgColor)
ctx.move(to: CGPoint(x: inner.minX, y: inner.minY)); ctx.addLine(to: CGPoint(x: inner.minX + 170, y: inner.minY + 220))
ctx.addLine(to: CGPoint(x: inner.minX + 280, y: inner.minY + 120)); ctx.addLine(to: CGPoint(x: inner.minX + 380, y: inner.minY + 260))
ctx.addLine(to: CGPoint(x: inner.maxX, y: inner.minY)); ctx.fillPath()
ctx.resetClip()
// ★
let star = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)!
    .withSymbolConfiguration(.init(pointSize: 230, weight: .bold).applying(.init(paletteColors: [NSColor(red: 1, green: 0.84, blue: 0.2, alpha: 1)])))!
star.draw(in: CGRect(x: 610, y: 170, width: 250, height: 240))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
