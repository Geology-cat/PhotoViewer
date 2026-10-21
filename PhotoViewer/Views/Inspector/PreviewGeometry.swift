import CoreGraphics

// プレビューの拡大・回転の計算（画面に依存しない。通常版とレガシー版で共有する）

/// プレビューの設定（@AppStorage のキーと選択肢）
enum PreviewSettings {
    /// クリックしたときの拡大率（%）。100% は画像の 1 ピクセルを画面の 1 ピクセルで表示する
    static let zoomPercentKey = "preview.zoomPercent"
    static let zoomPercents = [50, 100, 200, 400]
    static let defaultZoomPercent = 100
}

/// 拡大表示の計算（画面に依存しない部分）
enum ZoomGeometry {
    /// 回転後に枠へ収まる大きさ（回転前の向きでの幅・高さを返す）
    static func fittedSize(_ image: CGSize, rotation: Int, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let quarter = abs(rotation / 90) % 2 == 1
        let w = quarter ? image.height : image.width
        let h = quarter ? image.width : image.height
        let scale = min(box.width / w, box.height / h)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    /// 拡大したときの大きさ。percent は元画像に対する倍率（100 で画像の 1 ピクセル = 画面の 1 ピクセル）
    /// 拡大率どおりだと全体表示とほとんど変わらない（小さな画像など）ときは、全体表示の 2 倍にする
    static func zoomSize(fit: CGSize, originalLongSide: CGFloat, percent: Int, displayScale: CGFloat) -> CGSize {
        let fitLong = max(fit.width, fit.height)
        guard fitLong > 0 else { return fit }
        var long = originalLongSide * CGFloat(percent) / 100 / max(displayScale, 1)
        if long < fitLong * 1.2 { long = fitLong * 2 }
        let k = long / fitLong
        return CGSize(width: fit.width * k, height: fit.height * k)
    }

    /// クリックした場所の画像が、拡大後も同じ画面位置に来るようにするためのずらし量
    static func offsetKeeping(_ point: CGPoint, in box: CGSize, fit: CGSize, zoom: CGSize) -> CGSize {
        let k = max(zoom.width, zoom.height) / max(max(fit.width, fit.height), 1)
        let dx = point.x - box.width / 2, dy = point.y - box.height / 2
        return CGSize(width: dx * (1 - k), height: dy * (1 - k))
    }

    /// 画像が枠の外へ行き過ぎない（端が枠の内側に入り込まない）ように、ずらす量を制限する
    static func clamp(_ o: CGSize, size: CGSize, rotation: Int, in box: CGSize) -> CGSize {
        let quarter = abs(rotation / 90) % 2 == 1
        let w = quarter ? size.height : size.width
        let h = quarter ? size.width : size.height
        let maxX = max(0, (w - box.width) / 2), maxY = max(0, (h - box.height) / 2)
        return CGSize(width: min(max(o.width, -maxX), maxX), height: min(max(o.height, -maxY), maxY))
    }
}
