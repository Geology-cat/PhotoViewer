import AppKit

/// 名前の一括変更シート（通常版の RenameSheet と同じ設定項目・プレビュー）
final class RenameSheetController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let browser = BrowserModel.shared
    private let targets: [URL]
    private weak var undoManagerRef: UndoManager?

    private let templateField = NSTextField()
    private let startField = NSTextField()
    private let digitsStepper = NSStepper()
    private let digitsLabel = NSTextField(labelWithString: "")
    private let datePopup = NSPopUpButton()
    private let extensionControl = NSSegmentedControl(labels: ExtensionCase.allCases.map(\.label), trackingMode: .selectOne,
                                                      target: nil, action: nil)
    private let pairsCheck = NSButton(checkboxWithTitle: "同じ名前の RAW＋JPEG などを一緒に変更する", target: nil, action: nil)
    private let table = NSTableView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let loadingLabel = NSTextField(labelWithString: "撮影情報を読み込み中…")
    private let runButton = NSButton(title: "変更する", target: nil, action: nil)

    private var plan: RenamePlan?
    private var isLoading = true
    private var isRunning = false
    private var existingNames: [URL: Set<String>] = [:]

    private static let dateFormats = ["yyyyMMdd_HHmmss", "yyyyMMdd", "yyyy-MM-dd", "yyyy-MM-dd_HH-mm-ss", "yyMMdd"]
    private let d = UserDefaults.standard

    init(targets: [URL], undoManager: UndoManager?) {
        self.targets = targets
        self.undoManagerRef = undoManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("未対応") }

    private var options: RenameOptions {
        RenameOptions(template: templateField.stringValue, startNumber: max(0, startField.integerValue),
                      digits: digitsStepper.integerValue, dateFormat: datePopup.selectedItem?.representedObject as? String
                          ?? "yyyyMMdd_HHmmss",
                      extensionCase: ExtensionCase.allCases[max(0, extensionControl.selectedSegment)],
                      includePairs: pairsCheck.state == .on)
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "名前の一括変更（\(targets.count) 件）")
        title.font = .boldSystemFont(ofSize: 15)

        templateField.font = .userFixedPitchFont(ofSize: 13)
        templateField.placeholderString = "例：{date}_{seq}"
        templateField.stringValue = d.string(forKey: "rename.template") ?? "{date}_{seq}"
        templateField.delegate = self
        templateField.widthAnchor.constraint(equalToConstant: 420).isActive = true
        let tokens = NSStackView(views: [("連番", "{seq}"), ("撮影日時", "{date}"), ("元の名前", "{name}"),
                                         ("カメラ", "{camera}"), ("レンズ", "{lens}")].map { label, token in
            let b = NSButton(title: label, target: self, action: #selector(addToken(_:)))
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            b.identifier = NSUserInterfaceItemIdentifier(token)
            b.toolTip = "\(token) を追加"
            return b
        })
        tokens.spacing = 6
        let templateBox = NSStackView(views: [templateField, tokens])
        templateBox.orientation = .vertical
        templateBox.alignment = .leading
        templateBox.spacing = 6

        startField.integerValue = d.object(forKey: "rename.startNumber") as? Int ?? 1
        startField.delegate = self
        startField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        digitsStepper.minValue = 1
        digitsStepper.maxValue = 8
        digitsStepper.integerValue = d.object(forKey: "rename.digits") as? Int ?? 4
        digitsStepper.target = self
        digitsStepper.action = #selector(optionsChanged)
        let seqRow = NSStackView(views: [NSTextField(labelWithString: "開始"), startField, digitsLabel, digitsStepper])
        seqRow.spacing = 6

        let savedFormat = d.string(forKey: "rename.dateFormat") ?? "yyyyMMdd_HHmmss"
        for f in Self.dateFormats {
            datePopup.addItem(withTitle: "\(f)（例：\(FormatterCache.shared.string(from: Date(), format: f))）")
            datePopup.lastItem?.representedObject = f
            if f == savedFormat { datePopup.select(datePopup.lastItem) }
        }
        datePopup.target = self
        datePopup.action = #selector(optionsChanged)

        let ext = ExtensionCase(rawValue: d.string(forKey: "rename.extensionCase") ?? "") ?? .keep
        extensionControl.selectedSegment = ExtensionCase.allCases.firstIndex(of: ext) ?? 0
        extensionControl.target = self
        extensionControl.action = #selector(optionsChanged)

        pairsCheck.state = d.object(forKey: "rename.includePairs") as? Bool == false ? .off : .on
        pairsCheck.target = self
        pairsCheck.action = #selector(optionsChanged)
        let note = NSTextField(wrappingLabelWithString: "XMP サイドカー（レーティングなど）は常に一緒に変更します。撮影日時が読めないファイルは更新日を使います。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 520
        let pairsBox = NSStackView(views: [pairsCheck, note])
        pairsBox.orientation = .vertical
        pairsBox.alignment = .leading
        pairsBox.spacing = 2

        let grid = NSGridView(views: [
            [label("名前の形式"), templateBox],
            [label("連番"), seqRow],
            [label("撮影日時の書式"), datePopup],
            [label("拡張子"), extensionControl],
            [NSGridCell.emptyContentView, pairsBox],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        // プレビューの表
        for (id, title, width) in [("from", "変更前", 260.0), ("to", "変更後", 260.0), ("note", "", 140.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = CGFloat(width)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(loadingLabel)

        let cancel = NSButton(title: "キャンセル", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        runButton.target = self
        runButton.action = #selector(run)
        runButton.keyEquivalent = "\r"
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [summaryLabel, NSView(), cancel, runButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [title, grid, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let v = NSView()
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            v.widthAnchor.constraint(equalToConstant: 720),
            v.heightAnchor.constraint(equalToConstant: 620),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            loadingLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            loadingLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        view = v
    }

    private func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

    override func viewDidLoad() {
        super.viewDidLoad()
        digitsLabel.stringValue = "桁数 \(digitsStepper.integerValue)"
        updateButtons()
        browser.ensureMetadata(targets) { [weak self] in
            guard let self = self else { return }
            BrowserModel.existingNames(for: self.targets) { names in
                self.existingNames = names
                self.isLoading = false
                self.loadingLabel.isHidden = true
                self.recompute()
            }
        }
    }

    // MARK: 操作

    @objc private func addToken(_ sender: NSButton) {
        templateField.stringValue += sender.identifier?.rawValue ?? ""
        optionsChanged()
    }

    func controlTextDidChange(_ obj: Notification) { optionsChanged() }

    @objc private func optionsChanged() {
        digitsLabel.stringValue = "桁数 \(digitsStepper.integerValue)"
        let o = options
        d.set(o.template, forKey: "rename.template")
        d.set(o.startNumber, forKey: "rename.startNumber")
        d.set(o.digits, forKey: "rename.digits")
        d.set(o.dateFormat, forKey: "rename.dateFormat")
        d.set(o.extensionCase.rawValue, forKey: "rename.extensionCase")
        d.set(o.includePairs, forKey: "rename.includePairs")
        recompute()
    }

    private func recompute() {
        guard !isLoading else { return }
        plan = browser.makeRenamePlan(targets: targets, options: options, existingNames: existingNames)
        table.reloadData()
        updateButtons()
    }

    private func updateButtons() {
        runButton.isEnabled = (plan?.canExecute ?? false) && !isRunning && !isLoading
        guard let plan else {
            summaryLabel.stringValue = ""
            return
        }
        if !plan.problems.isEmpty {
            summaryLabel.stringValue = "⚠︎ \(plan.problems.count) 件の問題があります"
            summaryLabel.textColor = .systemRed
        } else {
            summaryLabel.stringValue = "\(plan.operations.count) 件のファイル名を変更します（⌘Z で取り消せます）"
            summaryLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func cancel() {
        dismiss(nil)
    }

    @objc private func run() {
        guard let plan, plan.canExecute, !isRunning else { return }
        isRunning = true
        updateButtons()
        browser.performRename(plan, undoManager: undoManagerRef) { [weak self] ok in
            self?.isRunning = false
            self?.updateButtons()
            if ok { self?.dismiss(nil) }
        }
    }

    // MARK: 表

    func numberOfRows(in tableView: NSTableView) -> Int { plan?.rows.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let r = plan?.rows[row], let id = tableColumn?.identifier.rawValue else { return nil }
        let t = NSTextField(labelWithString: "")
        t.lineBreakMode = .byTruncatingMiddle
        switch id {
        case "from":
            t.stringValue = r.source.lastPathComponent
            t.textColor = r.isSidecar ? .secondaryLabelColor : .labelColor
        case "to":
            t.stringValue = (r.problem != nil ? "⚠︎ " : "") + r.destination.lastPathComponent
            t.textColor = r.problem != nil ? .systemRed : (r.unchanged ? .secondaryLabelColor : .labelColor)
            t.toolTip = r.problem
        default:
            t.stringValue = r.problem ?? (r.isSidecar ? "サイドカー" : (r.unchanged ? "変更なし" : ""))
            t.font = .systemFont(ofSize: 11)
            t.textColor = r.problem != nil ? .systemRed : .secondaryLabelColor
        }
        return t
    }
}
