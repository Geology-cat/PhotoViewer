import AppKit

/// グリッドの 1 セル（サムネイル＋ファイル名）
final class PhotoGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoGridItem")

    private(set) var representedURL: URL?
    private let thumbView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let selectionLayer = CALayer()
    /// 左下：★、右上：現像済みマーク
    private let ratingLabel = NSTextField(labelWithString: "")
    private let developedBadge = NSImageView()
    private var loadTask: Task<Void, Never>?
    private var showName = true

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        selectionLayer.cornerRadius = 6
        v.layer?.addSublayer(selectionLayer)

        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.imageAlignment = .alignCenter
        thumbView.wantsLayer = true
        v.addSubview(thumbView)

        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.textColor = .secondaryLabelColor
        v.addSubview(nameLabel)

        ratingLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        ratingLabel.textColor = .white
        ratingLabel.alignment = .center
        ratingLabel.wantsLayer = true
        ratingLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        ratingLabel.layer?.cornerRadius = 4
        ratingLabel.isHidden = true
        v.addSubview(ratingLabel)

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            .applying(.init(paletteColors: [.white, .systemGreen]))
        developedBadge.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "現像済み")?
            .withSymbolConfiguration(config)
        developedBadge.toolTip = "現像済み"
        developedBadge.isHidden = true
        v.addSubview(developedBadge)

        view = v
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let b = view.bounds
        let labelH = showName ? GridLayout.labelHeight : 0
        let inset: CGFloat = 4
        // NSView は左下原点
        nameLabel.frame = NSRect(x: 2, y: 2, width: b.width - 4, height: labelH - 4)
        thumbView.frame = NSRect(x: inset, y: labelH + inset, width: b.width - inset * 2,
                                 height: b.height - labelH - inset * 2)
        let ratingSize = ratingLabel.intrinsicContentSize
        ratingLabel.frame = NSRect(x: inset + 4, y: labelH + inset + 4,
                                   width: ratingSize.width + 8, height: ratingSize.height + 2)
        developedBadge.frame = NSRect(x: b.width - inset - 22, y: b.height - inset - 22, width: 18, height: 18)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.frame = b
        CATransaction.commit()
    }

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateSelectionAppearance() }
    }

    private func updateSelectionAppearance() {
        let on = isSelected || highlightState == .forSelection
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.backgroundColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : nil
        selectionLayer.borderColor = on ? NSColor.controlAccentColor.cgColor : nil
        selectionLayer.borderWidth = on ? 2 : 0
        CATransaction.commit()
        nameLabel.textColor = on ? .labelColor : .secondaryLabelColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        representedURL = nil
        thumbView.image = nil
    }

    /// ★と現像済みマークを更新する
    func updateBadges(_ tags: PhotoTags) {
        switch tags.rating {
        case 1...5:
            ratingLabel.stringValue = String(repeating: "★", count: tags.rating)
            ratingLabel.textColor = .systemYellow
            ratingLabel.isHidden = false
        case -1:
            ratingLabel.stringValue = "✕"
            ratingLabel.textColor = .systemRed
            ratingLabel.isHidden = false
        default:
            ratingLabel.isHidden = true
        }
        developedBadge.isHidden = !tags.developed
        view.needsLayout = true
    }

    func configure(_ photo: PhotoItem, pixelSize: Int, showName: Bool, tags: PhotoTags) {
        updateBadges(tags)
        let url = photo.url
        let sameURL = representedURL == url
        representedURL = url
        nameLabel.stringValue = photo.name
        nameLabel.isHidden = !showName
        if self.showName != showName {
            self.showName = showName
            view.needsLayout = true
        }
        updateSelectionAppearance()

        loadTask?.cancel()
        if let hit = ThumbnailLoader.shared.cached(url, pixelSize: pixelSize) {
            thumbView.image = NSImage(cgImage: hit, size: .zero)
            PerfLog.firstThumbnailShown()
            return
        }
        // 同じ画像の別サイズを読み直すときは、今の画像を残してちらつきを防ぐ
        if !sameURL { thumbView.image = nil }
        loadTask = Task { [weak self] in
            let image = await Self.loadThumbnail(url, pixelSize: pixelSize)
            guard !Task.isCancelled, let self, self.representedURL == url, let image else { return }
            self.thumbView.image = NSImage(cgImage: image, size: .zero)
            PerfLog.firstThumbnailShown()
        }
    }

    /// バックグラウンドでサムネイルを読む
    nonisolated private static func loadThumbnail(_ url: URL, pixelSize: Int) async -> CGImage? {
        if Task.isCancelled { return nil }
        return ThumbnailLoader.shared.load(url, pixelSize: pixelSize, allowFullDecode: false)
    }
}
