import AppKit
import SwiftUI

/// 右上：選択中の画像のプレビュー
struct PreviewView: View {
    let item: PhotoItem?
    let selectionCount: Int
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var loadedURL: URL?
    @State private var isLoading = false

    var body: some View {
        GeometryReader { geo in
            let pixel = ThumbnailLoader.bucket(for: Int(max(geo.size.width, geo.size.height) * displayScale))
            ZStack {
                if let image, loadedURL == item?.url {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
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
            .task(id: PreviewKey(url: item?.url, pixel: pixel)) {
                await load(url: item?.url, pixel: pixel)
            }
        }
        .padding(8)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func load(url: URL?, pixel: Int) async {
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
        let cg = await Self.loadPreview(url, pixel: pixel)
        guard !Task.isCancelled, let cg else { return }
        image = NSImage(cgImage: cg, size: .zero)
        loadedURL = url
    }

    nonisolated private static func loadPreview(_ url: URL, pixel: Int) async -> CGImage? {
        if Task.isCancelled { return nil }
        return ThumbnailLoader.shared.load(url, pixelSize: pixel, allowFullDecode: true)
    }
}

private struct PreviewKey: Hashable {
    var url: URL?
    var pixel: Int
}
