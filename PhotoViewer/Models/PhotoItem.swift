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
    /// 検索用の小文字のファイル名
    let lowerName: String
    /// 拡張子を除いたパス（小文字）。同名の RAW と JPEG で共有するサイドカーを探すのに使う
    let sidecarKey: String
    /// レーティング等を保存する XMP サイドカーの既定の場所（同名の RAW と JPEG で共有）
    let sidecarURL: URL

    /// よく使う値はここで一度だけ求める（フォルダの走査はバックグラウンドで行うので、画面の操作を止めない）
    init(url: URL, fileSize: Int64, modificationDate: Date) {
        let url = url.swiftNative(isDirectory: false)
        self.url = url
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.name = url.lastPathComponent
        self.ext = url.pathExtension.lowercased()
        self.lowerName = name.lowercased()
        let base = url.deletingPathExtension()
        self.sidecarKey = base.path.lowercased()
        self.sidecarURL = base.appendingPathExtension("xmp")
    }

    var id: URL { url }
    /// 拡張子を除いたファイル名
    var baseName: String { url.deletingPathExtension().lastPathComponent }
    var isRAW: Bool { SupportedFormats.raw.contains(ext) }
    var isVideo: Bool { SupportedFormats.video.contains(ext) }

    /// 「種類」で並べ替えるときの順位（RAW → JPEG → HEIC → TIF → PNG → その他の画像 → 動画）
    var kindRank: Int {
        if isRAW { return 0 }
        switch ext {
        case "jpg", "jpeg": return 1
        case "heic", "heif", "hif": return 2
        case "tif", "tiff": return 3
        case "png": return 4
        default: return isVideo ? 6 : 5
        }
    }
}

/// 対応する拡張子
extension URL {
    /// Swift 側で作り直した同じ URL
    /// フォルダの列挙で得た URL は中身が NSURL のままで、辞書のキーにしたり比べたりするたびに文字列の変換が走る。
    /// 日本語を含むパスでは数千件の辞書を作るだけで数十 ms かかり、並べ替えのたびに画面が一瞬止まる原因になっていた
    func swiftNative(isDirectory: Bool) -> URL {
        URL(fileURLWithPath: String(decoding: Array(path.utf8), as: UTF8.self), isDirectory: isDirectory)
    }
}

enum SupportedFormats {
    static let raw: Set<String> = [
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef",
        "dng", "srw", "x3f", "3fr", "iiq", "erf", "mef", "mos", "rwl", "raw",
    ]
    static let standard: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "hif", "png", "tif", "tiff", "gif", "bmp", "webp", "avif", "psd",
    ]
    /// 動画（AVFoundation で再生できる形式）
    static let video: Set<String> = ["mov", "mp4", "m4v", "mts", "m2ts", "3gp"]
    static let all: Set<String> = raw.union(standard).union(video)

    static func isVideo(_ url: URL) -> Bool {
        video.contains(url.pathExtension.lowercased())
    }

    static func isSupported(_ url: URL) -> Bool {
        all.contains(url.pathExtension.lowercased())
    }
}
