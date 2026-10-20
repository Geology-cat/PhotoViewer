import Foundation
import Testing
@testable import PhotoViewer

@MainActor
struct AppSettingsTests {
    /// テストごとに専用の UserDefaults を使う（アプリ本体の設定を汚さない）
    private func makeDefaults() -> UserDefaults {
        let name = "PhotoViewerTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")

    @Test func 拡張子の正規化() {
        #expect(AppSettings.normalize(".CR3") == "cr3")
        #expect(AppSettings.normalize(" jpg ") == "jpg")
        #expect(AppSettings.normalize("...") == "")
    }

    @Test func 関連アプリを保存して読み直せる() {
        let d = makeDefaults()
        let s = AppSettings(defaults: d)
        s.setAssociation(".PNG", appURL: preview)
        #expect(s.associations["png"]?.bundleIdentifier == "com.apple.Preview")

        let reloaded = AppSettings(defaults: d)
        #expect(reloaded.associations["png"]?.bundleIdentifier == "com.apple.Preview")
        #expect(reloaded.appURL(forExtension: "png")?.lastPathComponent == "Preview.app")

        reloaded.removeAssociation("png")
        #expect(AppSettings(defaults: d).associations.isEmpty)
    }

    @Test func アプリが移動してもバンドルIDで見つける() {
        var a = AppAssociation(appURL: preview)
        a.path = "/存在しない/Preview.app"
        #expect(a.appURL?.lastPathComponent == "Preview.app")
    }

    @Test func JPEGを開ける候補アプリがある() {
        #expect(!AppSettings.candidateApps(forExtension: "jpg").isEmpty)
    }
}
