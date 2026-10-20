import AppKit
import SwiftUI

/// 右下：画像情報パネル
struct InfoPanelView: View {
    @Environment(BrowserState.self) private var browser
    let item: PhotoItem?
    @State private var metadata: PhotoMetadata?

    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.name)
                        .font(.headline)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    TagEditor(targets: targets(primary: item))
                    if let m = metadata {
                        shootingSection(m)
                        if let c = m.coordinate {
                            GPSSection(coordinate: c, altitude: m.altitude)
                        } else {
                            SectionBox(title: "位置情報") {
                                Text("位置情報なし").foregroundStyle(.secondary)
                            }
                        }
                        fileSection(item, m)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("情報なし")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
        .task(id: item?.url) {
            metadata = nil
            guard let url = item?.url else { return }
            metadata = await browser.metadata(for: url)
        }
    }

    /// 複数選択中は選択中すべて、そうでなければ表示中の 1 枚が対象
    private func targets(primary: PhotoItem) -> [URL] {
        browser.selection.count > 1 ? browser.selectedURLsInDisplayOrder : [primary.url]
    }

    private func shootingSection(_ m: PhotoMetadata) -> some View {
        SectionBox(title: "撮影情報") {
            InfoRow(label: "撮影日", value: m.captureDate.map { ExifFormat.dateFormatter.string(from: $0) })
            InfoRow(label: "ISO", value: m.iso.map { "\($0)" })
            InfoRow(label: "F値", value: m.fNumber.map(ExifFormat.fNumber))
            InfoRow(label: "シャッター", value: m.exposureTime.map(ExifFormat.exposure))
            InfoRow(label: "焦点距離", value: m.focalLength.map(ExifFormat.focal))
            InfoRow(label: "カメラ", value: m.cameraName)
            InfoRow(label: "レンズ", value: m.lensModel)
        }
    }

    private func fileSection(_ item: PhotoItem, _ m: PhotoMetadata) -> some View {
        SectionBox(title: "ファイル") {
            InfoRow(label: "画素数", value: {
                guard let w = m.pixelWidth, let h = m.pixelHeight else { return nil }
                return "\(w) × \(h)"
            }())
            InfoRow(label: "サイズ", value: ExifFormat.fileSize(item.fileSize))
            InfoRow(label: "更新日", value: ExifFormat.dateFormatter.string(from: item.modificationDate))
            InfoRow(label: "場所", value: item.url.deletingLastPathComponent().path)
        }
    }
}

/// GPS 表示とコピー・地図ボタン
private struct GPSSection: View {
    let coordinate: GPSCoordinate
    let altitude: Double?

    var body: some View {
        SectionBox(title: "位置情報") {
            InfoRow(label: "緯度", value: coordinate.latitudeText)
            InfoRow(label: "経度", value: coordinate.longitudeText)
            if let altitude {
                InfoRow(label: "高度", value: String(format: "%.1f m", altitude))
            }
            HStack(spacing: 6) {
                Menu {
                    Button("緯度, 経度") { copy(coordinate.text) }
                    Button("緯度のみ") { copy(coordinate.latitudeText) }
                    Button("経度のみ") { copy(coordinate.longitudeText) }
                } label: {
                    Label("コピー", systemImage: "doc.on.doc")
                } primaryAction: {
                    copy(coordinate.text)
                }
                .fixedSize()
                .help("緯度・経度をコピー")
                Button {
                    NSWorkspace.shared.open(coordinate.googleMapsURL)
                } label: {
                    Label("Google マップ", systemImage: "map")
                }
                Button {
                    NSWorkspace.shared.open(coordinate.gsiMapsURL())
                } label: {
                    Label("地理院地図", systemImage: "map.fill")
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            Text(value ?? "-")
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

/// レーティング（★）と現像済みチェックの編集
private struct TagEditor: View {
    @Environment(BrowserState.self) private var browser
    let targets: [URL]

    var body: some View {
        let tags = targets.first.map { browser.tags(for: $0) } ?? .empty
        let mixedRating = Set(targets.map { browser.tags(for: $0).rating }).count > 1
        let allDeveloped = targets.allSatisfy { browser.tags(for: $0).developed }
        let anyDeveloped = targets.contains { browser.tags(for: $0).developed }
        let _ = browser.tagsVersion

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { n in
                    Button {
                        // 同じ★をもう一度押すと解除
                        browser.setRating(!mixedRating && tags.rating == n ? 0 : n, for: targets)
                    } label: {
                        Image(systemName: !mixedRating && tags.rating >= n ? "star.fill" : "star")
                            .foregroundStyle(!mixedRating && tags.rating >= n ? .yellow : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("★\(n)（キー \(n)）")
                }
                Button {
                    browser.setRating(tags.rating == -1 ? 0 : -1, for: targets)
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(!mixedRating && tags.rating == -1 ? .red : .secondary)
                }
                .buttonStyle(.borderless)
                .help("リジェクト（⌥⌫）")
                .padding(.leading, 6)
                if mixedRating {
                    Text("（混在）").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .imageScale(.large)

            Toggle(isOn: Binding(
                get: { allDeveloped },
                set: { browser.setDeveloped($0, for: targets) }
            )) {
                Text("現像済み") + Text("（キー D）").font(.caption).foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .overlay(alignment: .leading) {
                // 一部だけ現像済みのとき
                if anyDeveloped && !allDeveloped {
                    Text("−").font(.caption.bold()).offset(x: 3).allowsHitTesting(false)
                }
            }
            if targets.count > 1 {
                Text("\(targets.count) 件にまとめて設定します")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
