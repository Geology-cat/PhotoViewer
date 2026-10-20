import AppKit
import Foundation
import Observation

/// 閲覧画面の状態（選択中のフォルダ・ファイル一覧・選択状態・レーティング）
@MainActor
@Observable
final class BrowserState {
    /// 表示中のフォルダ
    private(set) var currentFolder: URL?
    /// フォルダ内の全ファイル（名前順）
    private(set) var items: [PhotoItem] = []
    /// グリッドに表示するファイル（絞り込み・並べ替え後）
    private(set) var displayedItems: [PhotoItem] = []
    /// グリッドで選択中のファイル
    var selection: Set<URL> = []
    /// プレビュー・情報パネルに表示するファイル（最後に選択したもの）
    var primarySelection: URL?
    private(set) var isScanning = false

    /// 読み込み済みの撮影情報
    private(set) var metadataCache: [URL: PhotoMetadata] = [:]

    /// サイドカーの URL → レーティング・現像済み
    private(set) var tagsBySidecar: [URL: PhotoTags] = [:]
    /// レーティング等が変わるたびに増える（グリッドの再描画の合図）
    private(set) var tagsVersion = 0
    /// 拡張子を除いたパス（小文字）→ 実在するサイドカー
    @ObservationIgnored private var sidecarIndex: [String: URL] = [:]

    /// 書き込みエラーなど、ユーザーに知らせるメッセージ
    var alertMessage: String?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var metadataTasks: [URL: Task<PhotoMetadata, Never>] = [:]

    private static let lastFolderKey = "lastFolderPath"

    var primaryItem: PhotoItem? {
        guard let primarySelection else { return nil }
        return items.first { $0.url == primarySelection }
    }

    /// 選択中のファイル（グリッドの表示順）
    var selectedURLsInDisplayOrder: [URL] {
        displayedItems.lazy.map(\.url).filter { self.selection.contains($0) }
    }

    // MARK: - フォルダ

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
            var result = await Task.detached(priority: .userInitiated) {
                FolderScanner.scan(folder)
            }.value
            result.items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            guard !Task.isCancelled, folder == self.currentFolder else { return }
            self.items = result.items
            self.sidecarIndex = result.sidecars
            self.tagsBySidecar = [:]
            self.recomputeDisplayed()
            PerfLog.scanFinished(count: result.items.count)
            let existing = Set(result.items.map(\.url))
            self.selection = self.selection.intersection(existing)
            if let p = self.primarySelection, !existing.contains(p) { self.primarySelection = nil }
            self.isScanning = false
            await self.loadSidecars(Array(result.sidecars.values), folder: folder)
        }
    }

    /// サイドカーをまとめて読む（小さいファイルなので一括で読む）
    private func loadSidecars(_ urls: [URL], folder: URL) async {
        guard !urls.isEmpty else { return }
        let loaded: [URL: PhotoTags] = await Task.detached(priority: .utility) {
            var d: [URL: PhotoTags] = [:]
            for u in urls {
                if Task.isCancelled { break }
                if let t = try? XMPSidecar.read(from: u) { d[u] = t }
            }
            return d
        }.value
        guard !Task.isCancelled, folder == currentFolder else { return }
        tagsBySidecar.merge(loaded) { _, new in new }
        tagsDidChange()
    }

    /// 表示用の一覧を作り直す（Phase 4 で絞り込み・並べ替えを入れる）
    func recomputeDisplayed() {
        displayedItems = items
    }

    // MARK: - 選択

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

    // MARK: - 撮影情報

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

    // MARK: - レーティング・現像済み

    /// 実際に使うサイドカーの場所（大文字の .XMP などが既にあればそれを使う）
    func sidecarURL(for url: URL) -> URL {
        sidecarIndex[FolderScanner.sidecarKey(url)] ?? url.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// 表示用のレーティング・現像済み。サイドカーがなければファイル内の XMP のレーティングを使う
    func tags(for url: URL) -> PhotoTags {
        if let t = tagsBySidecar[sidecarURL(for: url)] { return t }
        if let r = metadataCache[url]?.embeddedRating { return PhotoTags(rating: r) }
        return .empty
    }

    private func tagsDidChange() {
        tagsVersion &+= 1
    }

    func setRating(_ rating: Int, for urls: [URL]) {
        let r = max(-1, min(5, rating))
        modifyTags(of: urls) { $0.rating = r }
    }

    /// 選択中の現像済みを切り替える（1 枚でも未設定があれば全部を済みにする）
    func toggleDeveloped(for urls: [URL]) {
        let allDeveloped = urls.allSatisfy { tags(for: $0).developed }
        setDeveloped(!allDeveloped, for: urls)
    }

    func setDeveloped(_ value: Bool, for urls: [URL]) {
        modifyTags(of: urls) { $0.developed = value }
    }

    /// 画面上はすぐ反映し、書き込みはバックグラウンドで行う。失敗したら元に戻して知らせる
    private func modifyTags(of urls: [URL], change: @escaping @Sendable (inout PhotoTags) -> Void) {
        // 同名ペアは 1 つのサイドカーを共有するのでまとめる
        var sidecars: [URL: URL] = [:]   // サイドカー → 代表の画像
        for u in urls { sidecars[sidecarURL(for: u)] = sidecars[sidecarURL(for: u)] ?? u }
        guard !sidecars.isEmpty else { return }

        var previous: [URL: PhotoTags?] = [:]
        for (sc, image) in sidecars {
            previous.updateValue(tagsBySidecar[sc], forKey: sc)
            var t = tags(for: image)
            change(&t)
            tagsBySidecar[sc] = t
        }
        tagsDidChange()

        let targets = Array(sidecars.keys)
        Task {
            let failures = await SidecarWriter.shared.update(targets, change: change)
            for (sc, _) in failures {
                if let old = previous[sc] { self.tagsBySidecar[sc] = old }
            }
            for sc in targets where !failures.contains(where: { $0.0 == sc }) {
                self.sidecarIndex[FolderScanner.sidecarKey(sc)] = sc
            }
            if !failures.isEmpty {
                self.tagsDidChange()
                self.alertMessage = "レーティング等を保存できませんでした（\(failures.count) 件）\n"
                    + failures.prefix(3).map { "\($0.0.lastPathComponent)：\($0.1)" }.joined(separator: "\n")
            }
        }
    }
}
