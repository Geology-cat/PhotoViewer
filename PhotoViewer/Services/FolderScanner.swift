import Foundation

/// フォルダ内の写真ファイルとサブフォルダを列挙する
enum FolderScanner {
    private static let fileKeys: [URLResourceKey] = [
        .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
    ]

    /// フォルダ直下（recursive なら配下すべて）の対応ファイルを列挙する
    static func scanPhotos(in folder: URL, recursive: Bool = false) -> [PhotoItem] {
        let fm = FileManager.default
        var urls: [URL] = []
        if recursive {
            let e = fm.enumerator(at: folder, includingPropertiesForKeys: fileKeys,
                                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let u = e?.nextObject() as? URL {
                if SupportedFormats.isSupported(u) { urls.append(u) }
            }
        } else {
            urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: fileKeys,
                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
            urls = urls.filter(SupportedFormats.isSupported)
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

    /// サブフォルダを 1 つでも持つか（ツリーの開閉ボタン表示用。最初の 1 件で打ち切る）
    static func hasSubfolders(_ folder: URL) -> Bool {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let e = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]) else { return false }
        while let u = e.nextObject() as? URL {
            if let v = try? u.resourceValues(forKeys: Set(keys)), v.isDirectory == true, v.isPackage != true {
                return true
            }
        }
        return false
    }
}
