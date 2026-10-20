import AppKit
import SwiftUI

/// 環境設定（⌘,）
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("一般", systemImage: "gearshape") }
            AssociationSettingsView()
                .tabItem { Label("関連アプリ", systemImage: "app.badge") }
        }
        .frame(width: 560, height: 420)
    }
}

// MARK: - 一般

private struct GeneralSettingsView: View {
    @AppStorage(GridSettings.modeKey) private var gridMode: GridLayoutMode = .size
    @AppStorage(GridSettings.thumbnailSizeKey) private var thumbnailSize = GridSettings.defaultSize
    @AppStorage(GridSettings.columnsKey) private var columns = GridSettings.defaultColumns
    @AppStorage(GridSettings.showNamesKey) private var showNames = true

    var body: some View {
        Form {
            Section("サムネイル") {
                Picker("並べ方", selection: $gridMode) {
                    ForEach(GridLayoutMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                LabeledContent("大きさ") {
                    HStack {
                        Slider(value: $thumbnailSize, in: GridSettings.sizeRange)
                        Text("\(Int(thumbnailSize)) pt").monospacedDigit().frame(width: 50, alignment: .trailing)
                    }
                }
                .disabled(gridMode != .size)
                Stepper(value: $columns, in: GridSettings.columnsRange) {
                    LabeledContent("列数", value: "\(columns) 列")
                }
                .disabled(gridMode != .columns)
                Toggle("ファイル名を表示", isOn: $showNames)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 関連アプリ

private struct AssociationSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var selection: String?
    @State private var newExtension = ""

    private var rows: [ExtensionRow] { settings.associations.keys.sorted().map(ExtensionRow.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("グリッドでダブルクリック（または Return / ⌘O）したときに使うアプリを、拡張子ごとに指定します。指定のない拡張子は macOS の既定のアプリで開きます。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Table(rows, selection: $selection) {
                TableColumn("拡張子") { row in
                    Text(".\(row.id)").monospaced()
                }
                .width(min: 70, ideal: 90, max: 120)
                TableColumn("開くアプリ") { row in
                    AppPickerCell(ext: row.id)
                }
            }
            .onDeleteCommand {
                if let s = selection { settings.removeAssociation(s) }
            }

            HStack {
                TextField("拡張子（例：cr3）", text: $newExtension)
                    .frame(width: 160)
                    .onSubmit(add)
                Button("追加", action: add)
                    .disabled(AppSettings.normalize(newExtension).isEmpty)
                Spacer()
                Button("削除") {
                    if let s = selection { settings.removeAssociation(s) }
                }
                .disabled(selection == nil)
            }
        }
        .padding()
    }

    /// 拡張子を追加し、アプリ選択パネルを開く
    private func add() {
        let ext = AppSettings.normalize(newExtension)
        guard !ext.isEmpty else { return }
        if let app = chooseApplication(for: ext) {
            settings.setAssociation(ext, appURL: app)
            selection = ext
            newExtension = ""
        }
    }
}

private struct ExtensionRow: Identifiable {
    let id: String
}

/// 表の「開くアプリ」セル：候補アプリのメニューから選ぶ
private struct AppPickerCell: View {
    @Environment(AppSettings.self) private var settings
    let ext: String

    var body: some View {
        let current = settings.associations[ext]
        Menu {
            let candidates = AppSettings.candidateApps(forExtension: ext)
            ForEach(candidates, id: \.self) { app in
                Button {
                    settings.setAssociation(ext, appURL: app)
                } label: {
                    Label {
                        Text(AppAssociation(appURL: app).name)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    }
                }
            }
            if !candidates.isEmpty { Divider() }
            Button("その他…") {
                if let app = chooseApplication(for: ext) {
                    settings.setAssociation(ext, appURL: app)
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let url = current?.appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(current?.name ?? "")
                } else {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("\(current?.name ?? "") が見つかりません")
                }
            }
        }
        .menuStyle(.borderlessButton)
    }
}

/// .app を選ぶパネル
@MainActor
private func chooseApplication(for ext: String) -> URL? {
    let panel = NSOpenPanel()
    panel.title = ".\(ext) を開くアプリを選択"
    panel.prompt = "選択"
    panel.allowedContentTypes = [.application]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    return panel.runModal() == .OK ? panel.url : nil
}
