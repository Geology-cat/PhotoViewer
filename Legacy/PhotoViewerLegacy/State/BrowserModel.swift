import AppKit
import Foundation

/// 状態が変わったときの通知（object は BrowserModel）
extension Notification.Name {
    /// 表示中のフォルダ・読み込み中かどうか
    static let browserFolderChanged = Notification.Name("BrowserModel.folderChanged")
    /// グリッドに表示する一覧
    static let browserDisplayedChanged = Notification.Name("BrowserModel.displayedChanged")
    /// 選択・プレビュー対象
    static let browserSelectionChanged = Notification.Name("BrowserModel.selectionChanged")
    /// レーティング・現像済み
    static let browserTagsChanged = Notification.Name("BrowserModel.tagsChanged")
    /// 絞り込み・並べ替えの条件、サブフォルダの表示
    static let browserFilterChanged = Notification.Name("BrowserModel.filterChanged")
    /// 撮影情報の一括読み込みの進み具合、読み込み済みの撮影情報
    static let browserMetadataChanged = Notification.Name("BrowserModel.metadataChanged")
    /// 戻る・進むの履歴、サイドバーの起点
    static let browserLocationChanged = Notification.Name("BrowserModel.locationChanged")
    /// プレビューの回転
    static let browserRotationChanged = Notification.Name("BrowserModel.rotationChanged")
}

