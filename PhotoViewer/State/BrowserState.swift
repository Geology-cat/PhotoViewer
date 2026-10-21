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

    /// プレビューの回転（度。90 の倍数）。表示だけを回し、ファイルは書き換えない（アプリを終了するまで覚えておく）
    /// 360 で割らずに積み重ねるのは、押した向きにだけ 90° 回るアニメーションにするため
    private(set) var previewRotation: [URL: Int] = [:]

    func rotatePreview(_ url: URL, by degrees: Int) {
        previewRotation[url] = (previewRotation[url] ?? 0) + degrees
    }

    /// バッチリネームの対象（nil でなければシートを表示する）
    var renameTargets: [URL]?

    /// 検索・絞り込み・並べ替えの条件
    var filter = PhotoFilter() {
        didSet {
            guard filter != oldValue else { return }
            if filter.needsMetadata { loadAllMetadata() }
            recomputeDisplayed()
        }
    }
    /// サブフォルダ内の写真も表示するか
    var includeSubfolders = false {
        didSet { if includeSubfolders != oldValue { reload() } }
    }
    /// 撮影情報の一括読み込みの進み具合（読み込み中でなければ nil）
    private(set) var metadataProgress: (done: Int, total: Int)?
    @ObservationIgnored private var bulkMetadataTask: Task<Void, Never>?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// 一覧を読み込み済みのフォルダ（同じフォルダの読み直しかどうかの判定用）
    @ObservationIgnored private var loadedFolder: URL?
    /// 読み込み済みサイドカーの更新日（同じフォルダの読み直しでは、変わったものだけ読む）
    @ObservationIgnored private var sidecarDates: [URL: Date] = [:]
    /// 書き込み中のサイドカー（読み直しで古い値に戻さないため）
    @ObservationIgnored private var pendingWrites: [URL: Int] = [:]
    @ObservationIgnored private lazy var watcher = FolderWatcher { [weak self] in self?.reload() }
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

    // MARK: - 戻る・進む（Finder と同じ移動の履歴）

    /// 履歴の 1 件：表示していたフォルダと、サイドバー（リスト表示）の起点
    struct Location: Equatable {
        var folder: URL?
        var listRoot: String
    }

    private(set) var history: [Location] = []
    private(set) var historyIndex = -1
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    static let listRootKey = "sidebar.listRoot"

    /// 今の場所を履歴に加える（直前と同じなら何もしない。戻った後に別の場所へ移ったら「進む」側は捨てる）
    func recordLocation() {
        let loc = Location(folder: currentFolder,
                           listRoot: UserDefaults.standard.string(forKey: Self.listRootKey) ?? "")
        if historyIndex >= 0, history[historyIndex] == loc { return }
        history = Array(history.prefix(historyIndex + 1))
        history.append(loc)
        if history.count > 100 { history.removeFirst(history.count - 100) }
        historyIndex = history.count - 1
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        apply(history[historyIndex])
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        apply(history[historyIndex])
    }

    private func apply(_ loc: Location) {
        UserDefaults.standard.set(loc.listRoot, forKey: Self.listRootKey)
        if let f = loc.folder {
            open(folder: f, recordHistory: false)
        } else {
            closeFolder()
        }
    }

    func open(folder: URL, recordHistory: Bool = true) {
        let folder = folder.standardizedFileURL
        guard folder != currentFolder else { return }
        defer { if recordHistory { recordLocation() } }
        currentFolder = folder
        watcher.watch(folder)
        // フォルダを移ったら撮影情報のキャッシュは捨てる（メモリを増やし続けないため）
        bulkMetadataTask?.cancel()
        metadataProgress = nil
        metadataCache = [:]
        UserDefaults.standard.set(folder.path, forKey: Self.lastFolderKey)
        selection = []
        primarySelection = nil
        PerfLog.folderOpened(folder)
        reload()
    }

    /// 表示中のフォルダを閉じる（ドライブが外されたときなど）
    func closeFolder() {
        scanTask?.cancel()
        bulkMetadataTask?.cancel()
        watcher.stop()
        currentFolder = nil
        loadedFolder = nil
        items = []
        displayedItems = []
        selection = []
        primarySelection = nil
        metadataCache = [:]
        tagsBySidecar = [:]
        sidecarDates = [:]
        sidecarIndex = [:]
        isScanning = false
        metadataProgress = nil
    }

    /// 現在のフォルダを読み直す
    func reload() {
        guard let folder = currentFolder else { return }
        scanTask?.cancel()
        isScanning = true
        let recursive = includeSubfolders
        scanTask = Task {
            var result = await Task.detached(priority: .userInitiated) {
                FolderScanner.scan(folder, recursive: recursive)
            }.value
            result.items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            guard !Task.isCancelled, folder == self.currentFolder else { return }
            let isRefresh = self.loadedFolder == folder
            self.loadedFolder = folder
            // 中身が同じなら代入しない（不要な再描画を避ける）
            if self.items != result.items { self.items = result.items }
            self.sidecarIndex = result.sidecars
            // 別のフォルダを開いたときだけ消す（同じフォルダの読み直しでは★がちらつかないよう残す）
            if !isRefresh {
                self.tagsBySidecar = [:]
                self.sidecarDates = [:]
            }
            self.recomputeDisplayed()
            PerfLog.scanFinished(count: result.items.count)
            let existing = Set(result.items.map(\.url))
            if let pending = self.pendingSelection {
                self.pendingSelection = nil
                self.selection = pending.0
                self.primarySelection = pending.1
            }
            self.selection = self.selection.intersection(existing)
            if let p = self.primarySelection, !existing.contains(p) { self.primarySelection = nil }
            self.isScanning = false
            if self.filter.needsMetadata { self.loadAllMetadata() }
            await self.loadSidecars(result.sidecarDates, folder: folder)
        }
    }

    /// フォルダ内すべての撮影情報をバックグラウンドで読む（撮影情報で絞り込むときに使う）
    func loadAllMetadata() {
        guard bulkMetadataTask == nil else { return }
        let targets = items.map(\.url).filter { metadataCache[$0] == nil }
        guard !targets.isEmpty else { return }
        let folder = currentFolder
        metadataProgress = (0, targets.count)
        let start = ContinuousClock.now
        bulkMetadataTask = Task {
            defer {
                self.bulkMetadataTask = nil
                self.metadataProgress = nil
            }
            var done = 0
            // 200 件ずつ読んで、その都度画面に反映する
            for chunk in stride(from: 0, to: targets.count, by: 200).map({ Array(targets[$0..<min($0 + 200, targets.count)]) }) {
                let loaded = await Self.readMetadata(chunk)
                guard !Task.isCancelled, folder == self.currentFolder else { return }
                self.metadataCache.merge(loaded) { old, _ in old }
                done += chunk.count
                self.metadataProgress = (done, targets.count)
                self.recomputeDisplayed()
            }
            PerfLog.metadataLoaded(count: targets.count, since: start)
        }
    }

    /// 並列（同時 4 件まで）で撮影情報を読む
    nonisolated private static func readMetadata(_ urls: [URL]) async -> [URL: PhotoMetadata] {
        await withTaskGroup(of: (URL, PhotoMetadata).self) { group in
            var result: [URL: PhotoMetadata] = [:]
            var iterator = urls.makeIterator()
            for _ in 0..<4 {
                guard let u = iterator.next() else { break }
                group.addTask { (u, MetadataReader.read(url: u)) }
            }
            while let (u, m) = await group.next() {
                result[u] = m
                if Task.isCancelled { group.cancelAll(); break }
                if let next = iterator.next() {
                    group.addTask { (next, MetadataReader.read(url: next)) }
                }
            }
            return result
        }
    }

    /// 指定したファイルの撮影情報を読み込んでおく（リネームで撮影日を使うため）
    func ensureMetadata(_ urls: [URL]) async {
        let missing = urls.filter { metadataCache[$0] == nil }
        guard !missing.isEmpty else { return }
        let loaded = await Self.readMetadata(missing)
        metadataCache.merge(loaded) { old, _ in old }
    }

    // MARK: - ゴミ箱

    /// ゴミ箱へ移す。同名のファイルがすべてなくなるならサイドカーも移す。⌘Z で戻せる
    func moveToTrash(_ urls: [URL], undoManager: UndoManager?) {
        guard !urls.isEmpty else { return }
        let removing = Set(urls)
        var targets = urls
        for u in urls {
            let key = FolderScanner.sidecarKey(u)
            let siblingsRemain = items.contains { FolderScanner.sidecarKey($0.url) == key && !removing.contains($0.url) }
            if !siblingsRemain, let sc = sidecarIndex[key], !targets.contains(sc) { targets.append(sc) }
        }
        Task {
            var restored: [(original: URL, trashed: URL)] = []
            var failed: [String] = []
            for u in targets {
                do {
                    var result: NSURL?
                    try FileManager.default.trashItem(at: u, resultingItemURL: &result)
                    if let t = result as URL? { restored.append((u, t)) }
                } catch {
                    failed.append("\(u.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            if !failed.isEmpty {
                self.alertMessage = "ゴミ箱に入れられませんでした\n" + failed.prefix(3).joined(separator: "\n")
            }
            if !restored.isEmpty {
                let pairs = restored
                undoManager?.registerUndo(withTarget: self) { target in
                    MainActor.assumeIsolated { target.restoreFromTrash(pairs) }
                }
                undoManager?.setActionName("ゴミ箱に入れる")
            }
            self.selection.subtract(removing)
            if let p = self.primarySelection, removing.contains(p) { self.primarySelection = nil }
            self.reload()
        }
    }

    private func restoreFromTrash(_ pairs: [(original: URL, trashed: URL)]) {
        var failed: [String] = []
        for p in pairs {
            do {
                try FileManager.default.moveItem(at: p.trashed, to: p.original)
            } catch {
                failed.append("\(p.original.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if !failed.isEmpty {
            alertMessage = "ゴミ箱から戻せませんでした\n" + failed.prefix(3).joined(separator: "\n")
        }
        pendingSelection = (Set(pairs.map(\.original).filter { SupportedFormats.isSupported($0) }),
                            pairs.first.map(\.original))
        reload()
    }

    // MARK: - バッチリネーム

    func makeRenamePlan(targets: [URL], options: RenameOptions) -> RenamePlan {
        let dirs = Set(targets.map { $0.deletingLastPathComponent() })
        var existing: [URL: Set<String>] = [:]
        for d in dirs {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
            existing[d] = Set(names.map { $0.lowercased() })
        }
        let modDates = Dictionary(items.map { ($0.url, $0.modificationDate) }, uniquingKeysWith: { a, _ in a })
        return RenameService.plan(targets: targets, folderItems: items.map(\.url), sidecars: sidecarIndex,
                                  metadata: metadataCache, modificationDates: modDates,
                                  existingNames: existing, options: options)
    }

    /// リネームを実行し、取り消し（⌘Z）を登録する
    func performRename(_ plan: RenamePlan, undoManager: UndoManager?) async -> Bool {
        do {
            let journal = try await Task.detached(priority: .userInitiated) {
                try RenameService.execute(plan)
            }.value
            afterRename(journal)
            undoManager?.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated { target.undoRename(journal) }
            }
            undoManager?.setActionName("名前の一括変更")
            return true
        } catch {
            alertMessage = error.localizedDescription
            reload()
            return false
        }
    }

    private func undoRename(_ journal: RenameJournal) {
        Task {
            do {
                let back = try await Task.detached(priority: .userInitiated) {
                    try RenameService.undo(journal)
                }.value
                self.afterRename(back)
            } catch {
                self.alertMessage = "取り消しに失敗しました。\n" + error.localizedDescription
                self.reload()
            }
        }
    }

    /// リネーム後：一覧を読み直し、変更後のファイルを選択した状態にする
    private func afterRename(_ journal: RenameJournal) {
        let map = Dictionary(journal.steps.filter { !$0.copied }.map { ($0.from, $0.to) },
                             uniquingKeysWith: { a, _ in a })
        let newSelection = Set(selection.map { map[$0] ?? $0 })
        let newPrimary = primarySelection.map { map[$0] ?? $0 }
        for s in journal.steps { ThumbnailLoader.shared.remove(s.from) }
        pendingSelection = (newSelection, newPrimary)
        reload()
    }

    @ObservationIgnored private var pendingSelection: (Set<URL>, URL?)?

    /// 読み込み済みの撮影情報にあるカメラ名・レンズ名（絞り込みの候補）
    var knownCameras: [String] {
        Set(metadataCache.values.compactMap(\.cameraName)).sorted()
    }

    var knownLenses: [String] {
        Set(metadataCache.values.compactMap(\.lensModel)).sorted()
    }

    /// フォルダ内の拡張子と件数
    var extensionCounts: [(ext: String, count: Int)] {
        Dictionary(grouping: items, by: \.ext).map { ($0.key, $0.value.count) }.sorted { $0.ext < $1.ext }
    }

    /// サイドカーをまとめて読む（小さいファイルなので一括で読む）
    /// サイドカーを読む。前回から更新日が変わったもの・新しいものだけを読み、消えたものは取り除く
    private func loadSidecars(_ dates: [URL: Date], folder: URL) async {
        let changed = dates.filter { sidecarDates[$0.key] != $0.value }.map(\.key)
        let removed = Set(sidecarDates.keys).subtracting(dates.keys)
        sidecarDates = dates
        // 書き込み中のものは更新日を覚えず、次の読み直しで必ず読む
        for u in pendingWrites.keys { sidecarDates[u] = nil }
        PerfLog.sidecarsReloaded(changed: changed.count, removed: removed.count, total: dates.count)
        guard !changed.isEmpty || !removed.isEmpty else { return }
        let urls = changed
        let loaded: [URL: PhotoTags] = await Task.detached(priority: .utility) {
            var d: [URL: PhotoTags] = [:]
            for u in urls {
                if Task.isCancelled { break }
                if let t = try? XMPSidecar.read(from: u) { d[u] = t }
            }
            return d
        }.value
        guard !Task.isCancelled, folder == currentFolder else { return }
        // 変わったものを反映し、消えたサイドカーの分は消す。書き込み中のものは今の値を残す
        var next = tagsBySidecar
        for u in removed where pendingWrites[u] == nil { next[u] = nil }
        for (u, t) in loaded where pendingWrites[u] == nil { next[u] = t }
        if next != tagsBySidecar {
            tagsBySidecar = next
            tagsDidChange()
        }
    }

    /// 表示用の一覧を作り直す
    func recomputeDisplayed() {
        let result = filter.apply(to: items, metadata: metadataCache) { self.tags(for: $0) }
        if result.map(\.url) != displayedItems.map(\.url) {
            displayedItems = result
        }
        // 非表示になったファイルは選択から外す（見えないファイルにレーティングを付けないため）
        if filter.isFiltering {
            let visible = Set(result.map(\.url))
            let pruned = selection.intersection(visible)
            if pruned != selection { selection = pruned }
            if let p = primarySelection, !visible.contains(p) {
                primarySelection = displayedItems.first { pruned.contains($0.url) }?.url
            }
        }
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
        // ファイル内のレーティングで表示が変わることがある
        if m.embeddedRating != nil { tagsDidChange() }
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
        if filter.rating != .all || filter.developed != .all || filter.sortKey == .rating {
            recomputeDisplayed()
        }
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
        for t in targets { pendingWrites[t, default: 0] += 1 }
        Task {
            // サイドカーがまだ無いファイルは、ファイル内の★（カメラや Lightroom が書いたもの）を初期値にする
            let failures = await SidecarWriter.shared.update(targets, images: sidecars, change: change)
            for t in targets {
                self.pendingWrites[t, default: 1] -= 1
                if self.pendingWrites[t] == 0 { self.pendingWrites[t] = nil }
            }
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
