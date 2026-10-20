import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// 拡張子に割り当てたアプリ
struct AppAssociation: Codable, Hashable, Sendable {
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
        if let id = bundleIdentifier, let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return u
        }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}

/// アプリ全体の設定（関連アプリなど）
@MainActor
@Observable
final class AppSettings {
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

    /// この拡張子のファイルを開くアプリ（未設定なら OS の既定アプリ）
    func appURL(forExtension ext: String, sampleFile: URL? = nil) -> URL? {
        if let a = associations[Self.normalize(ext)], let u = a.appURL { return u }
        return Self.defaultAppURL(forExtension: ext, sampleFile: sampleFile)
    }

    static func defaultAppURL(forExtension ext: String, sampleFile: URL? = nil) -> URL? {
        if let sampleFile, let u = NSWorkspace.shared.urlForApplication(toOpen: sampleFile) { return u }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: type)
    }

    /// この拡張子を開けるアプリの候補
    static func candidateApps(forExtension ext: String) -> [URL] {
        guard let type = UTType(filenameExtension: normalize(ext)) else { return [] }
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: type)
        var seen = Set<String>()
        return urls.filter { seen.insert($0.lastPathComponent).inserted }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// 設定に従ってファイルを開く（拡張子ごとにまとめて、それぞれのアプリへ渡す）
    func open(_ urls: [URL]) {
        let groups = Dictionary(grouping: urls) { $0.pathExtension.lowercased() }
        for (ext, files) in groups {
            if let a = associations[ext], let app = a.appURL {
                NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else {
                for f in files { NSWorkspace.shared.open(f) }
            }
        }
    }

    func open(_ urls: [URL], withApplicationAt app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
