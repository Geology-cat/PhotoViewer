import Foundation

/// 拡張子の大文字・小文字
enum ExtensionCase: String, CaseIterable, Identifiable, Sendable {
    case keep, lower, upper
    var id: String { rawValue }
    var label: String {
        switch self {
        case .keep: "そのまま"
        case .lower: "小文字"
        case .upper: "大文字"
        }
    }

    func apply(_ ext: String) -> String {
        switch self {
        case .keep: ext
        case .lower: ext.lowercased()
        case .upper: ext.uppercased()
        }
    }
}

/// リネームの設定
/// テンプレートの書き方：
///   {name} 元の名前（拡張子なし）／ {seq} 連番（{seq:4} で 4 桁）／ {date} 撮影日時（{date:yyyyMMdd} で書式指定）
///   {camera} カメラ名 ／ {lens} レンズ名 ／ それ以外はそのままの文字
struct RenameOptions: Equatable, Sendable {
    var template = "{date}_{seq}"
    var startNumber = 1
    /// {seq} に桁数の指定がないときの桁数
    var digits = 4
    /// {date} に書式の指定がないときの書式
    var dateFormat = "yyyyMMdd_HHmmss"
    var extensionCase: ExtensionCase = .keep
    /// 同名の RAW＋JPEG などを一緒に変更する（同じ名前・同じ番号）
    var includePairs = true
}

/// 1 ファイル分の変更
struct RenameOperation: Equatable, Sendable {
    enum Kind: Sendable { case photo, sidecarMove, sidecarCopy }
    var source: URL
    var destination: URL
    var kind: Kind
}

/// プレビューの 1 行
struct RenamePreviewRow: Identifiable, Equatable, Sendable {
    var id: URL { source }
    var source: URL
    var destination: URL
    var problem: String?
    var isSidecar: Bool
    var unchanged: Bool { source == destination }
}

struct RenamePlan: Sendable {
    var rows: [RenamePreviewRow]
    var operations: [RenameOperation]

    var problems: [RenamePreviewRow] { rows.filter { $0.problem != nil } }
    var canExecute: Bool { problems.isEmpty && !operations.isEmpty }
}

/// 実行した変更の記録（取り消しに使う）
struct RenameJournal: Sendable {
    /// 実行した順の (変更前, 変更後, コピーだったか)
    var steps: [(from: URL, to: URL, copied: Bool)]

    /// 新しい URL → 古い URL
    var mapping: [URL: URL] {
        Dictionary(steps.map { ($0.to, $0.from) }, uniquingKeysWith: { a, _ in a })
    }
}

enum RenameError: LocalizedError {
    case failed(String, rolledBack: Bool)

    var errorDescription: String? {
        switch self {
        case .failed(let s, let rolledBack):
            rolledBack ? "リネームに失敗したため、元に戻しました。\n\(s)"
                       : "リネームに失敗し、一部を元に戻せませんでした。\n\(s)"
        }
    }
}

/// 日付書式ごとの DateFormatter を使い回す（作成が重いため）
final class FormatterCache: @unchecked Sendable {
    static let shared = FormatterCache()
    private var formatters: [String: DateFormatter] = [:]
    private let lock = NSLock()

    func string(from date: Date, format: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let f = formatters[format] ?? {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            formatters[format] = f
            return f
        }()
        return f.string(from: date)
    }
}

enum RenameService {
    // MARK: - テンプレート

    struct TokenContext {
        var originalBase: String
        var sequence: Int
        var date: Date?
        var camera: String?
        var lens: String?
    }

    /// テンプレートから新しいベース名（拡張子なし）を作る
    static func render(_ template: String, options: RenameOptions, context: TokenContext) -> String {
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            if template[i] == "{", let close = template[i...].firstIndex(of: "}") {
                let inner = String(template[template.index(after: i)..<close])
                let parts = inner.split(separator: ":", maxSplits: 1).map(String.init)
                let key = parts.first?.lowercased() ?? ""
                let arg = parts.count > 1 ? parts[1] : nil
                switch key {
                case "name":
                    out += context.originalBase
                case "seq":
                    let d = arg.flatMap(Int.init) ?? options.digits
                    out += String(format: "%0\(max(1, min(d, 12)))d", context.sequence)
                case "date":
                    if let date = context.date {
                        out += FormatterCache.shared.string(from: date, format: arg ?? options.dateFormat)
                    }
                case "camera":
                    out += context.camera ?? ""
                case "lens":
                    out += context.lens ?? ""
                default:
                    // 知らないトークンは文字としてそのまま残す
                    out += String(template[i...close])
                }
                i = template.index(after: close)
            } else {
                out.append(template[i])
                i = template.index(after: i)
            }
        }
        // ファイル名に使えない文字を置き換える
        return out.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 計画

