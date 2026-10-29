import Foundation

/// Finder・Dock から渡された項目を、表示するフォルダと選択画像に変換する。
/// ファイルの種類の確認を伴うため、バックグラウンドから呼ぶ。
struct ExternalOpenRequest: Sendable {
    let folder: URL
    let selection: URL?

    enum OpenError: LocalizedError {
        case unsupported

        var errorDescription: String? {
            "フォルダ、または PhotoViewer が対応している画像・動画ファイルを指定してください。"
        }
    }

    /// 1 つの画面で開くため、複数渡された場合は先頭の対応項目を使う。
    static func resolve(_ urls: [URL]) throws -> ExternalOpenRequest {
        for url in urls where url.isFileURL {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isPackageKey]
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true, values.isPackage != true {
                return ExternalOpenRequest(folder: url.resolvingSymlinksInPath().swiftNative(isDirectory: true), selection: nil)
            }
            if values.isRegularFile == true, SupportedFormats.isSupported(url) {
                // リンクの場合は、リンク先のファイルがあるフォルダを開く。
                let file = url.resolvingSymlinksInPath().swiftNative(isDirectory: false)
                return ExternalOpenRequest(folder: file.deletingLastPathComponent(), selection: file)
            }
        }
        throw OpenError.unsupported
    }
}
