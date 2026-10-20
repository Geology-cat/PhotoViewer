import Foundation

/// 一覧に表示する 1 ファイル分の情報（フォルダ走査時に取得できる範囲のみ）
struct PhotoItem: Identifiable, Hashable, Sendable {
    let url: URL
    let fileSize: Int64
    let modificationDate: Date
    /// ファイル名（並べ替え・検索で頻繁に使うので最初に一度だけ計算して持つ）
    let name: String
    /// 小文字の拡張子
    let ext: String

    init(url: URL, fileSize: Int64, modificationDate: Date) {
        self.url = url
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.name = url.lastPathComponent
        self.ext = url.pathExtension.lowercased()
    }

    var id: URL { url }
    /// 拡張子を除いたファイル名
    var baseName: String { url.deletingPathExtension().lastPathComponent }
    var isRAW: Bool { SupportedFormats.raw.contains(ext) }
    /// レーティング等を保存する XMP サイドカーの場所（同名の RAW と JPEG で共有）
    var sidecarURL: URL { url.deletingPathExtension().appendingPathExtension("xmp") }
}

/// 対応する拡張子
enum SupportedFormats {
    static let raw: Set<String> = [
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef",
        "dng", "srw", "x3f", "3fr", "iiq", "erf", "mef", "mos", "rwl", "raw",
    ]
    static let standard: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "hif", "png", "tif", "tiff", "gif", "bmp", "webp", "avif", "psd",
    ]
    static let all: Set<String> = raw.union(standard)

    static func isSupported(_ url: URL) -> Bool {
        all.contains(url.pathExtension.lowercased())
    }
}