    /// リネームの計画を立てる（ファイルは変更しない）
    /// - Parameters:
    ///   - targets: 変更するファイル（この順に番号を振る）
    ///   - folderItems: 同じフォルダ内の写真（ペアの検出に使う）
    ///   - sidecars: 拡張子を除いたパス（小文字）→ 実在するサイドカー
    ///   - existingNames: フォルダ → そのフォルダにあるファイル名（衝突の検出に使う）
    static func plan(targets: [URL], folderItems: [URL], sidecars: [String: URL],
                     metadata: [URL: PhotoMetadata], modificationDates: [URL: Date],
                     existingNames: [URL: Set<String>], options: RenameOptions) -> RenamePlan {
        func key(_ u: URL) -> String { FolderScanner.sidecarKey(u) }

        // 1. 同じ名前になるまとまり（ユニット）を作る
        var siblingsByKey: [String: [URL]] = [:]
        for u in folderItems { siblingsByKey[key(u), default: []].append(u) }
        var units: [[URL]] = []
        var seenKeys = Set<String>()
        for t in targets {
            if options.includePairs {
                let k = key(t)
                guard seenKeys.insert(k).inserted else { continue }
                var members = [t]
                for s in siblingsByKey[k] ?? [] where s != t { members.append(s) }
                units.append(members)
            } else {
                units.append([t])
            }
        }

        // 2. 変更先を決める
        var rows: [RenamePreviewRow] = []
        var ops: [RenameOperation] = []
        let renamedSet = Set(units.flatMap { $0 })
        for (index, unit) in units.enumerated() {
            let rep = unit[0]
            let m = metadata[rep]
            let ctx = TokenContext(originalBase: rep.deletingPathExtension().lastPathComponent,
                                   sequence: options.startNumber + index,
                                   date: m?.captureDate ?? modificationDates[rep],
                                   camera: m?.cameraName, lens: m?.lensModel)
            let newBase = render(options.template, options: options, context: ctx)
            for u in unit {
                let ext = options.extensionCase.apply(u.pathExtension)
                let dest = u.deletingLastPathComponent()
                    .appendingPathComponent(ext.isEmpty ? newBase : "\(newBase).\(ext)")
                rows.append(RenamePreviewRow(source: u, destination: dest, problem: nil, isSidecar: false))
                if dest != u { ops.append(RenameOperation(source: u, destination: dest, kind: .photo)) }
            }
            // サイドカーも一緒に。ユニット外に同じサイドカーを使うファイルが残るならコピーする
            if let sc = sidecars[key(rep)] {
                let remaining = (siblingsByKey[key(rep)] ?? []).contains { !renamedSet.contains($0) }
                let dest = sc.deletingLastPathComponent().appendingPathComponent("\(newBase).\(sc.pathExtension)")
                rows.append(RenamePreviewRow(source: sc, destination: dest, problem: nil, isSidecar: true))
                if dest != sc {
                    ops.append(RenameOperation(source: sc, destination: dest,
                                               kind: remaining ? .sidecarCopy : .sidecarMove))
                }
            }
        }

        // 3. 問題の検出
        let movedAway = Set(ops.filter { $0.kind != .sidecarCopy }.map { $0.source.path.lowercased() })
        var destCount: [String: Int] = [:]
        for r in rows { destCount[r.destination.path.lowercased(), default: 0] += 1 }
        for i in rows.indices {
            let r = rows[i]
            let base = r.destination.deletingPathExtension().lastPathComponent
            let destKey = r.destination.path.lowercased()
            if base.isEmpty {
                rows[i].problem = "名前が空になります"
            } else if r.destination.lastPathComponent.hasPrefix(".") {
                rows[i].problem = "名前が「.」で始まります"
            } else if destCount[destKey, default: 0] > 1 {
                rows[i].problem = "変更後の名前が重複しています"
            } else if !r.unchanged && r.source.path.lowercased() != destKey {
                // 既存のファイルとの衝突（同時に別名へ移動するファイルは除く）
                let dir = r.destination.deletingLastPathComponent()
                let name = r.destination.lastPathComponent.lowercased()
                if existingNames[dir]?.contains(name) == true && !movedAway.contains(destKey) {
                    rows[i].problem = "同じ名前のファイルがすでにあります"
                }
            }
        }
        return RenamePlan(rows: rows, operations: ops)
    }

