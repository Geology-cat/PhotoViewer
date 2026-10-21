import Foundation

/// メインスレッドが止まった時間を記録する（環境変数 PV_HANGCHECK=1 のときだけ動く。普段は何もしない）
/// 20ms ごとにメインスレッドへ合図を送り、返事が 100ms 以上遅れたら標準エラー出力に記録する。
/// 止まっている最中には `sample` で呼び出し履歴を保存し、原因を調べられるようにする。
enum HangWatchdog {
    static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["PV_HANGCHECK"] == "1" else { return }
        let sampleDir = env["PV_HANGCHECK_DIR"].map { URL(fileURLWithPath: $0) }
        let thread = Thread { run(sampleDir: sampleDir) }
        thread.name = "HangWatchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private static func run(sampleDir: URL?) {
        let pid = ProcessInfo.processInfo.processIdentifier
        var lastSample = Date.distantPast
        while true {
            let sem = DispatchSemaphore(value: 0)
            let start = DispatchTime.now()
            DispatchQueue.main.async { sem.signal() }
            // 150ms 待っても返事がなければ、止まっている最中なので呼び出し履歴を取る（5 秒に 1 回まで）
            if sem.wait(timeout: .now() + .milliseconds(150)) == .timedOut {
                if let dir = sampleDir, Date().timeIntervalSince(lastSample) > 5 {
                    lastSample = Date()
                    let out = dir.appendingPathComponent("hang-\(Int(Date().timeIntervalSince1970 * 1000)).txt")
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                    p.arguments = ["\(pid)", "1", "-mayDie", "-file", out.path]
                    p.standardOutput = FileHandle.nullDevice
                    p.standardError = FileHandle.nullDevice
                    try? p.run()
                }
                sem.wait()
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            if ms >= 100 {
                let f = DateFormatter()
                f.dateFormat = "HH:mm:ss.SSS"
                FileHandle.standardError.write(Data(String(format: "[hang] %@ メインスレッドが %.0f ms 止まった\n", f.string(from: Date()), ms).utf8))
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}
