import AppKit

/// 絞り込み・詳細検索のパネル（ツールバーのボタンから開く。通常版の FilterPanel と同じ項目）
final class FilterPanelController: NSViewController, NSTextFieldDelegate, NSMenuDelegate {
    private let browser = BrowserModel.shared
    private let stack = NSStackView()

    private let subfolders = NSButton(checkboxWithTitle: "サブフォルダ内の写真も表示", target: nil, action: nil)
    private let extStack = NSStackView()
    private var extButtons: [String: NSButton] = [:]
    private let ratingPopup = NSPopUpButton()
    private let developed = NSSegmentedControl(labels: ["すべて", "済み", "未"], trackingMode: .selectOne, target: nil, action: nil)
    private let progressLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let dateFromCheck = NSButton(checkboxWithTitle: "撮影日（から）", target: nil, action: nil)
    private let dateToCheck = NSButton(checkboxWithTitle: "撮影日（まで）", target: nil, action: nil)
    private let dateFrom = NSDatePicker()
    private let dateTo = NSDatePicker()
    private let cameraButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let lensButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var rangeFields: [NSTextField: (WritableKeyPath<PhotoFilter, NumberRange>, Bool, Bool)] = [:]
    private let gps = NSSegmentedControl(labels: ["すべて", "あり", "なし"], trackingMode: .selectOne, target: nil, action: nil)
    private let clearButton = NSButton(title: "条件をすべて解除", target: nil, action: nil)

    private static let ratingOptions: [(String, RatingFilter)] = {
        var o: [(String, RatingFilter)] = [("すべて", .all)]
        for n in 1...5 { o.append((String(repeating: "★", count: n) + " 以上", .atLeast(n))) }
        for n in 1...5 { o.append((String(repeating: "★", count: n) + " のみ", .exactly(n))) }
        o.append(("なし", .unrated))
        o.append(("リジェクト", .rejected))
        return o
    }()

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        subfolders.target = self
        subfolders.action = #selector(subfoldersChanged)
        stack.addArrangedSubview(subfolders)

