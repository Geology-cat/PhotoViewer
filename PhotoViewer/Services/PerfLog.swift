import Foundation
import os

/// 性能計測用のログ（環境変数 PV_PERF=1 のときだけ標準出力にも出す）
@MainActor
enum PerfLog {
    private static let logger = Logger(subsystem: "com.geologycat.PhotoViewer", category: "perf")
    private static let enabled = ProcessInfo.processInfo.environment["PV_PERF"] == "1"
    private static var folderOpenedAt: ContinuousClock.Instant?
    private static var label = ""

    static func folderOpened(_ url: URL) {
        folderOpenedAt = .now
        label = url.lastPathComponent
    }

    static func scanFinished(count: Int) {
        guard let t = folderOpenedAt else { return }
        log("走査完了 \(label): \(count) 件 \(ms(t.duration(to: .now)))")
    }

    /// フォルダを開いてから最初のサムネイルが表示されるまで
    static func firstThumbnailShown() {
        guard let t = folderOpenedAt else { return }
        folderOpenedAt = nil
        log("最初のサムネイル表示 \(label): \(ms(t.duration(to: .now)))")
    }

    static func sidecarsReloaded(changed: Int, removed: Int, total: Int) {
        log("サイドカー読み直し: 変更 \(changed) 件・削除 \(removed) 件（全 \(total) 件）")
    }

    static func metadataLoaded(count: Int, since start: ContinuousClock.Instant) {
        log("撮影情報の一括読み込み: \(count) 件 \(ms(start.duration(to: .now)))")
    }

    private static func ms(_ d: Duration) -> String {
        let c = d.components
        return String(format: "%.0f ms", Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
    }

    private static func log(_ s: String) {
        logger.info("\(s, privacy: .public)")
        if enabled { FileHandle.standardError.write(Data("[perf] \(s)\n".utf8)) }
    }
}
