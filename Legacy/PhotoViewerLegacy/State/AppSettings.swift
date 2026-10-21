import AppKit
import CoreServices
import Foundation

/// 拡張子に割り当てたアプリ（通常版と同じ形式で保存する）
struct AppAssociation: Codable, Hashable {
    var bundleIdentifier: String?
    /// bundle identifier で見つからないときの予備
    var path: String
    var name: String

    init(appURL: URL) {
        let bundle = Bundle(url: appURL)
        bundleIdentifier = bundle?.bundleIdentifier
        path = appURL.path
        name = FileManager.default.displayName(atPath: appURL.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    /// 現在のアプリの場所（移動・更新されていても bundle identifier から探す）
    var appURL: URL? {
        if let id = bundleIdentifier, let p = NSWorkspace.shared.absolutePathForApplication(withBundleIdentifier: id) {
            return URL(fileURLWithPath: p)
        }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}

extension Notification.Name {
    static let appSettingsChanged = Notification.Name("AppSettings.changed")
}

/// アプリ全体の設定（関連アプリなど）
final class AppSettings {
    static let shared = AppSettings()

    /// 小文字の拡張子 → アプリ
    private(set) var associations: [String: AppAssociation] = [:]

    private static let associationsKey = "settings.associations"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.associationsKey),
           let decoded = try? JSONDecoder().decode([String: AppAssociation].self, from: data) {
            associations = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(associations) {
            defaults.set(data, forKey: Self.associationsKey)
        }
        NotificationCenter.default.post(name: .appSettingsChanged, object: self)
    }

    static func normalize(_ ext: String) -> String {
        ext.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    func setAssociation(_ ext: String, appURL: URL) {
        let e = Self.normalize(ext)
        guard !e.isEmpty else { return }
        associations[e] = AppAssociation(appURL: appURL)
        save()
    }

    func removeAssociation(_ ext: String) {
        associations[Self.normalize(ext)] = nil
        save()
    }

    /// 拡張子の種類（UTI）。UTType は macOS 11 以降なので、古い Launch Services の関数を使う
    private static func uti(forExtension ext: String) -> CFString? {
        UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, normalize(ext) as CFString, nil)?
            .takeRetainedValue()
    }

    private static func appURL(bundleIdentifier id: String) -> URL? {
        NSWorkspace.shared.absolutePathForApplication(withBundleIdentifier: id).map { URL(fileURLWithPath: $0) }
    }

    /// この拡張子を開けるアプリの候補
    static func candidateApps(forExtension ext: String) -> [URL] {
        guard let type = uti(forExtension: ext),
              let ids = LSCopyAllRoleHandlersForContentType(type, .all)?.takeRetainedValue() as? [String] else { return [] }
        var seen = Set<String>()
        return ids.compactMap(appURL(bundleIdentifier:))
            .filter { seen.insert($0.lastPathComponent).inserted }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// 設定に従ってファイルを開く（拡張子ごとにまとめて、それぞれのアプリへ渡す）
    func open(_ urls: [URL]) {
        let groups = Dictionary(grouping: urls) { $0.pathExtension.lowercased() }
        for (ext, files) in groups {
            if let a = associations[ext], let app = a.appURL {
                open(files, withApplicationAt: app)
            } else {
                for f in files { NSWorkspace.shared.open(f) }
            }
        }
    }

    func open(_ urls: [URL], withApplicationAt app: URL) {
        // 10.15 以降の open(_:withApplicationAt:configuration:) の代わりに、10.10 からある版を使う
        _ = try? NSWorkspace.shared.open(urls, withApplicationAt: app, options: [], configuration: [:])
    }
}