/// 閲覧画面の状態（通常版の BrowserState を、10.12 で使える仕組みで書き直したもの）
/// - バックグラウンドの処理は GCD で行い、結果はメインスレッドで反映する
/// - 変更は NotificationCenter で画面に知らせる
/// - メインスレッドからだけ使う
final class BrowserModel {
    static let shared = BrowserModel()

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: self)
    }

    /// 表示中のフォルダ
    private(set) var currentFolder: URL?
    /// フォルダ内の全ファイル（名前順）
    private(set) var items: [PhotoItem] = []
    /// グリッドに表示するファイル（絞り込み・並べ替え後）
    private(set) var displayedItems: [PhotoItem] = []
    /// グリッドで選択中のファイル
    private(set) var selection: Set<URL> = []
    /// プレビュー・情報パネルに表示するファイル（最後に選択したもの）
    private(set) var primarySelection: URL?
    private(set) var isScanning = false { didSet { if isScanning != oldValue { post(.browserFolderChanged) } } }

    /// 読み込み済みの撮影情報
    private(set) var metadataCache: [URL: PhotoMetadata] = [:]
    /// サイドカーの URL → レーティング・現像済み
    private(set) var tagsBySidecar: [URL: PhotoTags] = [:]
    /// 拡張子を除いたパス（小文字）→ 実在するサイドカー
    private var sidecarIndex: [String: URL] = [:]

    /// 書き込みエラーなどを知らせる（画面側で設定する）
    var onAlert: ((String) -> Void)?
    /// リネームのシートを開く（画面側で設定する）
    var onRenameRequest: (([URL]) -> Void)?

    /// プレビューの回転（度。90 の倍数）。表示だけを回す（アプリを終了するまで覚えておく）
    private(set) var previewRotation: [URL: Int] = [:]

    func rotatePreview(_ url: URL, by degrees: Int) {
        previewRotation[url] = (previewRotation[url] ?? 0) + degrees
        post(.browserRotationChanged)
    }

    /// 検索・絞り込み・並べ替えの条件
    var filter = PhotoFilter() {
        didSet {
            guard filter != oldValue else { return }
            post(.browserFilterChanged)
            if filter.needsMetadata { loadAllMetadata() }
            recomputeDisplayed()
        }
    }
    /// サブフォルダ内の写真も表示するか
    var includeSubfolders = false {
        didSet {
            guard includeSubfolders != oldValue else { return }
            post(.browserFilterChanged)
            reload()
        }
    }
    /// 撮影情報の一括読み込みの進み具合（読み込み中でなければ nil）
    private(set) var metadataProgress: (done: Int, total: Int)? {
        didSet { post(.browserMetadataChanged) }
    }
    private var bulkMetadataGeneration = 0
    private var isBulkLoading = false

    private var scanGeneration = 0
    private var loadedFolder: URL?
    private var sidecarDates: [URL: Date] = [:]
    private var pendingWrites: [URL: Int] = [:]
    private lazy var watcher = FolderWatcher { [weak self] in self?.reload() }
    /// 読み込み中の撮影情報の完了待ち（同じファイルを何度も読まない）
    private var metadataWaiters: [URL: [(PhotoMetadata) -> Void]] = [:]
    private var pendingSelection: (Set<URL>, URL?)?

    private static let lastFolderKey = "lastFolderPath"
    static let listRootKey = "sidebar.listRoot"

    private var itemsByURL: [URL: PhotoItem] = [:]

    var primaryItem: PhotoItem? {
        guard let primarySelection else { return nil }
        return itemsByURL[primarySelection]
    }

    /// 選択中のファイル（グリッドの表示順）
    var selectedURLsInDisplayOrder: [URL] {
        displayedItems.lazy.map(\.url).filter { self.selection.contains($0) }
    }

    // MARK: - サイドバーの起点（リスト表示）

    /// リスト表示の起点フォルダのパス（空 = よく使う項目・ドライブの一覧）
    var listRoot: String = UserDefaults.standard.string(forKey: BrowserModel.listRootKey) ?? "" {
        didSet {
            guard listRoot != oldValue else { return }
            UserDefaults.standard.set(listRoot, forKey: Self.listRootKey)
            if !isApplyingHistory { recordLocation() }
            post(.browserLocationChanged)
        }
    }

    /// 起点とフォルダをまとめて切り替える（サイドバーでフォルダに入るとき。履歴には 1 件だけ残す）
    func navigate(listRoot newRoot: String, folder: URL?) {
        isApplyingHistory = true
        listRoot = newRoot
        if let folder { open(folder: folder, recordHistory: false) }
        isApplyingHistory = false
        recordLocation()
        post(.browserLocationChanged)
    }

    // MARK: - フォルダ

    /// 前回開いていたフォルダを開き直す（存在の確認はバックグラウンドで）
    func restoreLastFolder() {
        guard currentFolder == nil, let path = UserDefaults.standard.string(forKey: Self.lastFolderKey) else { return }
        runInBackground({ () -> Bool in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }, then: { exists in
            if exists, self.currentFolder == nil { self.open(folder: URL(fileURLWithPath: path)) }
        })
    }

    // MARK: - 戻る・進む

    struct Location: Equatable {
        var folder: URL?
        var listRoot: String
    }

    private(set) var history: [Location] = []
    private(set) var historyIndex = -1
    private var isApplyingHistory = false
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    func recordLocation() {
        let loc = Location(folder: currentFolder, listRoot: listRoot)
        if historyIndex >= 0, history[historyIndex] == loc { return }
        history = Array(history.prefix(historyIndex + 1))
        history.append(loc)
        if history.count > 100 { history.removeFirst(history.count - 100) }
        historyIndex = history.count - 1
        post(.browserLocationChanged)
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
        isApplyingHistory = true
        listRoot = loc.listRoot
        if let f = loc.folder {
            open(folder: f, recordHistory: false)
        } else {
            closeFolder()
        }
        isApplyingHistory = false
        post(.browserLocationChanged)
    }

    func open(folder: URL, recordHistory: Bool = true) {
        let folder = folder.standardizedFileURL
        guard folder != currentFolder else { return }
        currentFolder = folder
        watcher.watch(folder)
        bulkMetadataGeneration += 1
        isBulkLoading = false
        metadataProgress = nil
        metadataCache = [:]
        UserDefaults.standard.set(folder.path, forKey: Self.lastFolderKey)
        selection = []
        primarySelection = nil
        post(.browserFolderChanged)
        post(.browserSelectionChanged)
        reload()
        if recordHistory && !isApplyingHistory { recordLocation() }
    }

    /// 表示中のフォルダを閉じる（ドライブが外されたときなど）
    func closeFolder() {
        scanGeneration += 1
        bulkMetadataGeneration += 1
        isBulkLoading = false
        watcher.stop()
        currentFolder = nil
        loadedFolder = nil
        items = []
        itemsByURL = [:]
        displayedItems = []
        selection = []
        primarySelection = nil
        metadataCache = [:]
        tagsBySidecar = [:]
        sidecarDates = [:]
        sidecarIndex = [:]
        isScanning = false
        metadataProgress = nil
        post(.browserFolderChanged)
        post(.browserDisplayedChanged)
        post(.browserSelectionChanged)
    }

    /// 現在のフォルダを読み直す
    func reload() {
        guard let folder = currentFolder else { return }
        scanGeneration += 1
        let gen = scanGeneration
        isScanning = true
        let recursive = includeSubfolders
        runInBackground({ () -> FolderScanner.ScanResult in
            var r = FolderScanner.scan(folder, recursive: recursive)
            r.items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return r
        }, then: { result in
            guard gen == self.scanGeneration, folder == self.currentFolder else { return }
            let isRefresh = self.loadedFolder == folder
            self.loadedFolder = folder
            if self.items != result.items {
                self.items = result.items
                self.itemsByURL = Dictionary(result.items.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
            }
            self.sidecarIndex = result.sidecars
            if !isRefresh {
                self.tagsBySidecar = [:]
                self.sidecarDates = [:]
            }
            self.recomputeDisplayed()
            let existing = Set(result.items.map(\.url))
            var newSelection = self.selection
            var newPrimary = self.primarySelection
            if let pending = self.pendingSelection {
                self.pendingSelection = nil
                newSelection = pending.0
                newPrimary = pending.1
            }
            newSelection.formIntersection(existing)
            if let p = newPrimary, !existing.contains(p) { newPrimary = nil }
            if newSelection != self.selection || newPrimary != self.primarySelection {
                self.selection = newSelection
                self.primarySelection = newPrimary
                self.post(.browserSelectionChanged)
            }
            self.isScanning = false
            if self.filter.needsMetadata { self.loadAllMetadata() }
            self.loadSidecars(result.sidecarDates, folder: folder)
        })
    }

    /// フォルダ内すべての撮影情報をバックグラウンドで読む（撮影情報で絞り込むときに使う）
    func loadAllMetadata() {
        guard !isBulkLoading else { return }
        let targets = items.map(\.url).filter { metadataCache[$0] == nil }
        guard !targets.isEmpty else { return }
        isBulkLoading = true
        bulkMetadataGeneration += 1
        let gen = bulkMetadataGeneration
        let folder = currentFolder
        metadataProgress = (0, targets.count)
        let chunks = stride(from: 0, to: targets.count, by: 200).map { Array(targets[$0..<min($0 + 200, targets.count)]) }
        var done = 0
        func next(_ index: Int) {
            guard gen == bulkMetadataGeneration, folder == currentFolder else { return }
            guard index < chunks.count else {
                isBulkLoading = false
                metadataProgress = nil
                return
            }
            let chunk = chunks[index]
            let isCancelled = { [weak self] in self?.bulkMetadataGeneration != gen }
            runInBackground({ Self.readMetadata(chunk, isCancelled: isCancelled) }, then: { loaded in
                guard gen == self.bulkMetadataGeneration, folder == self.currentFolder else { return }
                self.metadataCache.merge(loaded) { old, _ in old }
                done += chunk.count
                self.metadataProgress = (done, targets.count)
                self.recomputeDisplayed()
                next(index + 1)
            })
        }
        next(0)
    }

    /// 同時 4 件までで撮影情報を読む（バックグラウンドで呼ぶ）
    private static func readMetadata(_ urls: [URL], isCancelled: @escaping () -> Bool) -> [URL: PhotoMetadata] {
        var result: [URL: PhotoMetadata] = [:]
        let lock = NSLock()
        let limit = DispatchSemaphore(value: 4)
        let group = DispatchGroup()
        for u in urls {
            limit.wait()
            if DispatchQueue.main.sync(execute: isCancelled) {
                limit.signal()
                break
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let m = MetadataReader.readAnySync(url: u)
                lock.lock(); result[u] = m; lock.unlock()
                limit.signal()
                group.leave()
            }
        }
        group.wait()
        return result
    }

    /// 指定したファイルの撮影情報を読み込んでおく（リネームで撮影日を使うため）
    func ensureMetadata(_ urls: [URL], completion: @escaping () -> Void) {
        let missing = urls.filter { metadataCache[$0] == nil }
        guard !missing.isEmpty else { completion(); return }
        runInBackground({ Self.readMetadata(missing, isCancelled: { false }) }, then: { loaded in
            self.metadataCache.merge(loaded) { old, _ in old }
            completion()
        })
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
        runInBackground({ () -> ([(original: URL, trashed: URL)], [String]) in
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
            return (restored, failed)
        }, then: { restored, failed in
            if !failed.isEmpty {
                self.onAlert?("ゴミ箱に入れられませんでした\n" + failed.prefix(3).joined(separator: "\n"))
            }
            if !restored.isEmpty {
                undoManager?.registerUndo(withTarget: self) { target in target.restoreFromTrash(restored) }
                undoManager?.setActionName("ゴミ箱に入れる")
            }
            self.selection.subtract(removing)
            if let p = self.primarySelection, removing.contains(p) { self.primarySelection = nil }
            self.post(.browserSelectionChanged)
            self.reload()
        })
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
            onAlert?("ゴミ箱から戻せませんでした\n" + failed.prefix(3).joined(separator: "\n"))
        }
        pendingSelection = (Set(pairs.map(\.original).filter { SupportedFormats.isSupported($0) }),
                            pairs.first.map(\.original))
        reload()
    }

    // MARK: - バッチリネーム

    /// フォルダにあるファイル名（リネームの衝突確認用。バックグラウンドで読む）
    static func existingNames(for targets: [URL], completion: @escaping ([URL: Set<String>]) -> Void) {
        runInBackground({ () -> [URL: Set<String>] in
            var existing: [URL: Set<String>] = [:]
            for d in Set(targets.map { $0.deletingLastPathComponent() }) {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
                existing[d] = Set(names.map { $0.lowercased() })
            }
            return existing
        }, then: completion)
    }

    func makeRenamePlan(targets: [URL], options: RenameOptions, existingNames existing: [URL: Set<String>]) -> RenamePlan {
        let modDates = Dictionary(items.map { ($0.url, $0.modificationDate) }, uniquingKeysWith: { a, _ in a })
        return RenameService.plan(targets: targets, folderItems: items.map(\.url), sidecars: sidecarIndex,
                                  metadata: metadataCache, modificationDates: modDates,
                                  existingNames: existing, options: options)
    }

    /// リネームを実行し、取り消し（⌘Z）を登録する。成功したかを返す
    func performRename(_ plan: RenamePlan, undoManager: UndoManager?, completion: @escaping (Bool) -> Void) {
        runInBackground({ () -> Result<RenameJournal, Error> in
            Result { try RenameService.execute(plan) }
        }, then: { result in
            switch result {
            case .success(let journal):
                self.afterRename(journal)
                undoManager?.registerUndo(withTarget: self) { target in target.undoRename(journal) }
                undoManager?.setActionName("名前の一括変更")
                completion(true)
            case .failure(let error):
                self.onAlert?(error.localizedDescription)
                self.reload()
                completion(false)
            }
        })
    }

    private func undoRename(_ journal: RenameJournal) {
        runInBackground({ () -> Result<RenameJournal, Error> in
            Result { try RenameService.undo(journal) }
        }, then: { result in
            switch result {
            case .success(let back):
                self.afterRename(back)
            case .failure(let error):
                self.onAlert?("取り消しに失敗しました。\n" + error.localizedDescription)
                self.reload()
            }
        })
    }

    private func afterRename(_ journal: RenameJournal) {
        let map = Dictionary(journal.steps.filter { !$0.copied }.map { ($0.from, $0.to) },
                             uniquingKeysWith: { a, _ in a })
        let newSelection = Set(selection.map { map[$0] ?? $0 })
        let newPrimary = primarySelection.map { map[$0] ?? $0 }
        for s in journal.steps { ThumbnailLoader.shared.remove(s.from) }
        pendingSelection = (newSelection, newPrimary)
        reload()
    }

    /// 読み込み済みの撮影情報にあるカメラ名・レンズ名（絞り込みの候補）
    var knownCameras: [String] { Set(metadataCache.values.compactMap(\.cameraName)).sorted() }
    var knownLenses: [String] { Set(metadataCache.values.compactMap(\.lensModel)).sorted() }

    /// フォルダ内の拡張子と件数
    var extensionCounts: [(ext: String, count: Int)] {
        Dictionary(grouping: items, by: \.ext).map { ($0.key, $0.value.count) }.sorted { $0.ext < $1.ext }
    }

    /// サイドカーを読む。前回から更新日が変わったもの・新しいものだけを読み、消えたものは取り除く
    private func loadSidecars(_ dates: [URL: Date], folder: URL) {
        let changed = dates.filter { sidecarDates[$0.key] != $0.value }.map(\.key)
        let removed = Set(sidecarDates.keys).subtracting(dates.keys)
        sidecarDates = dates
        for u in pendingWrites.keys { sidecarDates[u] = nil }
        guard !changed.isEmpty || !removed.isEmpty else { return }
        runInBackground(qos: .utility, { () -> [URL: PhotoTags] in
            var d: [URL: PhotoTags] = [:]
            for u in changed {
                if let t = try? XMPSidecar.read(from: u) { d[u] = t }
            }
            return d
        }, then: { loaded in
            guard folder == self.currentFolder else { return }
            var next = self.tagsBySidecar
            for u in removed where self.pendingWrites[u] == nil { next[u] = nil }
            for (u, t) in loaded where self.pendingWrites[u] == nil { next[u] = t }
            if next != self.tagsBySidecar {
                self.tagsBySidecar = next
                self.tagsDidChange()
            }
        })
    }

    // MARK: - 表示用の一覧

    private var recomputeGeneration = 0

    /// 表示用の一覧を作り直す（件数が多いときはバックグラウンドで計算して結果だけを反映する）
    func recomputeDisplayed() {
        recomputeGeneration &+= 1
        let gen = recomputeGeneration
        let filter = self.filter, items = self.items, metadata = self.metadataCache
        let needsTags = filter.rating != .all || filter.developed != .all || filter.sortKey == .rating
        let tagSnapshot: [URL: PhotoTags] = needsTags
            ? Dictionary(items.map { ($0.url, tags(for: $0.url)) }, uniquingKeysWith: { a, _ in a }) : [:]
        if items.count <= 500 {
            applyDisplayed(filter.apply(to: items, metadata: metadata) { tagSnapshot[$0] ?? .empty })
            return
        }
        runInBackground({ filter.apply(to: items, metadata: metadata) { tagSnapshot[$0] ?? .empty } }, then: { result in
            guard gen == self.recomputeGeneration else { return }
            self.applyDisplayed(result)
        })
    }

    private func applyDisplayed(_ result: [PhotoItem]) {
        if result.count != displayedItems.count || result.map(\.url) != displayedItems.map(\.url) {
            displayedItems = result
            post(.browserDisplayedChanged)
        }
        // 非表示になったファイルは選択から外す（見えないファイルにレーティングを付けないため）
        if filter.isFiltering {
            let visible = Set(result.map(\.url))
            let pruned = selection.intersection(visible)
            var changed = false
            if pruned != selection { selection = pruned; changed = true }
            if let p = primarySelection, !visible.contains(p) {
                primarySelection = displayedItems.first { pruned.contains($0.url) }?.url
                changed = true
            }
            if changed { post(.browserSelectionChanged) }
        }
    }

    // MARK: - 選択

    /// グリッドの選択変更を受け取る
    func updateSelection(_ newSelection: Set<URL>, lastAdded: URL?) {
        let oldPrimary = primarySelection
        let oldSelection = selection
        selection = newSelection
        if let lastAdded {
            primarySelection = lastAdded
        } else if let p = primarySelection, !newSelection.contains(p) {
            primarySelection = displayedItems.first { newSelection.contains($0.url) }?.url
        } else if primarySelection == nil {
            primarySelection = displayedItems.first { newSelection.contains($0.url) }?.url
        }
        if oldSelection != selection || oldPrimary != primarySelection { post(.browserSelectionChanged) }
    }

    // MARK: - 撮影情報

    /// 撮影情報を取得する（キャッシュがなければバックグラウンドで読み、メインスレッドで completion を呼ぶ）
    func metadata(for url: URL, completion: @escaping (PhotoMetadata) -> Void) {
        if let m = metadataCache[url] {
            completion(m)
            return
        }
        if metadataWaiters[url] != nil {
            metadataWaiters[url]?.append(completion)
            return
        }
        metadataWaiters[url] = [completion]
        runInBackground({ MetadataReader.readAnySync(url: url) }, then: { m in
            self.metadataCache[url] = m
            let waiters = self.metadataWaiters.removeValue(forKey: url) ?? []
            if m.embeddedRating != nil { self.tagsDidChange() }
            for w in waiters { w(m) }
        })
    }

    // MARK: - レーティング・現像済み

    /// 実際に使うサイドカーの場所（大文字の .XMP などが既にあればそれを使う）
    func sidecarURL(for url: URL) -> URL {
        if let item = itemsByURL[url] { return sidecarIndex[item.sidecarKey] ?? item.sidecarURL }
        return sidecarIndex[FolderScanner.sidecarKey(url)] ?? url.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// 表示用のレーティング・現像済み。サイドカーがなければファイル内の XMP のレーティングを使う
    func tags(for url: URL) -> PhotoTags {
        if let t = tagsBySidecar[sidecarURL(for: url)] { return t }
        if let r = metadataCache[url]?.embeddedRating { return PhotoTags(rating: r) }
        return .empty
    }

    private func tagsDidChange() {
        post(.browserTagsChanged)
        if filter.rating != .all || filter.developed != .all || filter.sortKey == .rating {
            recomputeDisplayed()
        }
    }

    func setRating(_ rating: Int, for urls: [URL]) {
        let r = max(-1, min(5, rating))
        modifyTags(of: urls) { $0.rating = r }
    }

    /// 現像済みを切り替える（1 枚でも未設定があれば全部を済みにする）
    func toggleDeveloped(for urls: [URL]) {
        let allDeveloped = urls.allSatisfy { tags(for: $0).developed }
        setDeveloped(!allDeveloped, for: urls)
    }

    func setDeveloped(_ value: Bool, for urls: [URL]) {
        modifyTags(of: urls) { $0.developed = value }
    }

    /// 画面上はすぐ反映し、書き込みはバックグラウンドで行う。失敗したら元に戻して知らせる
    private func modifyTags(of urls: [URL], change: @escaping (inout PhotoTags) -> Void) {
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
        SidecarWriter.shared.update(targets, images: sidecars, change: change) { failures in
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
                self.onAlert?("レーティング等を保存できませんでした（\(failures.count) 件）\n"
                    + failures.prefix(3).map { "\($0.0.lastPathComponent)：\($0.1)" }.joined(separator: "\n"))
            }
        }
    }
}
