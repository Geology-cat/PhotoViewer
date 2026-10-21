import SwiftUI

/// 絞り込み・詳細検索のパネル（ツールバーのボタンから開く）
struct FilterPanel: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        @Bindable var browser = browser
        Form {
            Section {
                Toggle("サブフォルダ内の写真も表示", isOn: $browser.includeSubfolders)
            }

            Section("拡張子") {
                HStack {
                    Button("すべて") { browser.filter.extensions = [] }
                    Button("RAW のみ") {
                        browser.filter.extensions = Set(browser.extensionCounts.map(\.ext).filter(SupportedFormats.raw.contains))
                    }
                    Button("RAW 以外") {
                        browser.filter.extensions = Set(browser.extensionCounts.map(\.ext).filter { !SupportedFormats.raw.contains($0) })
                    }
                    Button("動画のみ") {
                        browser.filter.extensions = Set(browser.extensionCounts.map(\.ext).filter(SupportedFormats.video.contains))
                    }
                }
                .controlSize(.small)
                ForEach(browser.extensionCounts, id: \.ext) { entry in
                    Toggle(isOn: Binding(
                        get: { browser.filter.extensions.isEmpty || browser.filter.extensions.contains(entry.ext) },
                        set: { on in toggleExtension(entry.ext, on: on) }
                    )) {
                        HStack {
                            Text(".\(entry.ext)").monospaced()
                            Spacer()
                            Text("\(entry.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }

            Section("レーティング・現像") {
                Picker("レーティング", selection: $browser.filter.rating) {
                    Text("すべて").tag(RatingFilter.all)
                    ForEach(1...5, id: \.self) { n in
                        Text(String(repeating: "★", count: n) + " 以上").tag(RatingFilter.atLeast(n))
                    }
                    Divider()
                    ForEach(1...5, id: \.self) { n in
                        Text(String(repeating: "★", count: n) + " のみ").tag(RatingFilter.exactly(n))
                    }
                    Divider()
                    Text("なし").tag(RatingFilter.unrated)
                    Text("リジェクト").tag(RatingFilter.rejected)
                }
                Picker("現像済み", selection: $browser.filter.developed) {
                    Text("すべて").tag(TriState.all)
                    Text("済み").tag(TriState.yes)
                    Text("未").tag(TriState.no)
                }
                .pickerStyle(.segmented)
            }

            MetadataFilterSection()

            Section {
                HStack {
                    Spacer()
                    Button("条件をすべて解除") {
                        let sort = (browser.filter.sortKey, browser.filter.ascending)
                        browser.filter = PhotoFilter()
                        browser.filter.sortKey = sort.0
                        browser.filter.ascending = sort.1
                    }
                    .disabled(!browser.filter.isFiltering)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .frame(minHeight: 420, maxHeight: 680)
        .presentationBackground(Color(nsColor: .windowBackgroundColor))
    }

    /// 拡張子のチェック。空集合は「すべて」を意味するので、最初に外したときは残りを全部入れる
    private func toggleExtension(_ ext: String, on: Bool) {
        var set = browser.filter.extensions
        if set.isEmpty { set = Set(browser.extensionCounts.map(\.ext)) }
        if on { set.insert(ext) } else { set.remove(ext) }
        if set.count == browser.extensionCounts.count { set = [] }
        browser.filter.extensions = set
    }
}

/// 撮影情報による詳細検索
private struct MetadataFilterSection: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        @Bindable var browser = browser
        Section {
            if let p = browser.metadataProgress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1))) {
                    Text("撮影情報を読み込み中… \(p.done) / \(p.total)").font(.caption)
                }
            }

            OptionalDateRow(label: "撮影日（から）", date: $browser.filter.dateFrom)
            OptionalDateRow(label: "撮影日（まで）", date: $browser.filter.dateTo)

            MultiSelectMenu(label: "カメラ", options: browser.knownCameras, selection: $browser.filter.cameras)
            MultiSelectMenu(label: "レンズ", options: browser.knownLenses, selection: $browser.filter.lenses)

            RangeRow(label: "ISO", range: $browser.filter.iso, placeholder: ("100", "6400"))
            RangeRow(label: "F値", range: $browser.filter.fNumber, placeholder: ("1.4", "16"))
            ExposureRangeRow(range: $browser.filter.exposure)
            RangeRow(label: "焦点距離 mm", range: $browser.filter.focalLength, placeholder: ("14", "600"))

            Picker("位置情報", selection: $browser.filter.gps) {
                Text("すべて").tag(TriState.all)
                Text("あり").tag(TriState.yes)
                Text("なし").tag(TriState.no)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("撮影情報")
        } footer: {
            Text("撮影情報の条件を使うと、フォルダ内の写真の撮影情報をまとめて読み込みます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { browser.loadAllMetadata() }
    }
}

/// 使う／使わないを切り替えられる日付
private struct OptionalDateRow: View {
    let label: String
    @Binding var date: Date?

    var body: some View {
        HStack {
            Toggle(label, isOn: Binding(
                get: { date != nil },
                set: { date = $0 ? (date ?? Date()) : nil }
            ))
            Spacer()
            if let d = date {
                DatePicker("", selection: Binding(get: { d }, set: { date = $0 }), displayedComponents: .date)
                    .labelsHidden()
            }
        }
    }
}

/// 複数選択のメニュー（未選択 = すべて）
private struct MultiSelectMenu: View {
    let label: String
    let options: [String]
    @Binding var selection: Set<String>

    var body: some View {
        LabeledContent(label) {
            Menu {
                Button("すべて") { selection = [] }
                Divider()
                ForEach(options, id: \.self) { o in
                    Toggle(o, isOn: Binding(
                        get: { selection.contains(o) },
                        set: { on in if on { selection.insert(o) } else { selection.remove(o) } }
                    ))
                }
            } label: {
                Text(summary).lineLimit(1).truncationMode(.middle)
            }
            .fixedSize(horizontal: false, vertical: true)
            .disabled(options.isEmpty)
        }
    }

    private var summary: String {
        if options.isEmpty { return "（読み込み中・なし）" }
        switch selection.count {
        case 0: return "すべて"
        case 1: return selection.first!
        default: return "\(selection.count) 件"
        }
    }
}

/// 数値の範囲（最小〜最大）
private struct RangeRow: View {
    let label: String
    @Binding var range: NumberRange
    let placeholder: (String, String)

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField(placeholder.0, value: $range.min, format: .number)
                    .frame(width: 80)
                Text("〜")
                TextField(placeholder.1, value: $range.max, format: .number)
                    .frame(width: 80)
            }
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
        }
    }
}

/// シャッタースピードの範囲（「1/250」形式で入力）
private struct ExposureRangeRow: View {
    @Binding var range: NumberRange
    @State private var minText = ""
    @State private var maxText = ""

    var body: some View {
        LabeledContent("シャッター") {
            HStack(spacing: 4) {
                TextField("1/8000", text: $minText)
                    .frame(width: 80)
                    .onSubmit { range.min = ExposureParser.seconds(from: minText) }
                Text("〜")
                TextField("30\"", text: $maxText)
                    .frame(width: 80)
                    .onSubmit { range.max = ExposureParser.seconds(from: maxText) }
            }
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
        }
        .help("「1/250」や「2」のように入力して Return")
        .onAppear {
            minText = range.min.map(ExifFormat.exposure) ?? ""
            maxText = range.max.map(ExifFormat.exposure) ?? ""
        }
        .onChange(of: minText) { _, t in if t.isEmpty { range.min = nil } }
        .onChange(of: maxText) { _, t in if t.isEmpty { range.max = nil } }
    }
}
