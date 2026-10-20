import Foundation

/// フォルダ内の写真ファイルとサブフォルダを列挙する
enum FolderScanner {
    private static let fileKeys: [URLResourceKey] = [
        .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
    ]

    struct ScanResult: Sendable {
        var items: [PhotoItem]
        /// 拡張子を除いたパス（小文字）→ 実在するサイドカーの URL
        var sidecars: [String: URL]
        /// サイドカーの更新日（変わったものだけ読み直すため）
        var sidecarDates: [URL: Date]
    }

    static func sidecarKey(_ url: URL) -> String {
        url.deletingPathExtension().path.lowercased()
    }

    /// 写真とサイドカー（.xmp）を列挙する
    static func scan(_ folder: URL, recursive: Bool = false) -> ScanResult {
        var sidecars: [String: URL] = [:]
        var dates: [URL: Date] = [:]
        let items = scanPhotos(in: folder, recursive: recursive) { u in
            if u.pathExtension.lowercased() == "xmp" {
                sidecars[sidecarKey(u)] = u
                dates[u] = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
            }
        }
        return ScanResult(items: items, sidecars: sidecars, sidecarDates: dates)
    }

    /// フォルダ直下（recursive なら配下すべて）の対応ファイルを列挙する
    /// - Parameter other: 対応形式以外のファイルを受け取る（サイドカー収集用）
    static func scanPhotos(in folder: URL, recursive: Bool = false, other: (URL) -> Void = { _ in }) -> [PhotoItem] {
        let fm = FileManager.default
        var urls: [URL] = []
        if recursive {
            let e = fm.enumerator(at: folder, includingPropertiesForKeys: fileKeys,
                                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let u = e?.nextObject() as? URL {
                if SupportedFormats.isSupported(u) { urls.append(u) } else { other(u) }
            }
        } else {
            let all = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: fileKeys,
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
            for u in all {
                if SupportedFormats.isSupported(u) { urls.append(u) } else { other(u) }
            }
        }
        var items: [PhotoItem] = []
        items.reserveCapacity(urls.count)
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: Set(fileKeys)), v.isRegularFile == true else { continue }
            items.append(PhotoItem(url: u, fileSize: Int64(v.fileSize ?? 0),
                                   modificationDate: v.contentModificationDate ?? .distantPast))
        }
        return items
    }

    /// サブフォルダ一覧（隠しフォルダ・パッケージ（.app や .photoslibrary）は除く）
    static func subfolders(of folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.filter { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return false }
            return v.isDirectory == true && v.isPackage != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
