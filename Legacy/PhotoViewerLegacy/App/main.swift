import AppKit

// アプリの入口（10.12 では SwiftUI の App が使えないため、AppKit で起動する）
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
