import AppKit

/// 選択の強調色（controlAccentColor は 10.14 以降）
var accentColor: NSColor {
    if #available(macOS 10.14, *) { return .controlAccentColor }
    return .alternateSelectedControlColor
}

/// グリッドの 1 セル（サムネイル＋ファイル名）。通常版の PhotoGridItem と同じ見た目
final class PhotoGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoGridItem")

    private(set) var representedURL: URL?
    private let thumbView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let selectionLayer = CALayer()
    /// 左下：★、右上：現像済みマーク、右下：動画の印
    private let ratingLabel = NSTextField(labelWithString: "")
    private let developedBadge = NSImageView()
    private let videoBadge = NSImageView()
    private var loadRequest: LoadRequest?
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
        ratingLabel.drawsBackground = false
        ratingLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        ratingLabel.layer?.cornerRadius = 4
        ratingLabel.isHidden = true
        v.addSubview(ratingLabel)

        developedBadge.image = LegacyIcons.developedBadge
        developedBadge.toolTip = "現像済み"
        developedBadge.isHidden = true
        v.addSubview(developedBadge)

        videoBadge.image = LegacyIcons.videoBadge
        videoBadge.toolTip = "動画"
        videoBadge.isHidden = true
        v.addSubview(videoBadge)

        view = v
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let b = view.bounds
        let labelH = showName ? GridLayout.labelHeight : 0
        let inset: CGFloat = 4
        nameLabel.frame = NSRect(x: 2, y: 2, width: b.width - 4, height: max(labelH - 4, 0))
        thumbView.frame = NSRect(x: inset, y: labelH + inset, width: b.width - inset * 2,
                                 height: b.height - labelH - inset * 2)
        let ratingSize = ratingLabel.intrinsicContentSize
        ratingLabel.frame = NSRect(x: inset + 4, y: labelH + inset + 4,
                                   width: ratingSize.width + 8, height: ratingSize.height + 2)
        developedBadge.frame = NSRect(x: b.width - inset - 22, y: b.height - inset - 22, width: 18, height: 18)
        videoBadge.frame = NSRect(x: b.width - inset - 26, y: labelH + inset + 4, width: 22, height: 22)
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
        selectionLayer.backgroundColor = on ? accentColor.withAlphaComponent(0.25).cgColor : nil
        selectionLayer.borderColor = on ? accentColor.cgColor : nil
        selectionLayer.borderWidth = on ? 2 : 0
        CATransaction.commit()
        nameLabel.textColor = on ? .labelColor : .secondaryLabelColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadRequest?.cancel()
        loadRequest = nil
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
        videoBadge.isHidden = !photo.isVideo
        if self.showName != showName {
            self.showName = showName
            view.needsLayout = true
        }
        updateSelectionAppearance()

        loadRequest?.cancel()
        if let hit = ThumbnailLoader.shared.cached(url, pixelSize: pixelSize) {
            thumbView.image = NSImage(cgImage: hit, size: .zero)
            return
        }
        // 同じ画像の別サイズを読み直すときは、今の画像を残してちらつきを防ぐ
        if !sameURL { thumbView.image = nil }
        loadRequest = ThumbnailLoader.shared.request(url, pixelSize: pixelSize, allowFullDecode: false) { [weak self] image in
            guard let self = self, self.representedURL == url else { return }
            if let image {
                self.thumbView.image = NSImage(cgImage: image, size: .zero)
            } else if !sameURL {
                // OS が読めない形式（HEIC・CR3 など）はファイルの種類のアイコンを出す
                self.thumbView.image = NSWorkspace.shared.icon(forFileType: photo.ext)
            }
        }
    }
}
