import AppKit

/// ボタン・バッジのアイコン（10.12 では SF Symbols が使えないため、コードで描く）
/// テンプレート画像（isTemplate）は、ボタンの状態に合わせて OS が色を付ける
enum LegacyIcons {
    /// 描画で画像を作る
    static func make(_ size: CGFloat = 16, template: Bool = true, _ draw: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(rect)
            return true
        }
        image.isTemplate = template
        return image
    }

    private static func stroke(_ path: NSBezierPath, _ width: CGFloat = 1.4, color: NSColor = .black) {
        color.setStroke()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    // MARK: ツールバー

    /// サイドバーの開閉（left = 左側の帯）
    static func sidebar(left: Bool) -> NSImage {
        make(18) { r in
            let box = r.insetBy(dx: 1.5, dy: 3)
            stroke(NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5))
            let x = left ? box.minX + box.width * 0.33 : box.maxX - box.width * 0.33
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: box.minY))
            line.line(to: NSPoint(x: x, y: box.maxY))
            stroke(line)
            // 帯の中の短い線
            for i in 0..<3 {
                let y = box.maxY - 3 - CGFloat(i) * 2.6
                let l = NSBezierPath()
                let x0 = left ? box.minX + 2 : x + 2
                l.move(to: NSPoint(x: x0, y: y))
                l.line(to: NSPoint(x: x0 + box.width * 0.33 - 4, y: y))
                stroke(l, 1)
            }
        }
    }

    /// 絞り込み（下ほど短い 3 本線を丸で囲む）
    static func filter(active: Bool) -> NSImage {
        make(18) { r in
            let circle = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
            if active {
                NSColor.black.setFill()
                circle.fill()
            } else {
                stroke(circle)
            }
            let c = NSPoint(x: r.midX, y: r.midY)
            for (i, w) in [9.0, 6.0, 3.0].enumerated() {
                let y = c.y + 3 - CGFloat(i) * 3
                let l = NSBezierPath()
                l.move(to: NSPoint(x: c.x - CGFloat(w) / 2, y: y))
                l.line(to: NSPoint(x: c.x + CGFloat(w) / 2, y: y))
                if active {
                    NSGraphicsContext.current?.compositingOperation = .destinationOut
                }
                stroke(l, 1.4)
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
        }
    }

    /// 並べ替え（上下の矢印）
    static var sort: NSImage {
        make(18) { r in
            for (x, up) in [(r.minX + 5.5, true), (r.maxX - 5.5, false)] {
                let p = NSBezierPath()
                p.move(to: NSPoint(x: x, y: r.minY + 2.5))
                p.line(to: NSPoint(x: x, y: r.maxY - 2.5))
                let tip = up ? r.maxY - 2.5 : r.minY + 2.5
                let d: CGFloat = up ? -3.5 : 3.5
                p.move(to: NSPoint(x: x - 3, y: tip + d))
                p.line(to: NSPoint(x: x, y: tip))
                p.line(to: NSPoint(x: x + 3, y: tip + d))
                stroke(p)
            }
        }
    }

    /// ファイル名の表示（「Aa」）
    static var fileName: NSImage {
        make(18) { r in
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                        .foregroundColor: NSColor.black]
            let s = NSAttributedString(string: "Aa", attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
        }
    }

    /// 写真（サイズのスライダーの両端）
    static func photo(_ size: CGFloat) -> NSImage {
        make(size) { r in
            let box = r.insetBy(dx: 1, dy: r.height * 0.18)
            stroke(NSBezierPath(roundedRect: box, xRadius: 1.5, yRadius: 1.5), 1)
            let m = NSBezierPath()
            m.move(to: NSPoint(x: box.minX + 1, y: box.minY + 1))
            m.line(to: NSPoint(x: box.minX + box.width * 0.4, y: box.midY))
            m.line(to: NSPoint(x: box.minX + box.width * 0.6, y: box.minY + box.height * 0.3))
            m.line(to: NSPoint(x: box.maxX - 1, y: box.midY + 1))
            stroke(m, 1)
        }
    }

    // MARK: サイドバー

    /// 上の階層へ（左上へ曲がる矢印）
    static var goUp: NSImage {
        make(16) { r in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.maxX - 3, y: r.minY + 2))
            p.line(to: NSPoint(x: r.maxX - 3, y: r.midY + 1))
            p.line(to: NSPoint(x: r.minX + 4, y: r.midY + 1))
            p.move(to: NSPoint(x: r.minX + 7.5, y: r.midY + 4.5))
            p.line(to: NSPoint(x: r.minX + 4, y: r.midY + 1))
            p.line(to: NSPoint(x: r.minX + 7.5, y: r.midY - 2.5))
            stroke(p)
        }
    }

    /// 一覧に戻る（星）
    static var favorites: NSImage {
        make(16) { r in starPath(in: r.insetBy(dx: 1, dy: 1)).fill() }
    }

    /// ドライブ（種類ごとに色を付ける。テンプレートではない）
    static func drive(_ kind: VolumeKind, size: CGFloat = 16) -> NSImage {
        make(size, template: false) { r in
            let color: NSColor
            switch kind {
            case .internal: color = .secondaryLabelColor
            case .external: color = .systemOrange
            case .diskImage: color = .systemGray
            case .network: color = NSColor(calibratedRed: 0.2, green: 0.6, blue: 0.7, alpha: 1)
            }
            if kind == .network {
                let g = NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2))
                stroke(g, 1.3, color: color)
                let l = NSBezierPath()
                l.move(to: NSPoint(x: r.minX + 2, y: r.midY)); l.line(to: NSPoint(x: r.maxX - 2, y: r.midY))
                l.move(to: NSPoint(x: r.midX, y: r.minY + 2)); l.line(to: NSPoint(x: r.midX, y: r.maxY - 2))
                stroke(l, 1, color: color)
                return
            }
            let body = NSRect(x: r.minX + 1.5, y: r.minY + r.height * 0.28, width: r.width - 3, height: r.height * 0.44)
            let path = NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2)
            if kind == .external {
                color.setFill()
                path.fill()
                NSColor.white.setFill()
            } else {
                stroke(path, 1.3, color: color)
                color.setFill()
            }
            NSBezierPath(ovalIn: NSRect(x: body.maxX - 4.5, y: body.midY - 1.2, width: 2.4, height: 2.4)).fill()
        }
    }

    /// 取り出し
    static var eject: NSImage {
        make(12) { r in
            let t = NSBezierPath()
            t.move(to: NSPoint(x: r.minX + 1.5, y: r.midY - 0.5))
            t.line(to: NSPoint(x: r.maxX - 1.5, y: r.midY - 0.5))
            t.line(to: NSPoint(x: r.midX, y: r.maxY - 1))
            t.close()
            NSColor.black.setFill()
            t.fill()
            NSBezierPath(rect: NSRect(x: r.minX + 1.5, y: r.minY + 1.5, width: r.width - 3, height: 1.8)).fill()
        }
    }

    // MARK: プレビュー・情報

    /// 90° 回転（clockwise = 右回り）
    static func rotate(clockwise: Bool) -> NSImage {
        make(16) { r in
            let c = NSPoint(x: r.midX, y: r.midY - 0.5)
            let arc = NSBezierPath()
            if clockwise {
                arc.appendArc(withCenter: c, radius: 5.5, startAngle: 160, endAngle: -60, clockwise: true)
            } else {
                arc.appendArc(withCenter: c, radius: 5.5, startAngle: 20, endAngle: 240, clockwise: false)
            }
            stroke(arc)
            // 矢印の先
            let startAngle: CGFloat = clockwise ? 160 : 20
            let a = startAngle * .pi / 180
            let tip = NSPoint(x: c.x + 5.5 * cos(a), y: c.y + 5.5 * sin(a))
            let head = NSBezierPath()
            let s: CGFloat = clockwise ? 1 : -1
            head.move(to: NSPoint(x: tip.x - 3 * s, y: tip.y + 1.5))
            head.line(to: tip)
            head.line(to: NSPoint(x: tip.x + 1.5 * s, y: tip.y + 3.5))
            stroke(head)
        }
    }

    /// 星の形
    static func starPath(in r: NSRect) -> NSBezierPath {
        let p = NSBezierPath()
        let c = NSPoint(x: r.midX, y: r.midY - r.height * 0.04)
        let outer = min(r.width, r.height) / 2, inner = outer * 0.42
        for i in 0..<10 {
            let rad = i % 2 == 0 ? outer : inner
            let a = (90 + CGFloat(i) * 36) * .pi / 180
            let pt = NSPoint(x: c.x + rad * cos(a), y: c.y + rad * sin(a))
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        p.close()
        return p
    }

    /// ★（filled = 塗りつぶし）。色付き
    static func star(filled: Bool, color: NSColor, size: CGFloat = 18) -> NSImage {
        make(size, template: false) { r in
            let p = starPath(in: r.insetBy(dx: 1.5, dy: 1.5))
            if filled {
                color.setFill()
                p.fill()
            } else {
                stroke(p, 1.1, color: color)
            }
        }
    }

    /// リジェクト（丸に ×）。色付き
    static func reject(color: NSColor, size: CGFloat = 18) -> NSImage {
        make(size, template: false) { r in
            let b = r.insetBy(dx: 2, dy: 2)
            stroke(NSBezierPath(ovalIn: b), 1.3, color: color)
            let x = NSBezierPath()
            let d = b.width * 0.22
            x.move(to: NSPoint(x: b.midX - d, y: b.midY - d)); x.line(to: NSPoint(x: b.midX + d, y: b.midY + d))
            x.move(to: NSPoint(x: b.midX - d, y: b.midY + d)); x.line(to: NSPoint(x: b.midX + d, y: b.midY - d))
            stroke(x, 1.3, color: color)
        }
    }

    // MARK: グリッドのバッジ

    /// 現像済み（緑の丸に白いチェック）
    static var developedBadge: NSImage {
        make(18, template: false) { r in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).fill()
            let c = NSBezierPath()
            c.move(to: NSPoint(x: r.minX + 5.5, y: r.midY))
            c.line(to: NSPoint(x: r.minX + 8, y: r.midY - 2.8))
            c.line(to: NSPoint(x: r.maxX - 5, y: r.midY + 3))
            stroke(c, 2, color: .white)
        }
    }

    /// 動画（半透明の黒い丸に白い三角）
    static var videoBadge: NSImage {
        make(22, template: false) { r in
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            let t = NSBezierPath()
            t.move(to: NSPoint(x: r.midX - 3, y: r.midY - 4.5))
            t.line(to: NSPoint(x: r.midX - 3, y: r.midY + 4.5))
            t.line(to: NSPoint(x: r.midX + 5, y: r.midY))
            t.close()
            NSColor.white.setFill()
            t.fill()
        }
    }

    /// フォルダ・ボリュームの汎用アイコン（ディスクに触らない）
    static var folder: NSImage { NSImage(named: NSImage.folderName) ?? NSImage() }
}
