import AppKit
import Foundation
import Observation

/// 閲覧画面の状態（選択中のフォルダ・ファイル一覧・選択状態）
@MainActor
@Observable
final class BrowserState {
    /// 表示中のフォルダ
    private(set) var currentFolder: URL?
    /// フォルダ内の全ファイル（名前順）
    private(set) var items: [PhotoItem] = []
    /// グリッドで選択中のファイル
    var selection: Set<URL> = []
    /// プレビュー・情報パネルに表示するファイル（最後に選択したもの）
    var primarySelection: URL?
    private(set) var isScanning = false

    /// 読み込み済みの撮影情報
    private(set) var metadataCache: [URL: PhotoMetadata] = [:]

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var metadataTasks: [URL: Task<PhotoMetadata, Never>] = [:]

    private static let lastFolderKey = "lastFolderPath"

    /// グリッドに表示するファイル（Phase 4 で絞り込み・並べ替えを入れる）
    var displayedItems: [PhotoItem] { items }

    var primaryItem: PhotoItem? {
        guard let primarySelection else { return nil }
        return items.first { $0.url == primarySelection }
    }

    /// 前回開いていたフォルダを開き直す
    func restoreLastFolder() {
        guard currentFolder == nil,
              let path = UserDefaults.standard.string(forKey: Self.lastFolderKey) else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            open(folder: URL(fileURLWithPath: path))
        }
    }

    func open(folder: URL) {
        let folder = folder.standardizedFileURL
        guard folder != currentFolder else { return }
        currentFolder = folder
        UserDefaults.standard.set(folder.path, forKey: Self.lastFolderKey)
        selection = []
        primarySelection = nil
        PerfLog.folderOpened(folder)
        reload()
    }

    /// 現在のフォルダを読み直す
    func reload() {
        guard let folder = currentFolder else { return }
        scanTask?.cancel()
        isScanning = true
        scanTask = Task {
            let found = await Task.detached(priority: .userInitiated) {
                FolderScanner.scanPhotos(in: folder)
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }.value
            guard !Task.isCancelled, folder == self.currentFolder else { return }
            self.items = found
            PerfLog.scanFinished(count: found.count)
            let existing = Set(found.map(\.url))
            self.selection = self.selection.intersection(existing)
            if let p = self.primarySelection, !existing.contains(p) { self.primarySelection = nil }
            self.isScanning = false
        }
    }

    /// グリッドの選択変更を受け取る
    func updateSelection(_ newSelection: Set<URL>, lastAdded: URL?) {
        selection = newSelection
        if let lastAdded {
            primarySelection = lastAdded
        } else if let p = primarySelection, !newSelection.contains(p) {
            primarySelection = displayedItems.first { newSelection.contains($0.url) }?.url
        } else if primarySelection == nil {
            primarySelection = displayedItems.first { newSelection.contains($0.url) }?.url
        }
    }

    /// 撮影情報を取得する（キャッシュがなければバックグラウンドで読む）
    func metadata(for url: URL) async -> PhotoMetadata {
        if let m = metadataCache[url] { return m }
        let task: Task<PhotoMetadata, Never>
        if let running = metadataTasks[url] {
            task = running
        } else {
            task = Task.detached(priority: .userInitiated) { MetadataReader.read(url: url) }
            metadataTasks[url] = task
        }
        let m = await task.value
        metadataCache[url] = m
        metadataTasks[url] = nil
        return m
    }

    /// 既定のアプリで開く（Phase 5 で拡張子ごとの関連アプリに対応する）
    func openExternally(_ urls: [URL]) {
        for u in urls { NSWorkspace.shared.open(u) }
    }
}