    // MARK: - 実行

    /// 計画を実行する。途中で失敗したら、それまでの変更を元に戻して例外を投げる
    /// A→B と B→A のような入れ替えにも対応するため、いったん一時名にしてから最終名にする
    static func execute(_ plan: RenamePlan) throws -> RenameJournal {
        try execute(plan.operations.map { ($0.source, $0.destination, $0.kind == .sidecarCopy) })
    }

    /// 取り消し：移動は元の名前に戻し、コピーで作ったサイドカーはゴミ箱へ移す
    static func undo(_ journal: RenameJournal) throws -> RenameJournal {
        let fm = FileManager.default
        for s in journal.steps where s.copied && fm.fileExists(atPath: s.to.path) {
            try fm.trashItem(at: s.to, resultingItemURL: nil)
        }
        let moves = journal.steps.filter { !$0.copied }.map { (from: $0.to, to: $0.from, copy: false) }
        return try execute(moves)
    }

    private static func execute(_ moves: [(from: URL, to: URL, copy: Bool)]) throws -> RenameJournal {
        let fm = FileManager.default
        let renames = moves.filter { !$0.copy && $0.from != $0.to }.map { (from: $0.from, to: $0.to) }
        let copies = moves.filter { $0.copy && $0.from != $0.to }

        // 移動（2 段階）
        var moved: [(from: URL, to: URL)] = []
        do {
            moved = try twoPhaseMove(renames)
        } catch let e as PartialMoveError {
            // 途中まで動いたものを、現在の場所から元の場所へ戻す
            let ok = (try? twoPhaseMove(e.current.map { (from: $0.now, to: $0.original) })) != nil
            throw RenameError.failed(e.underlying.localizedDescription, rolledBack: ok)
        }

        // コピー（同名のファイルが残る場合のサイドカー）
        var copied: [(from: URL, to: URL)] = []
        do {
            for c in copies {
                if fm.fileExists(atPath: c.to.path) {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: c.to.path])
                }
                try fm.copyItem(at: c.from, to: c.to)
                copied.append((c.from, c.to))
            }
        } catch {
            var ok = true
            for c in copied { do { try fm.removeItem(at: c.to) } catch { ok = false } }
            if (try? twoPhaseMove(moved.map { (from: $0.to, to: $0.from) })) == nil { ok = false }
            throw RenameError.failed(error.localizedDescription, rolledBack: ok)
        }
        return RenameJournal(steps: moved.map { ($0.from, $0.to, false) } + copied.map { ($0.from, $0.to, true) })
    }

    private struct PartialMoveError: Error {
        var underlying: Error
        /// 各ファイルの今の場所と元の場所
        var current: [(now: URL, original: URL)]
    }

    /// いったん一時名に移してから最終名へ移す（A→B と B→A の入れ替えに対応）
    private static func twoPhaseMove(_ pairs: [(from: URL, to: URL)]) throws -> [(from: URL, to: URL)] {
        let fm = FileManager.default
        let token = UUID().uuidString.prefix(8)
        var location: [(now: URL, original: URL)] = []
        do {
            var temps: [URL] = []
            for (i, p) in pairs.enumerated() {
                let temp = p.from.deletingLastPathComponent()
                    .appendingPathComponent(".pv-rename-\(token)-\(i)-\(p.from.lastPathComponent)")
                try fm.moveItem(at: p.from, to: temp)
                location.append((temp, p.from))
                temps.append(temp)
            }
            for (i, p) in pairs.enumerated() {
                if fm.fileExists(atPath: p.to.path) {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: p.to.path])
                }
                try fm.moveItem(at: temps[i], to: p.to)
                location[i].now = p.to
            }
        } catch {
            throw PartialMoveError(underlying: error, current: location)
        }
        return pairs
    }
}
