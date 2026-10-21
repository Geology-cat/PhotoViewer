import AVKit
import AppKit
import SwiftUI

/// 右上：選択中の画像のプレビュー
struct PreviewView: View {
    @Environment(BrowserState.self) private var browser
    let item: PhotoItem?
    let selectionCount: Int
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var loadedURL: URL?
    @State private var isLoading = false

    var body: some View {
        if let item, item.isVideo {
            // 動画はその場で再生できるようにする（自動では再生しない）
            VideoPreview(url: item.url)
                .id(item.url)
                .padding(8)
                .background(Color(nsColor: .underPageBackgroundColor))
        } else {
            imagePreview
        }
    }

    private var imagePreview: some View {
        GeometryReader { geo in
            let pixel = ThumbnailLoader.bucket(for: Int(max(geo.size.width, geo.size.height) * displayScale))
            ZStack {
                if let image, let item, loadedURL == item.url {
                    // 別の写真に変わったら拡大を解除する
                    ZoomableImage(item: item, image: image, rotation: browser.previewRotation[item.url] ?? 0, box: geo.size)
                        .id(item.url)
                } else if item == nil {
                    Text(selectionCount > 1 ? "\(selectionCount) 件を選択中" : "画像を選択してください")
                        .foregroundStyle(.secondary)
                }
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if let url = item?.url {
                    RotateButtons(url: url)
                }
            }
            .task(id: PreviewKey(url: item?.url, pixel: pixel)) {
                await load(url: item?.url, pixel: pixel, fileSize: item?.fileSize ?? 0)
            }
        }
        .padding(8)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func load(url: URL?, pixel: Int, fileSize: Int64) async {
        guard let url else {
            image = nil
            loadedURL = nil
            return
        }
        if let hit = ThumbnailLoader.shared.cached(url, pixelSize: pixel) {
            image = NSImage(cgImage: hit, size: .zero)
            loadedURL = url
            return
        }
        // 先にグリッド用の小さいサムネイルがあれば仮表示する
        if loadedURL != url, let small = ThumbnailLoader.shared.cached(url, pixelSize: 512)
            ?? ThumbnailLoader.shared.cached(url, pixelSize: 256) {
            image = NSImage(cgImage: small, size: .zero)
            loadedURL = url
        }
        isLoading = true
        defer { isLoading = false }
        // 大きな TIF などは高画質の読み込みに数秒かかるので、先に中くらいの画像（素早く作れる）を出す
        if fileSize >= ThumbnailLoader.largeFileThreshold, pixel > 768,
           ThumbnailLoader.shared.cached(url, pixelSize: pixel) == nil {
            if let medium = await Self.loadPreview(url, pixel: 768), !Task.isCancelled {
                image = NSImage(cgImage: medium, size: .zero)
                loadedURL = url
            }
        }
        let cg = await Self.loadPreview(url, pixel: pixel)
        guard !Task.isCancelled, let cg else { return }
        image = NSImage(cgImage: cg, size: .zero)
        loadedURL = url
    }

    /// 回転後に枠へ収まる大きさ（回転前の向きでの幅・高さを返す）
    static func fittedSize(_ image: CGSize, rotation: Int, in box: CGSize) -> CGSize {
        ZoomGeometry.fittedSize(image, rotation: rotation, in: box)
    }

    nonisolated private static func loadPreview(_ url: URL, pixel: Int) async -> CGImage? {
        if Task.isCancelled { return nil }
        return await ThumbnailLoader.shared.load(url, pixelSize: pixel, allowFullDecode: true)
    }
}

/// クリックで拡大し、拡大中はドラッグで動かせる画像
/// - クリック：その場所を中心に拡大（拡大率は環境設定）。拡大中にクリックすると全体表示に戻る
/// - ドラッグ：拡大中の画像を動かす
private struct ZoomableImage: View {
    @Environment(BrowserState.self) private var browser
    @Environment(\.displayScale) private var displayScale
    @AppStorage(PreviewSettings.zoomPercentKey) private var zoomPercent = PreviewSettings.defaultZoomPercent
    let item: PhotoItem
    /// 枠に合わせて読み込んだ画像
    let image: NSImage
    let rotation: Int
    let box: CGSize

    @State private var zoomed = false
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var isDragging = false
    /// 元の画像の長辺のピクセル数（撮影情報から。分かるまでは読み込んだ画像の大きさを使う）
    @State private var originalLongSide: CGFloat?
    /// 拡大用に読み直した高解像度の画像
    @State private var detail: NSImage?
    @State private var detailTask: Task<Void, Never>?

    private var fitSize: CGSize { PreviewView.fittedSize(image.size, rotation: rotation, in: box) }

    /// 拡大したときの大きさ（回転前の向き、ポイント）
    private var zoomSize: CGSize {
        ZoomGeometry.zoomSize(fit: fitSize, originalLongSide: originalLongSide ?? max(image.size.width, image.size.height),
                              percent: zoomPercent, displayScale: displayScale)
    }

