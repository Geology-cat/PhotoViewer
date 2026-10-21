import AppKit

/// 右下：画像情報パネル（ファイル名・★と現像済みの編集・撮影情報・位置情報・ファイル情報）
final class InfoPanel: NSView {
    private let browser = BrowserModel.shared
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var item: PhotoItem?
    private var metadata: PhotoMetadata?

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(selectionChanged), name: .browserSelectionChanged, object: browser)
        nc.addObserver(self, selector: #selector(rebuild), name: .browserTagsChanged, object: browser)
        selectionChanged()
    }

    required init?(coder: NSCoder) { fatalError("未対応") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func selectionChanged() {
        let newItem = browser.primaryItem
        if newItem?.url != item?.url {
            item = newItem
            metadata = nil
            if let url = newItem?.url {
                browser.metadata(for: url) { [weak self] m in
                    guard let self = self, self.item?.url == url else { return }
                    self.metadata = m
                    self.rebuild()
                }
            }
        }
        rebuild()
    }

    /// 複数選択中は選択中すべて、そうでなければ表示中の 1 枚が対象
    private var targets: [URL] {
        guard let item else { return [] }
        return browser.selection.count > 1 ? browser.selectedURLsInDisplayOrder : [item.url]
    }

    // MARK: 組み立て

    @objc private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let item else {
            stack.addArrangedSubview(Self.secondary("情報なし"))
            return
        }
        let title = Self.label(item.name, font: .boldSystemFont(ofSize: 13))
        title.isSelectable = true
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingMiddle
        add(title)
        add(tagEditor())

        guard let m = metadata else {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            add(spinner)
            return
        }
        let date = m.captureDate.map { ExifFormat.dateFormatter.string(from: $0) }
        if let duration = m.duration {
            add(section("動画", [("撮影日", date), ("長さ", ExifFormat.duration(duration)),
                               ("フレーム", m.frameRate.map { String(format: "%.2f fps", $0) }), ("カメラ", m.cameraName)]))
        } else {
            add(section("撮影情報", [("撮影日", date), ("ISO", m.iso.map { "\($0)" }),
                                 ("F値", m.fNumber.map(ExifFormat.fNumber)),
                                 ("シャッター", m.exposureTime.map(ExifFormat.exposure)),
                                 ("焦点距離", m.focalLength.map(ExifFormat.focal)),
                                 ("カメラ", m.cameraName), ("レンズ", m.lensModel)]))
        }
        if let c = m.coordinate {
            var rows: [(String, String?)] = [("緯度", c.latitudeText), ("経度", c.longitudeText)]
            if let alt = m.altitude { rows.append(("高度", String(format: "%.1f m", alt))) }
            let box = section("位置情報", rows)
            box.addArrangedSubview(gpsButtons(c))
            add(box)
        } else {
            let box = section("位置情報", [])
            box.addArrangedSubview(Self.secondary("位置情報なし"))
            add(box)
        }
        let pixels: String? = {
            guard let w = m.pixelWidth, let h = m.pixelHeight else { return nil }
            return "\(w) × \(h)"
        }()
        add(section("ファイル", [("画素数", pixels), ("サイズ", ExifFormat.fileSize(item.fileSize)),
                              ("更新日", ExifFormat.dateFormatter.string(from: item.modificationDate)),
                              ("場所", item.url.deletingLastPathComponent().path)]))
    }

    private func add(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    static func label(_ s: String, font: NSFont = .systemFont(ofSize: 12), color: NSColor = .labelColor) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = font
        t.textColor = color
        t.lineBreakMode = .byTruncatingMiddle
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return t
    }

    static func secondary(_ s: String) -> NSTextField { label(s, color: .secondaryLabelColor) }

    /// 見出しと「項目名　値」の行
    private func section(_ title: String, _ rows: [(String, String?)]) -> NSStackView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 4
        box.addArrangedSubview(Self.label(title, font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor))
        for (name, value) in rows {
            let n = Self.label(name, color: .secondaryLabelColor)
            n.alignment = .right
            n.widthAnchor.constraint(equalToConstant: 64).isActive = true
            let v = Self.label(value ?? "-")
            v.isSelectable = true
            v.maximumNumberOfLines = 3
            let row = NSStackView(views: [n, v])
            row.alignment = .firstBaseline
            row.spacing = 8
            box.addArrangedSubview(row)
        }
        return box
    }

    // MARK: ★・現像済み

    private func tagEditor() -> NSView {
        let urls = targets
        let tags = urls.first.map { browser.tags(for: $0) } ?? .empty
        let mixedRating = Set(urls.map { browser.tags(for: $0).rating }).count > 1
        let allDeveloped = urls.allSatisfy { browser.tags(for: $0).developed }
        let anyDeveloped = urls.contains { browser.tags(for: $0).developed }

        let stars = NSStackView()
        stars.spacing = 2
        for n in 1...5 {
            let on = !mixedRating && tags.rating >= n
            let b = PreviewPane.iconButton(LegacyIcons.star(filled: on, color: on ? .systemYellow : .secondaryLabelColor),
                                           tip: "★\(n)（キー \(n)）")
            b.tag = n
            b.target = self
            b.action = #selector(starPressed(_:))
            stars.addArrangedSubview(b)
        }
        let reject = PreviewPane.iconButton(
            LegacyIcons.reject(color: !mixedRating && tags.rating == -1 ? .systemRed : .secondaryLabelColor),
            tip: "リジェクト（⌥⌫）")
        reject.target = self
        reject.action = #selector(rejectPressed)
        stars.addArrangedSubview(reject)
        stars.setCustomSpacing(8, after: stars.arrangedSubviews[4])
        if mixedRating { stars.addArrangedSubview(Self.secondary("（混在）")) }

        let developed = NSButton(checkboxWithTitle: "現像済み（キー D）", target: self, action: #selector(developedPressed(_:)))
        developed.allowsMixedState = true
        developed.state = allDeveloped ? .on : (anyDeveloped ? .mixed : .off)

        let box = NSStackView(views: [stars, developed])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6
        if urls.count > 1 { box.addArrangedSubview(Self.secondary("\(urls.count) 件にまとめて設定します")) }
        return box
    }

    @objc private func starPressed(_ sender: NSButton) {
        let urls = targets
        let tags = urls.first.map { browser.tags(for: $0) } ?? .empty
        let mixed = Set(urls.map { browser.tags(for: $0).rating }).count > 1
        // 同じ★をもう一度押すと解除
        browser.setRating(!mixed && tags.rating == sender.tag ? 0 : sender.tag, for: urls)
    }

    @objc private func rejectPressed() {
        let urls = targets
        let tags = urls.first.map { browser.tags(for: $0) } ?? .empty
        browser.setRating(tags.rating == -1 ? 0 : -1, for: urls)
    }

    @objc private func developedPressed(_ sender: NSButton) {
        let urls = targets
        let allDeveloped = urls.allSatisfy { browser.tags(for: $0).developed }
        browser.setDeveloped(!allDeveloped, for: urls)
    }

    // MARK: 位置情報のボタン

    private var coordinate: GPSCoordinate?

    private func gpsButtons(_ c: GPSCoordinate) -> NSView {
        coordinate = c
        let copy = NSPopUpButton(frame: .zero, pullsDown: true)
        copy.controlSize = .small
        copy.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        copy.addItem(withTitle: "コピー")
        for (title, tag) in [("緯度, 経度", 0), ("緯度のみ", 1), ("経度のみ", 2)] {
            copy.addItem(withTitle: title)
            copy.lastItem?.tag = tag
        }
        copy.target = self
        copy.action = #selector(copyPressed(_:))
        copy.toolTip = "緯度・経度をコピー"
        let google = NSButton(title: "Google マップ", target: self, action: #selector(openGoogle))
        let gsi = NSButton(title: "地理院地図", target: self, action: #selector(openGSI))
        for b in [google, gsi] {
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            b.bezelStyle = .rounded
        }
        let row = NSStackView(views: [copy, google, gsi])
        row.spacing = 6
        return row
    }

    @objc private func copyPressed(_ sender: NSPopUpButton) {
        guard let c = coordinate, let item = sender.selectedItem else { return }
        let text = [c.text, c.latitudeText, c.longitudeText][max(0, min(2, item.tag))]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openGoogle() {
        if let c = coordinate { NSWorkspace.shared.open(c.googleMapsURL) }
    }

    @objc private func openGSI() {
        if let c = coordinate { NSWorkspace.shared.open(c.gsiMapsURL()) }
    }
}

/// 上から並べるための、座標が上下反転したビュー（スクロールの中身に使う）
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
