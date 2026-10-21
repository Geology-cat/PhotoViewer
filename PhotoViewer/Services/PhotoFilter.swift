import Foundation

/// 数値の範囲条件（片側だけでもよい）
struct NumberRange: Equatable, Sendable {
    var min: Double?
    var max: Double?

    var isActive: Bool { min != nil || max != nil }

    func contains(_ v: Double?) -> Bool {
        guard isActive else { return true }
        guard let v else { return false }
        if let min, v < min - 1e-9 { return false }
        if let max, v > max + 1e-9 { return false }
        return true
    }
}

enum RatingFilter: Hashable, Sendable {
    case all
    case atLeast(Int)
    case exactly(Int)
    case unrated
    case rejected

    func matches(_ rating: Int) -> Bool {
        switch self {
        case .all: true
        case .atLeast(let n): rating >= n
        case .exactly(let n): rating == n
        case .unrated: rating == 0
        case .rejected: rating == -1
        }
    }
}

enum TriState: String, CaseIterable, Identifiable, Sendable {
    case all, yes, no
    var id: String { rawValue }
}

enum SortKey: String, CaseIterable, Identifiable, Sendable {
    case name, kind, captureDate, modificationDate, rating, fileSize
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: "ファイル名"
        case .kind: "種類"
        case .captureDate: "撮影日"
        case .modificationDate: "更新日"
        case .rating: "レーティング"
        case .fileSize: "ファイルサイズ"
        }
    }
}

/// 検索・絞り込み・並べ替えの条件
struct PhotoFilter: Equatable, Sendable {
    /// フリーワード（ファイル名・カメラ・レンズ。空白区切りはすべてを含むもの）
    var text = ""
    /// 表示する拡張子（空 = すべて）
    var extensions: Set<String> = []
    var rating: RatingFilter = .all
    var developed: TriState = .all

    // 撮影情報による条件
    var dateFrom: Date?
    var dateTo: Date?
    var cameras: Set<String> = []
    var lenses: Set<String> = []
    var iso = NumberRange()
    var fNumber = NumberRange()
    /// 露出時間（秒）
    var exposure = NumberRange()
    var focalLength = NumberRange()
    var gps: TriState = .all

    var sortKey: SortKey = .name
    var ascending = true

    /// 撮影情報（EXIF）による絞り込み条件があるか
    var usesExifConditions: Bool {
        dateFrom != nil || dateTo != nil || !cameras.isEmpty || !lenses.isEmpty
            || iso.isActive || fNumber.isActive || exposure.isActive || focalLength.isActive
            || gps != .all
    }

    /// 撮影情報の一括読み込みが必要か
    /// レーティングの条件・並べ替えも含む（サイドカーの無い JPEG などはファイル内の★を EXIF と一緒に読むため）
    var needsMetadata: Bool {
        usesExifConditions || sortKey == .captureDate || rating != .all || sortKey == .rating
    }

