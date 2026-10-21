import AppKit
import AVKit

/// 画像を描く部分：枠に合わせて表示し、クリックで拡大・拡大中はドラッグで移動、90° 回転（通常版の ZoomableImage と同じ動き）
final class ZoomImageView: NSView {
    /// 枠に合わせて読み込んだ画像
    var image: NSImage? { didSet { needsDisplay = true } }
    /// 拡大用に読み直した高解像度の画像
    var detail: NSImage? { didSet { needsDisplay = true } }
    var rotation = 0 {
        didSet {
            guard rotation != oldValue else { return }
            zoomed = false
            offset = .zero
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    /// 元の画像の長辺のピクセル数（撮影情報から。分かるまでは読み込んだ画像の大きさを使う）
    var originalLongSide: CGFloat?
    /// 拡大に解像度が足りないときに呼ぶ（必要なピクセル数）
    var onNeedDetail: ((Int) -> Void)?

    private(set) var zoomed = false
    private var offset: CGSize = .zero
    private var dragStart: (point: NSPoint, offset: CGSize)?
    private var isDragging = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    private var zoomPercent: Int {
        let v = UserDefaults.standard.integer(forKey: PreviewSettings.zoomPercentKey)
        return v > 0 ? v : PreviewSettings.defaultZoomPercent
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private var fitSize: CGSize {
        guard let image else { return .zero }
        return ZoomGeometry.fittedSize(image.size, rotation: rotation, in: bounds.size)
    }

    private var zoomSize: CGSize {
        guard let image else { return .zero }
        return ZoomGeometry.zoomSize(fit: fitSize, originalLongSide: originalLongSide ?? max(image.size.width, image.size.height),
                                     percent: zoomPercent, displayScale: scale)
    }

    private var displaySize: CGSize { zoomed ? zoomSize : fitSize }

    /// 別の写真に変わったときに全体表示に戻す
    func reset() {
        zoomed = false
        offset = .zero
        detail = nil
        originalLongSide = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        offset = clamped(offset)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let img = detail ?? image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = displaySize
        guard size.width > 0, size.height > 0 else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: bounds.midX + offset.width, y: bounds.midY + offset.height)
        ctx.rotate(by: CGFloat(rotation) * .pi / 180)
        img.draw(in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        ctx.restoreGState()
    }

    // MARK: マウス

    override func resetCursorRects() {
        guard image != nil else { return }
        addCursorRect(bounds, cursor: zoomed ? (isDragging ? .closedHand : .openHand) : Self.zoomInCursor)
    }

    /// 虫めがねのカーソル（10.12 には拡大用のカーソルがないので描く）
    private static let zoomInCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let lens = NSRect(x: 1.5, y: 5.5, width: 11, height: 11)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: lens.insetBy(dx: -1, dy: -1)).fill()
            NSColor.black.setStroke()
            let ring = NSBezierPath(ovalIn: lens)
            ring.lineWidth = 1.6
            ring.stroke()
            let plus = NSBezierPath()
            plus.move(to: NSPoint(x: lens.midX - 3, y: lens.midY)); plus.line(to: NSPoint(x: lens.midX + 3, y: lens.midY))
            plus.move(to: NSPoint(x: lens.midX, y: lens.midY - 3)); plus.line(to: NSPoint(x: lens.midX, y: lens.midY + 3))
            plus.lineWidth = 1.4
            plus.stroke()
            let handle = NSBezierPath()
            handle.move(to: NSPoint(x: lens.maxX - 1.5, y: lens.minY + 1.5))
            handle.line(to: NSPoint(x: r.maxX - 1.5, y: 1.5))
            handle.lineWidth = 2.6
            handle.lineCapStyle = .round
            handle.stroke()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 7, y: 7))
    }()

    override func mouseDown(with event: NSEvent) {
        dragStart = (convert(event.locationInWindow, from: nil), offset)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard zoomed, let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - start.point.x, dy = p.y - start.point.y
        if !isDragging && hypot(dx, dy) > 3 {
            isDragging = true
            NSCursor.closedHand.set()
        }
        guard isDragging else { return }
        offset = clamped(CGSize(width: start.offset.width + dx, height: start.offset.height + dy))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = isDragging
        dragStart = nil
        isDragging = false
        if wasDragging {
            window?.invalidateCursorRects(for: self)
            return
        }
        toggleZoom(at: convert(event.locationInWindow, from: nil))
    }

    private func toggleZoom(at point: NSPoint) {
        guard image != nil else { return }
        if zoomed {
            zoomed = false
            offset = .zero
        } else {
            let target = ZoomGeometry.offsetKeeping(point, in: bounds.size, fit: fitSize, zoom: zoomSize)
            zoomed = true
            offset = clamped(target)
            requestDetailIfNeeded()
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func clamped(_ o: CGSize) -> CGSize {
        ZoomGeometry.clamp(o, size: displaySize, rotation: rotation, in: bounds.size)
    }

    private func requestDetailIfNeeded() {
        guard detail == nil, let image else { return }
        let needed = Int(max(zoomSize.width, zoomSize.height) * scale)
        let original = Int(originalLongSide ?? 0)
        let target = min(original > 0 ? min(needed, original) : needed, 16384)
        let current = Int(max(image.size.width, image.size.height))
        if target > current + current / 20 { onNeedDetail?(target) }
    }
}

/// 右上：選択中の画像のプレビュー（動画はその場で再生できる）
final class PreviewPane: NSView {
    private let browser = BrowserModel.shared
    private let imageView = ZoomImageView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let rotateBox = NSView()
    private var playerView: AVPlayerView?

    private var item: PhotoItem?
    private var loadedURL: URL?
    private var requests: [LoadRequest] = []
    private var lastPixel = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.textColor = .secondaryLabelColor
        addSubview(messageLabel)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        // 右下の「左に 90° 回転」「右に 90° 回転」
        rotateBox.wantsLayer = true
        rotateBox.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        rotateBox.layer?.cornerRadius = 12
        rotateBox.translatesAutoresizingMaskIntoConstraints = false
        let left = Self.iconButton(LegacyIcons.rotate(clockwise: false), tip: "左に 90° 回転（⌥⌘←）")
        left.target = self; left.action = #selector(rotateLeft)
        let right = Self.iconButton(LegacyIcons.rotate(clockwise: true), tip: "右に 90° 回転（⌥⌘→）")
        right.target = self; right.action = #selector(rotateRight)
        let stack = NSStackView(views: [left, right])
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        rotateBox.addSubview(stack)
        addSubview(rotateBox)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: rotateBox.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: rotateBox.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: rotateBox.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: rotateBox.bottomAnchor, constant: -3),
            rotateBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            rotateBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])

        imageView.onNeedDetail = { [weak self] pixel in self?.loadDetail(pixel) }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(selectionChanged), name: .browserSelectionChanged, object: browser)
        nc.addObserver(self, selector: #selector(rotationChanged), name: .browserRotationChanged, object: browser)
        update()
    }

    required init?(coder: NSCoder) { fatalError("未対応") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        requests.forEach { $0.cancel() }
    }

    static func iconButton(_ image: NSImage, tip: String) -> NSButton {
        let b = NSButton(image: image, target: nil, action: nil)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.toolTip = tip
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return b
    }

    @objc private func rotateLeft() {
        if let u = item?.url { browser.rotatePreview(u, by: -90) }
    }

    @objc private func rotateRight() {
        if let u = item?.url { browser.rotatePreview(u, by: 90) }
    }

    @objc private func rotationChanged() {
        guard let u = item?.url else { return }
        imageView.rotation = browser.previewRotation[u] ?? 0
    }

    @objc private func selectionChanged() {
        if browser.primaryItem != item || item == nil { update() }
        if item == nil { updateMessage() }
    }

    private func updateMessage() {
        let count = browser.selection.count
        messageLabel.stringValue = count > 1 ? "\(count) 件を選択中" : "画像を選択してください"
    }

    /// 表示する写真が変わった
    private func update() {
        let newItem = browser.primaryItem
        item = newItem
        requests.forEach { $0.cancel() }
        requests = []
        spinner.stopAnimation(nil)
        imageView.reset()

        // 動画はその場で再生できるようにする（自動では再生しない）
        if let v = newItem, v.isVideo {
            showVideo(v.url)
            return
        }
        hideVideo()
        guard let newItem else {
            imageView.image = nil
            loadedURL = nil
            messageLabel.isHidden = false
            rotateBox.isHidden = true
            updateMessage()
            return
        }
        messageLabel.isHidden = true
        rotateBox.isHidden = false
        imageView.rotation = browser.previewRotation[newItem.url] ?? 0
        if loadedURL != newItem.url { imageView.image = nil }
        loadImage()
        browser.metadata(for: newItem.url) { [weak self] m in
            guard let self = self, self.item?.url == newItem.url,
                  let w = m.pixelWidth, let h = m.pixelHeight, w > 0, h > 0 else { return }
            self.imageView.originalLongSide = CGFloat(max(w, h))
        }
    }

    /// 枠の大きさに合った画像を読む（先にグリッド用の小さい画像、大きなファイルは中くらいの画像を出す）
    private func loadImage() {
        guard let item, !item.isVideo else { return }
        let url = item.url
        let scale = window?.backingScaleFactor ?? 2
        let pixel = ThumbnailLoader.bucket(for: Int(max(bounds.width, bounds.height) * scale))
        lastPixel = pixel
        if let hit = ThumbnailLoader.shared.cached(url, pixelSize: pixel) {
            imageView.image = NSImage(cgImage: hit, size: .zero)
            loadedURL = url
            return
        }
        if loadedURL != url, let small = ThumbnailLoader.shared.cached(url, pixelSize: 512)
            ?? ThumbnailLoader.shared.cached(url, pixelSize: 256) {
            imageView.image = NSImage(cgImage: small, size: .zero)
            loadedURL = url
        }
        spinner.startAnimation(nil)
        let show: (CGImage?) -> Void = { [weak self] cg in
            guard let self = self, self.item?.url == url, let cg else { return }
            self.imageView.image = NSImage(cgImage: cg, size: .zero)
            self.loadedURL = url
        }
        if item.fileSize >= ThumbnailLoader.largeFileThreshold, pixel > 768,
           ThumbnailLoader.shared.cached(url, pixelSize: 768) == nil {
            requests.append(ThumbnailLoader.shared.request(url, pixelSize: 768, allowFullDecode: true, completion: show))
        }
        requests.append(ThumbnailLoader.shared.request(url, pixelSize: pixel, allowFullDecode: true) { [weak self] cg in
            show(cg)
            self?.spinner.stopAnimation(nil)
            if cg == nil, self?.item?.url == url, self?.imageView.image == nil {
                self?.messageLabel.stringValue = "この形式は表示できません"
                self?.messageLabel.isHidden = false
            }
        })
    }

    private func loadDetail(_ pixel: Int) {
        guard let url = item?.url else { return }
        requests.append(ThumbnailLoader.requestDetail(url, maxPixel: pixel) { [weak self] cg in
            guard let self = self, self.item?.url == url, let cg else { return }
            self.imageView.detail = NSImage(cgImage: cg, size: .zero)
        })
    }

    /// 大きさが別の段階に変わったら読み直す
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let item, !item.isVideo, !inLiveResize else { return }
        let scale = window?.backingScaleFactor ?? 2
        if ThumbnailLoader.bucket(for: Int(max(newSize.width, newSize.height) * scale)) != lastPixel { loadImage() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        setFrameSize(frame.size)
    }

    // MARK: 動画

    private func showVideo(_ url: URL) {
        imageView.isHidden = true
        rotateBox.isHidden = true
        messageLabel.isHidden = true
        if let pv = playerView, (pv.player?.currentItem?.asset as? AVURLAsset)?.url == url { return }
        playerView?.player?.pause()
        playerView?.removeFromSuperview()
        let pv = AVPlayerView()
        pv.controlsStyle = .inline
        pv.videoGravity = .resizeAspect
        pv.showsFullScreenToggleButton = true
        pv.player = AVPlayer(url: url)
        pv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pv)
        NSLayoutConstraint.activate([
            pv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pv.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            pv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        playerView = pv
    }

    private func hideVideo() {
        imageView.isHidden = false
        playerView?.player?.pause()
        playerView?.player = nil
        playerView?.removeFromSuperview()
        playerView = nil
    }
}