        // 拡張子
        stack.addArrangedSubview(heading("拡張子"))
        let quick = NSStackView(views: [
            smallButton("すべて", #selector(extAll)), smallButton("RAW のみ", #selector(extRAW)),
            smallButton("RAW 以外", #selector(extNonRAW)), smallButton("動画のみ", #selector(extVideo)),
        ])
        quick.spacing = 6
        stack.addArrangedSubview(quick)
        extStack.orientation = .vertical
        extStack.alignment = .leading
        extStack.spacing = 2
        stack.addArrangedSubview(extStack)

        // レーティング・現像
        stack.addArrangedSubview(heading("レーティング・現像"))
        for (title, _) in Self.ratingOptions { ratingPopup.addItem(withTitle: title) }
        ratingPopup.target = self
        ratingPopup.action = #selector(ratingChanged)
        stack.addArrangedSubview(row("レーティング", ratingPopup))
        developed.target = self
        developed.action = #selector(developedChanged)
        stack.addArrangedSubview(row("現像済み", developed))

        // 撮影情報
        stack.addArrangedSubview(heading("撮影情報"))
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.controlSize = .small
        progressBar.widthAnchor.constraint(equalToConstant: 200).isActive = true
        progressLabel.font = .systemFont(ofSize: 11)
        let progress = NSStackView(views: [progressLabel, progressBar])
        progress.orientation = .vertical
        progress.alignment = .leading
        progress.identifier = NSUserInterfaceItemIdentifier("progress")
        stack.addArrangedSubview(progress)
        for (check, picker) in [(dateFromCheck, dateFrom), (dateToCheck, dateTo)] {
            check.target = self
            check.action = #selector(dateChanged)
            picker.datePickerElements = .yearMonthDay
            picker.datePickerStyle = .textFieldAndStepper
            picker.dateValue = Date()
            picker.target = self
            picker.action = #selector(dateChanged)
            let r = NSStackView(views: [check, picker])
            r.spacing = 8
            stack.addArrangedSubview(r)
        }
        for b in [cameraButton, lensButton] {
            b.menu?.delegate = self
            b.widthAnchor.constraint(equalToConstant: 220).isActive = true
        }
        stack.addArrangedSubview(row("カメラ", cameraButton))
        stack.addArrangedSubview(row("レンズ", lensButton))
        stack.addArrangedSubview(row("ISO", rangeRow(\.iso, ("100", "6400"))))
        stack.addArrangedSubview(row("F値", rangeRow(\.fNumber, ("1.4", "16"))))
        stack.addArrangedSubview(row("シャッター", rangeRow(\.exposure, ("1/8000", "30\""), exposure: true)))
        stack.addArrangedSubview(row("焦点距離 mm", rangeRow(\.focalLength, ("14", "600"))))
        gps.target = self
        gps.action = #selector(gpsChanged)
        stack.addArrangedSubview(row("位置情報", gps))
        let note = NSTextField(wrappingLabelWithString: "撮影情報の条件を使うと、フォルダ内の写真の撮影情報をまとめて読み込みます。シャッターは「1/250」や「2」のように入力して Return。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 360
        stack.addArrangedSubview(note)

        clearButton.target = self
        clearButton.action = #selector(clearAll)
        stack.addArrangedSubview(clearButton)

        // 拡張子が多いときに備えてスクロールできるようにする
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 420),
            scroll.heightAnchor.constraint(equalToConstant: 620),
        ])
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(refresh), name: .browserFilterChanged, object: browser)
        nc.addObserver(self, selector: #selector(refresh), name: .browserFolderChanged, object: browser)
        nc.addObserver(self, selector: #selector(refreshProgress), name: .browserMetadataChanged, object: browser)
        refresh()
        // 撮影情報の候補（カメラ・レンズ）を用意するため、開いたら読み込みを始める
        browser.loadAllMetadata()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: 部品

    private func heading(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 12, weight: .semibold)
        t.textColor = .secondaryLabelColor
        return t
    }

    private func smallButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        b.bezelStyle = .rounded
        return b
    }

    private func row(_ label: String, _ control: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let r = NSStackView(views: [l, control])
        r.spacing = 8
        r.alignment = .centerY
        return r
    }

    private func rangeRow(_ key: WritableKeyPath<PhotoFilter, NumberRange>, _ placeholder: (String, String),
                          exposure: Bool = false) -> NSStackView {
        func field(_ ph: String, isMin: Bool) -> NSTextField {
            let f = NSTextField()
            f.placeholderString = ph
            f.alignment = .right
            f.widthAnchor.constraint(equalToConstant: 80).isActive = true
            f.delegate = self
            f.target = self
            f.action = #selector(rangeCommitted(_:))
            rangeFields[f] = (key, isMin, exposure)
            return f
        }
        let r = NSStackView(views: [field(placeholder.0, isMin: true), NSTextField(labelWithString: "〜"),
                                    field(placeholder.1, isMin: false)])
        r.spacing = 4
        return r
    }

    // MARK: 状態の反映

    @objc private func refresh() {
        let f = browser.filter
        subfolders.state = browser.includeSubfolders ? .on : .off
        // 拡張子のチェック（フォルダの拡張子が変わったときだけ作り直す）
        let counts = browser.extensionCounts
        if counts.map(\.ext) != extButtons.keys.sorted() {
            extStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            extButtons = [:]
            for entry in counts {
                let b = NSButton(checkboxWithTitle: ".\(entry.ext)　\(entry.count)", target: self, action: #selector(extToggled(_:)))
                b.identifier = NSUserInterfaceItemIdentifier(entry.ext)
                extButtons[entry.ext] = b
                extStack.addArrangedSubview(b)
            }
        }
        for (ext, b) in extButtons { b.state = f.extensions.isEmpty || f.extensions.contains(ext) ? .on : .off }
        ratingPopup.selectItem(at: Self.ratingOptions.firstIndex { $0.1 == f.rating } ?? 0)
        developed.selectedSegment = [TriState.all, .yes, .no].firstIndex(of: f.developed) ?? 0
        gps.selectedSegment = [TriState.all, .yes, .no].firstIndex(of: f.gps) ?? 0
        dateFromCheck.state = f.dateFrom != nil ? .on : .off
        dateToCheck.state = f.dateTo != nil ? .on : .off
        if let d = f.dateFrom { dateFrom.dateValue = d }
        if let d = f.dateTo { dateTo.dateValue = d }
        dateFrom.isEnabled = f.dateFrom != nil
        dateTo.isEnabled = f.dateTo != nil
        for (field, info) in rangeFields where view.window?.firstResponder != field.currentEditor() {
            let range = f[keyPath: info.0]
            let v = info.1 ? range.min : range.max
            field.stringValue = v.map { info.2 ? ExifFormat.exposure($0) : Self.number($0) } ?? ""
        }
        clearButton.isEnabled = f.isFiltering
        refreshProgress()
    }

    @objc private func refreshProgress() {
        let progressView = stack.arrangedSubviews.first { $0.identifier?.rawValue == "progress" }
        if let p = browser.metadataProgress {
            progressView?.isHidden = false
            progressLabel.stringValue = "撮影情報を読み込み中… \(p.done) / \(p.total)"
            progressBar.maxValue = Double(max(p.total, 1))
            progressBar.doubleValue = Double(p.done)
        } else {
            progressView?.isHidden = true
        }
        setPullDownTitle(cameraButton, summary(browser.filter.cameras, options: browser.knownCameras))
        setPullDownTitle(lensButton, summary(browser.filter.lenses, options: browser.knownLenses))
    }

    /// プルダウンは 1 項目目がボタンの表示になる（中身は開くときに作る）
    private func setPullDownTitle(_ button: NSPopUpButton, _ title: String) {
        if button.numberOfItems == 0 { button.addItem(withTitle: title) } else { button.item(at: 0)?.title = title }
    }

    private static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    private func summary(_ selection: Set<String>, options: [String]) -> String {
        if options.isEmpty { return "（読み込み中・なし）" }
        switch selection.count {
        case 0: return "すべて"
        case 1: return selection.first!
        default: return "\(selection.count) 件"
        }
    }

    // MARK: 操作

    @objc private func subfoldersChanged() { browser.includeSubfolders = subfolders.state == .on }

    @objc private func extAll() { browser.filter.extensions = [] }
    @objc private func extRAW() { setExtensions { SupportedFormats.raw.contains($0) } }
    @objc private func extNonRAW() { setExtensions { !SupportedFormats.raw.contains($0) } }
    @objc private func extVideo() { setExtensions { SupportedFormats.video.contains($0) } }

    private func setExtensions(_ include: (String) -> Bool) {
        browser.filter.extensions = Set(browser.extensionCounts.map(\.ext).filter(include))
    }

    /// 空集合は「すべて」を意味するので、最初に外したときは残りを全部入れる
    @objc private func extToggled(_ sender: NSButton) {
        guard let ext = sender.identifier?.rawValue else { return }
        var set = browser.filter.extensions
        if set.isEmpty { set = Set(browser.extensionCounts.map(\.ext)) }
        if sender.state == .on { set.insert(ext) } else { set.remove(ext) }
        if set.count == browser.extensionCounts.count { set = [] }
        browser.filter.extensions = set
    }

    @objc private func ratingChanged() {
        browser.filter.rating = Self.ratingOptions[max(0, ratingPopup.indexOfSelectedItem)].1
    }

    @objc private func developedChanged() {
        browser.filter.developed = [TriState.all, .yes, .no][max(0, developed.selectedSegment)]
    }

    @objc private func gpsChanged() {
        browser.filter.gps = [TriState.all, .yes, .no][max(0, gps.selectedSegment)]
    }

    @objc private func dateChanged() {
        var f = browser.filter
        f.dateFrom = dateFromCheck.state == .on ? dateFrom.dateValue : nil
        f.dateTo = dateToCheck.state == .on ? dateTo.dateValue : nil
        browser.filter = f
    }

    @objc private func rangeCommitted(_ sender: NSTextField) {
        guard let info = rangeFields[sender] else { return }
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        let value: Double? = text.isEmpty ? nil
            : (info.2 ? ExposureParser.seconds(from: text) : Double(text.replacingOccurrences(of: ",", with: ".")))
        var f = browser.filter
        if info.1 { f[keyPath: info.0].min = value } else { f[keyPath: info.0].max = value }
        browser.filter = f
    }

    /// 欄から出たときも反映する
    func controlTextDidEndEditing(_ obj: Notification) {
        if let f = obj.object as? NSTextField { rangeCommitted(f) }
    }

    @objc private func clearAll() {
        let sort = (browser.filter.sortKey, browser.filter.ascending)
        var f = PhotoFilter()
        f.sortKey = sort.0
        f.ascending = sort.1
        f.text = ""
        browser.filter = f
    }

    // MARK: カメラ・レンズのメニュー（開くたびに作る）

    func menuNeedsUpdate(_ menu: NSMenu) {
        let isCamera = menu === cameraButton.menu
        let options = isCamera ? browser.knownCameras : browser.knownLenses
        let selection = isCamera ? browser.filter.cameras : browser.filter.lenses
        menu.removeAllItems()
        // プルダウンの 1 項目目はボタンの表示に使われる
        menu.addItem(withTitle: summary(selection, options: options), action: nil, keyEquivalent: "")
        let all = NSMenuItem(title: "すべて", action: #selector(choiceAll(_:)), keyEquivalent: "")
        all.target = self
        all.representedObject = isCamera
        menu.addItem(all)
        menu.addItem(.separator())
        for o in options {
            let mi = NSMenuItem(title: o, action: #selector(choiceToggled(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = isCamera
            mi.state = selection.contains(o) ? .on : .off
            menu.addItem(mi)
        }
    }

    @objc private func choiceAll(_ sender: NSMenuItem) {
        if sender.representedObject as? Bool == true { browser.filter.cameras = [] } else { browser.filter.lenses = [] }
    }

    @objc private func choiceToggled(_ sender: NSMenuItem) {
        let isCamera = sender.representedObject as? Bool == true
        var set = isCamera ? browser.filter.cameras : browser.filter.lenses
        if set.contains(sender.title) { set.remove(sender.title) } else { set.insert(sender.title) }
        if isCamera { browser.filter.cameras = set } else { browser.filter.lenses = set }
    }
}
