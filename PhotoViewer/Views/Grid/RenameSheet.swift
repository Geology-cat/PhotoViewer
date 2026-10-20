import SwiftUI

/// 名前の一括変更シート
struct RenameSheet: View {
    @Environment(BrowserState.self) private var browser
    @Environment(\.dismiss) private var dismiss
    let targets: [URL]
    /// メインウインドウの取り消し管理（シートを閉じた後も ⌘Z で取り消せるように）
    let undoManager: UndoManager?

    @AppStorage("rename.template") private var template = "{date}_{seq}"
    @AppStorage("rename.startNumber") private var startNumber = 1
    @AppStorage("rename.digits") private var digits = 4
    @AppStorage("rename.dateFormat") private var dateFormat = "yyyyMMdd_HHmmss"
    @AppStorage("rename.extensionCase") private var extensionCase: ExtensionCase = .keep
    @AppStorage("rename.includePairs") private var includePairs = true

    @State private var plan: RenamePlan?
    @State private var isLoadingMetadata = true
    @State private var isRunning = false

    private var options: RenameOptions {
        RenameOptions(template: template, startNumber: startNumber, digits: digits, dateFormat: dateFormat,
                      extensionCase: extensionCase, includePairs: includePairs)
    }

    private static let dateFormats = ["yyyyMMdd_HHmmss", "yyyyMMdd", "yyyy-MM-dd", "yyyy-MM-dd_HH-mm-ss", "yyMMdd"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("名前の一括変更（\(targets.count) 件）").font(.title3.bold())

            settingsForm

            Divider()
            previewTable

            HStack {
                summary
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("変更する") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(plan?.canExecute ?? false) || isRunning || isLoadingMetadata)
            }
        }
        .padding(20)
        .frame(width: 720, height: 620)
        .task {
            await browser.ensureMetadata(targets)
            isLoadingMetadata = false
            recompute()
        }
        .onChange(of: options) { _, _ in recompute() }
    }

    private var settingsForm: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("名前の形式").gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    TextField("例：{date}_{seq}", text: $template)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    HStack(spacing: 6) {
                        tokenButton("連番", "{seq}")
                        tokenButton("撮影日時", "{date}")
                        tokenButton("元の名前", "{name}")
                        tokenButton("カメラ", "{camera}")
                        tokenButton("レンズ", "{lens}")
                    }
                    .controlSize(.small)
                }
            }
            GridRow {
                Text("連番")
                HStack {
                    Text("開始")
                    TextField("", value: $startNumber, format: .number)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                    Stepper("桁数 \(digits)", value: $digits, in: 1...8)
                }
            }
            GridRow {
                Text("撮影日時の書式")
                Picker("", selection: $dateFormat) {
                    ForEach(Self.dateFormats, id: \.self) { f in
                        Text("\(f)（例：\(FormatterCache.shared.string(from: Date(), format: f))）").tag(f)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Text("拡張子")
                Picker("", selection: $extensionCase) {
                    ForEach(ExtensionCase.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Text("")
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("同じ名前の RAW＋JPEG などを一緒に変更する", isOn: $includePairs)
                    Text("XMP サイドカー（レーティングなど）は常に一緒に変更します。撮影日時が読めないファイルは更新日を使います。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tokenButton(_ label: String, _ token: String) -> some View {
        Button(label) { template += token }
            .help("\(token) を追加")
    }

    private var previewTable: some View {
        Table(plan?.rows ?? []) {
            TableColumn("変更前") { row in
                Text(row.source.lastPathComponent)
                    .foregroundStyle(row.isSidecar ? .secondary : .primary)
            }
            TableColumn("変更後") { row in
                HStack(spacing: 4) {
                    if row.problem != nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    Text(row.destination.lastPathComponent)
                        .foregroundStyle(row.problem != nil ? .red : (row.unchanged ? .secondary : .primary))
                }
                .help(row.problem ?? "")
            }
            TableColumn("") { row in
                Text(row.problem ?? (row.isSidecar ? "サイドカー" : (row.unchanged ? "変更なし" : "")))
                    .font(.caption)
                    .foregroundStyle(row.problem != nil ? .red : .secondary)
            }
            .width(min: 80, ideal: 160)
        }
        .overlay {
            if isLoadingMetadata { ProgressView("撮影情報を読み込み中…") }
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let plan {
            let changes = plan.operations.count
            if !plan.problems.isEmpty {
                Label("\(plan.problems.count) 件の問題があります", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else {
                Text("\(changes) 件のファイル名を変更します（⌘Z で取り消せます）")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func recompute() {
        guard !isLoadingMetadata else { return }
        plan = browser.makeRenamePlan(targets: targets, options: options)
    }

    private func run() {
        guard let plan, plan.canExecute else { return }
        isRunning = true
        Task {
            let ok = await browser.performRename(plan, undoManager: undoManager)
            isRunning = false
            if ok { dismiss() }
        }
    }
}
