import Foundation

/// フォルダの変更（ファイルの追加・削除・名前変更）を監視する
/// 変更が続く間は待ち、落ち着いてから 1 回だけ通知する
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    func watch(_ folder: URL) {
        stop()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                            queue: .main)
        src.setEventHandler { [weak self] in self?.schedule() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() {
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
