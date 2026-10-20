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