    private var displaySize: CGSize { zoomed ? zoomSize : fitSize }

    var body: some View {
        let size = displaySize
        Image(nsImage: detail ?? image)
            .resizable()
            .interpolation(.high)
            .frame(width: size.width, height: size.height)
            .rotationEffect(.degrees(Double(rotation)))
            .offset(offset)
            .frame(width: box.width, height: box.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragOrClick)
            .pointerStyle(zoomed ? (isDragging ? .grabActive : .grabIdle) : .zoomIn)
            .animation(.easeInOut(duration: 0.2), value: rotation)
            .help(zoomed ? "ドラッグで移動、クリックで全体表示に戻る" : "クリックで拡大（\(zoomPercent)%）")
            .task { await loadOriginalSize() }
            .onChange(of: rotation) {
                withAnimation(.easeOut(duration: 0.15)) { zoomed = false; offset = .zero }
            }
            .onChange(of: box) { offset = clamped(offset) }
            .onDisappear { detailTask?.cancel() }
    }

    /// クリック（ほとんど動かさずに離した）とドラッグを 1 つのジェスチャで見分ける
    private var dragOrClick: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard zoomed else { return }
                if dragStart == nil { dragStart = offset }
                if hypot(value.translation.width, value.translation.height) > 3 { isDragging = true }
                guard isDragging, let start = dragStart else { return }
                offset = clamped(CGSize(width: start.width + value.translation.width,
                                        height: start.height + value.translation.height))
            }
            .onEnded { value in
                let wasDragging = isDragging
                dragStart = nil
                isDragging = false
                if !wasDragging { toggleZoom(at: value.location) }
            }
    }

    private func toggleZoom(at point: CGPoint) {
        if zoomed {
            withAnimation(.easeOut(duration: 0.15)) { zoomed = false; offset = .zero }
            return
        }
        let target = ZoomGeometry.offsetKeeping(point, in: box, fit: fitSize, zoom: zoomSize)
        withAnimation(.easeOut(duration: 0.15)) {
            zoomed = true
            offset = clamped(target)
        }
        loadDetailIfNeeded()
    }

    /// 画像が枠の外へ行き過ぎないように、ずらす量を制限する
    private func clamped(_ o: CGSize) -> CGSize {
        ZoomGeometry.clamp(o, size: displaySize, rotation: rotation, in: box)
    }

    private func loadOriginalSize() async {
        let m = await browser.metadata(for: item.url)
        if let w = m.pixelWidth, let h = m.pixelHeight, w > 0, h > 0 {
            originalLongSide = CGFloat(max(w, h))
        }
    }

    /// 拡大に足りない解像度なら、必要な大きさで読み直す（バックグラウンド）
    private func loadDetailIfNeeded() {
        let needed = Int(max(zoomSize.width, zoomSize.height) * max(displayScale, 1))
        let original = Int(originalLongSide ?? 0)
        let target = min(original > 0 ? min(needed, original) : needed, 16384)
        let current = Int(max(image.size.width, image.size.height))
        guard detail == nil, detailTask == nil, target > current + current / 20 else { return }
        let url = item.url
        detailTask = Task {
            let cg = await Task.detached(priority: .userInitiated) {
                ThumbnailLoader.makeImage(url: url, maxPixel: target, allowFullDecode: true)
            }.value
            guard !Task.isCancelled, let cg else { return }
            detail = NSImage(cgImage: cg, size: .zero)
        }
    }
}

private struct PreviewKey: Hashable {
    var url: URL?
    var pixel: Int
}

/// プレビュー右下の「左に 90° 回転」「右に 90° 回転」ボタン
private struct RotateButtons: View {
    @Environment(BrowserState.self) private var browser
    let url: URL

    var body: some View {
        HStack(spacing: 2) {
            Button {
                browser.rotatePreview(url, by: -90)
            } label: {
                Image(systemName: "rotate.left").frame(width: 24, height: 20)
            }
            .help("左に 90° 回転（⌥⌘←）")
            Button {
                browser.rotatePreview(url, by: 90)
            } label: {
                Image(systemName: "rotate.right").frame(width: 24, height: 20)
            }
            .help("右に 90° 回転（⌥⌘→）")
        }
        .buttonStyle(.borderless)
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .padding(6)
    }
}

/// 動画のプレビュー（再生・一時停止・コマ送りなどは AVKit の標準の操作）
/// SwiftUI の VideoPlayer は環境によって起動時に異常終了したため、AppKit の AVPlayerView を直接使う
private struct VideoPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        // 別の動画に変わったら差し替える（同じなら何もしない）
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player?.pause()
            view.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        // 別の写真を選んだら止める
        view.player?.pause()
        view.player = nil
    }
}
