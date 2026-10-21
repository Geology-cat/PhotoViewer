import CoreServices
import Foundation

/// フォルダ以下の変更を FSEvents で受け取る（配下すべてが対象。中身が変わったフォルダのパスが届く）
/// サイドバーのツリーで、新しく作ったフォルダなどをすぐに反映するために使う
/// FSEvents のコールバックはメインキューで受け取り、状態もメインスレッドでしか触らないので @unchecked Sendable にする
final class DirectoryEventWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []
    #if LEGACY
    private let handler: ([String]) -> Void

    init(handler: @escaping ([String]) -> Void) {
        self.handler = handler
    }
    #else
    private let handler: @MainActor ([String]) -> Void

    init(handler: @escaping @MainActor ([String]) -> Void) {
        self.handler = handler
    }
    #endif

    deinit { stop() }

    /// 監視するフォルダを指定する（同じなら何もしない）
    func watch(_ paths: [String]) {
        let paths = Array(Set(paths)).sorted()
        guard paths != watchedPaths else { return }
        stop()
        watchedPaths = paths
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryEventWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            // メインキューで受け取る設定なので、ここはメインスレッド
            #if LEGACY
            watcher.handler(paths)
            #else
            MainActor.assumeIsolated { watcher.handler(paths) }
            #endif
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        stream = nil
        watchedPaths = []
    }
}
