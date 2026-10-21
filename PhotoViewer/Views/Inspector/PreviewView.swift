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
                if let image, let url = item?.url, loadedURL == url {
                    let rotation = browser.previewRotation[url] ?? 0
                    let size = Self.fittedSize(image.size, rotation: rotation, in: geo.size)
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .rotationEffect(.degrees(Double(rotation)))
                        .animation(.easeInOut(duration: 0.2), value: rotation)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let quarter = abs(rotation / 90) % 2 == 1
        let w = quarter ? image.height : image.width
        let h = quarter ? image.width : image.height
        let scale = min(box.width / w, box.height / h)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    nonisolated private static func loadPreview(_ url: URL, pixel: Int) async -> CGImage? {
        if Task.isCancelled { return nil }
        return await ThumbnailLoader.shared.load(url, pixelSize: pixel, allowFullDecode: true)
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
