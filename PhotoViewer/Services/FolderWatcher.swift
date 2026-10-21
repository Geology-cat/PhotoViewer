import Foundation

/// フォルダの変更（ファイルの追加・削除・名前変更）を監視する
/// 変更が続く間は待ち、落ち着いてから 1 回だけ通知する
@MainActor
final class FolderWatcher {
    // deinit から片付けるため、メインスレッド以外からも触れる印を付ける（実際に触るのはメインスレッドだけ）
    nonisolated(unsafe) private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private let onChange: @MainActor () -> Void
    /// 監視の世代（フォルダを素早く切り替えたとき、古い監視を使わないため）
    private var generation = 0

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    deinit { source?.cancel() }

    func watch(_ folder: URL) {
        stop()
        let gen = generation
        let path = folder.path
        // フォルダを開く処理はバックグラウンドで（外付け HDD が止まっていると、開くだけで数秒かかることがある）
        Task { [weak self] in
            let fd = await Task.detached(priority: .utility) { open(path, O_EVTONLY) }.value
            guard fd >= 0 else { return }
            guard let self, self.generation == gen else {
                close(fd)
                return
            }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                                eventMask: [.write, .rename, .delete], queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.schedule() }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            self.source = src
        }
    }

    func stop() {
        generation += 1
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func schedule() {
        pending?.cancel()
        let onChange = onChange
        let item = DispatchWorkItem { MainActor.assumeIsolated { onChange() } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: item)
    }
}