    /// 並べ替え以外の条件が入っているか
    var isFiltering: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || !extensions.isEmpty || rating != .all
            || developed != .all || dateFrom != nil || dateTo != nil || !cameras.isEmpty || !lenses.isEmpty
            || iso.isActive || fNumber.isActive || exposure.isActive || focalLength.isActive || gps != .all
    }

    /// 撮影情報の条件だけを解除する
    mutating func clearMetadataConditions() {
        dateFrom = nil
        dateTo = nil
        cameras = []
        lenses = []
        iso = NumberRange()
        fNumber = NumberRange()
        exposure = NumberRange()
        focalLength = NumberRange()
        gps = .all
    }

    /// 絞り込みと並べ替えを行う
    /// - Parameters:
    ///   - metadata: 読み込み済みの撮影情報（未読み込みのファイルは撮影情報の条件に一致しないものとして扱う）
    ///   - tags: レーティング・現像済みの取得
    func apply(to items: [PhotoItem], metadata: [URL: PhotoMetadata],
               tags: (URL) -> PhotoTags) -> [PhotoItem] {
        let words = text.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        let needsMeta = usesExifConditions
        let calendar = Calendar.current
        let endOfDateTo = dateTo.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
        let startOfDateFrom = dateFrom.map { calendar.startOfDay(for: $0) }

        let filtered = items.filter { item in
            if !extensions.isEmpty && !extensions.contains(item.ext) { return false }
            let meta = metadata[item.url]
            if !words.isEmpty {
                // ファイル名は小文字にしたものを最初に用意してあるので速い。カメラ・レンズは撮影情報があるときだけ
                for w in words where !item.lowerName.contains(w) {
                    let inMeta = meta.map { m in
                        (m.cameraName?.lowercased().contains(w) ?? false) || (m.lensModel?.lowercased().contains(w) ?? false)
                    } ?? false
                    if !inMeta { return false }
                }
            }
            if rating != .all || developed != .all {
                let t = tags(item.url)
                if !rating.matches(t.rating) { return false }
                if developed == .yes && !t.developed { return false }
                if developed == .no && t.developed { return false }
            }
            if needsMeta {
                guard let m = meta else { return false }
                if let s = startOfDateFrom {
                    guard let d = m.captureDate, d >= s else { return false }
                }
                if let e = endOfDateTo {
                    guard let d = m.captureDate, d < e else { return false }
                }
                if !cameras.isEmpty && !cameras.contains(m.cameraName ?? "") { return false }
                if !lenses.isEmpty && !lenses.contains(m.lensModel ?? "") { return false }
                if !iso.contains(m.iso.map(Double.init)) { return false }
                if !fNumber.contains(m.fNumber) { return false }
                if !exposure.contains(m.exposureTime) { return false }
                if !focalLength.contains(m.focalLength) { return false }
                if gps == .yes && m.coordinate == nil { return false }
                if gps == .no && m.coordinate != nil { return false }
            }
            return true
        }
        return sorted(filtered, metadata: metadata, tags: tags)
    }

    private func sorted(_ items: [PhotoItem], metadata: [URL: PhotoMetadata],
                        tags: (URL) -> PhotoTags) -> [PhotoItem] {
        // 同じ値のときはファイル名順（元の並び）を保つ
        let indexed = Array(items.enumerated())
        let result: [(offset: Int, element: PhotoItem)]
        switch sortKey {
        case .name:
            result = ascending ? indexed : indexed.reversed()
        case .captureDate:
            // 撮影日がないものは更新日で代用する
            let keys = Dictionary(uniqueKeysWithValues: items.map {
                ($0.url, metadata[$0.url]?.captureDate ?? $0.modificationDate)
            })
            result = indexed.sorted { a, b in
                let ka = keys[a.element.url]!, kb = keys[b.element.url]!
                if ka == kb { return a.offset < b.offset }
                return ascending ? ka < kb : ka > kb
            }
        case .modificationDate:
            result = indexed.sorted { a, b in
                let ka = a.element.modificationDate, kb = b.element.modificationDate
                if ka == kb { return a.offset < b.offset }
                return ascending ? ka < kb : ka > kb
            }
        case .rating:
            let keys = Dictionary(uniqueKeysWithValues: items.map { ($0.url, tags($0.url).rating) })
            result = indexed.sorted { a, b in
                let ka = keys[a.element.url]!, kb = keys[b.element.url]!
                if ka == kb { return a.offset < b.offset }
                return ascending ? ka < kb : ka > kb
            }
        case .fileSize:
            result = indexed.sorted { a, b in
                let ka = a.element.fileSize, kb = b.element.fileSize
                if ka == kb { return a.offset < b.offset }
                return ascending ? ka < kb : ka > kb
            }
        case .kind:
            // 種類の順（RAW → JPEG → HEIC → TIF → PNG → その他 → 動画）、同じ種類なら拡張子、その次はファイル名
            result = indexed.sorted { a, b in
                let ka = (a.element.kindRank, a.element.ext), kb = (b.element.kindRank, b.element.ext)
                if ka == kb { return a.offset < b.offset }
                return ascending ? ka < kb : ka > kb
            }
        }
        return result.map(\.element)
    }
}

/// シャッタースピードの入力（「1/250」「2」「2"」「0.5」）を秒に変換する
enum ExposureParser {
    static func seconds(from text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "秒", with: "")
        guard !t.isEmpty else { return nil }
        if let slash = t.firstIndex(of: "/") {
            guard let n = Double(t[..<slash]), let d = Double(t[t.index(after: slash)...]), d > 0 else { return nil }
            return n / d
        }
        return Double(t)
    }
}
