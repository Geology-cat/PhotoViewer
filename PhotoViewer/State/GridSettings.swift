import Foundation

/// サムネイルグリッドの並べ方
enum GridLayoutMode: String, CaseIterable, Identifiable, Sendable {
    /// サムネイルの大きさを指定し、列数はウィンドウ幅に合わせる
    case size
    /// 列数を指定し、サムネイルの大きさはウィンドウ幅に合わせる
    case columns

    var id: String { rawValue }
    var label: String {
        switch self {
        case .size: "サイズ指定"
        case .columns: "列数指定"
        }
    }
}

/// グリッドの設定値（@AppStorage のキーと範囲）
enum GridSettings {
    static let modeKey = "grid.mode"
    static let thumbnailSizeKey = "grid.thumbnailSize"
    static let columnsKey = "grid.columns"
    static let showNamesKey = "grid.showNames"

    static let sizeRange: ClosedRange<Double> = 80...400
    static let columnsRange: ClosedRange<Int> = 1...12
    static let defaultSize: Double = 160
    static let defaultColumns = 4
}
