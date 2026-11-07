// Annotate.swift — 批注窗口：画布（画笔 / 矩形）+ 底部玻璃面板（说明 / 投递目标 / 发送）。
import AppKit

// MARK: - 批注模型

enum Mark { case pen([CGPoint]), rect(CGRect) }

final class Canvas: NSView {
    let image: NSImage
    let iw: CGFloat, ih: CGFloat
    var marks: [Mark] = []
    var tool = 0                    // 0 画笔 1 矩形
    var current: Mark?
    private var startPt = CGPoint.zero

    init(image: NSImage) {
        self.image = image
        let rep = image.representations.first
        iw = CGFloat(rep?.pixelsWide ?? Int(image.size.width))
        ih = CGFloat(rep?.pixelsHigh ?? Int(image.size.height))
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 浮层（工具条/底部面板）占用的留白；图片在其余区域内按比例居中显示。
    var insets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) { didSet { needsDisplay = true } }
    private var fitRect: CGRect {
        CGRect(x: insets.left, y: insets.bottom, width: max(bounds.width - insets.left - insets.right, 1),
               height: max(bounds.height - insets.top - insets.bottom, 1))
    }
    private var scale: CGFloat { min(fitRect.width / iw, fitRect.height / ih, 1.5 / (window?.backingScaleFactor ?? 2)) }   // 小截图最多放大到 1.5 倍原尺寸
    private var origin: CGPoint { CGPoint(x: fitRect.midX - iw * scale / 2, y: fitRect.midY - ih * scale / 2) }
    private let cornerRadius: CGFloat = 12
    private static let backdrop = NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.90, alpha: 1)
    }
    private var lineWidth: CGFloat { max(4, iw / 300) }

    /// 在“图片坐标系”里画图片和批注；预览与导出共用同一份代码。
    func drawContent() {
        image.draw(in: CGRect(x: 0, y: 0, width: iw, height: ih))
        NSColor(calibratedRed: 1, green: 0.17, blue: 0.17, alpha: 1).setStroke()
        for m in marks + (current.map { [$0] } ?? []) {
            let p = NSBezierPath()
            p.lineWidth = lineWidth; p.lineCapStyle = .round; p.lineJoinStyle = .round
            switch m {
            case .pen(let pts):
                guard let f = pts.first else { continue }
                p.move(to: f); pts.dropFirst().forEach { p.line(to: $0) }
                if pts.count == 1 { p.line(to: CGPoint(x: f.x + 0.1, y: f.y)) }
            case .rect(let r): p.appendRect(r)
            }
            p.stroke()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Canvas.backdrop.setFill(); bounds.fill()
        let imgRect = CGRect(x: origin.x, y: origin.y, width: iw * scale, height: ih * scale)
        let rounded = CGPath(roundedRect: imgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(NSColor.black.cgColor); ctx.addPath(rounded); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(rounded); ctx.clip()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: scale, y: scale)
        drawContent()
        ctx.restoreGState()
    }

    private func imagePoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: min(max((p.x - origin.x) / scale, 0), iw), y: min(max((p.y - origin.y) / scale, 0), ih))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with e: NSEvent) {
        startPt = imagePoint(e)
        current = tool == 0 ? .pen([startPt]) : .rect(CGRect(origin: startPt, size: .zero))
        needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        let p = imagePoint(e)
        if tool == 0, case .pen(var pts)? = current { pts.append(p); current = .pen(pts) }
        else { current = .rect(CGRect(x: min(startPt.x, p.x), y: min(startPt.y, p.y), width: abs(p.x - startPt.x), height: abs(p.y - startPt.y))) }
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) { if let c = current { marks.append(c) }; current = nil; needsDisplay = true }

    func undo() { if !marks.isEmpty { marks.removeLast(); needsDisplay = true } }
    func clear() { marks.removeAll(); needsDisplay = true }

    func exportPNG() -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(iw), pixelsHigh: Int(ih), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        drawContent()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// 带灰字占位提示的多行输入框。
final class PlaceholderTextView: NSTextView {
    private final class PassThroughLabel: NSTextField { override func hitTest(_ p: NSPoint) -> NSView? { nil } }
    private let hint = PassThroughLabel(labelWithString: "写点说明，会作为 prompt 发给 agent…")
    override var string: String { didSet { syncHint() } }
    var onChange: (() -> Void)?
    override func didChangeText() { super.didChangeText(); syncHint(); onChange?() }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard hint.superview == nil else { return }
        hint.textColor = .placeholderTextColor; hint.font = font ?? .systemFont(ofSize: 14)
        addSubview(hint); syncHint()
    }
    override func layout() {
        super.layout()
        hint.font = font ?? .systemFont(ofSize: 14)
        hint.sizeToFit()
        hint.frame.origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height)
    }
    private func syncHint() { hint.isHidden = !string.isEmpty; needsLayout = true }
}

// MARK: - 共用的玻璃与图标

enum UI {
    /// 玻璃容器：macOS 26 用 NSGlassEffectView，否则降级为 NSVisualEffectView。
    static func glass(_ content: NSView, radius: CGFloat, tint: NSColor? = nil) -> NSView {
        if #available(macOS 26, *) {
            let g = NSGlassEffectView(); g.cornerRadius = radius; g.tintColor = tint; g.contentView = content
            return g
        }
        let v = NSVisualEffectView()
        v.material = .hudWindow; v.blendingMode = .withinWindow; v.state = .active
        v.wantsLayer = true; v.layer?.cornerRadius = radius; v.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: v.leadingAnchor), content.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            content.topAnchor.constraint(equalTo: v.topAnchor), content.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        return v
    }
    static func symbol(_ name: String, _ size: CGFloat = 15, _ weight: NSFont.Weight = .medium, colors: [NSColor]? = nil) -> NSImage? {
        var cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        if let colors { cfg = cfg.applying(.init(paletteColors: colors)) }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }
}

// MARK: - 批注窗口

@MainActor
final class AnnotateController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let canvas: Canvas
    let note = PlaceholderTextView()
    let status = NSTextField(labelWithString: "")
    let chip = NSButton(title: "", target: nil, action: nil)
    let sendBtn = NSButton(title: "发送", target: nil, action: nil)
    let openBtn = NSButton(title: "打开线程", target: nil, action: nil)
    private(set) var destination: Destination?
    private var picker: PickerController?
    private var lastLink: URL?
    var onClose: (() -> Void)?
    var onSent: ((DeliveryResult) -> Void)?
    var isSending = false
    /// 常驻模式：按下发送窗口立刻收起，投递在后台进行，结果用右上角提示显示；失败时把窗口恢复。
    var dismissOnSend = false
    // Clef：看图给出候选排序。只预选 + 排序，不自动发送
    private(set) var suggestions: [ClefSuggestion] = []
    var userPicked = false
    private var clefLine = ""
    private var clefTask: Task<Void, Never>?
    private var clefDebounce: DispatchWorkItem?
    private var clefAsked = false

    init(image: NSImage) {
        canvas = Canvas(image: image)
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        build()
        note.onChange = { [weak self] in self?.noteChanged() }
        Directory.shared.onChange.append { [weak self] in self?.directoryChanged() }
        directoryChanged()
        if Directory.shared.loadedAt == nil || Date().timeIntervalSince(Directory.shared.loadedAt!) > 20 {
            Task { await Directory.shared.refresh() }
        }
    }

    func show() {
        window.center(); window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(note)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 布局

    private func iconButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton(image: UI.symbol(symbol) ?? NSImage(), target: self, action: action)
        b.isBordered = false; b.imagePosition = .imageOnly; b.toolTip = tip
        b.contentTintColor = .labelColor
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 34).isActive = true
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return b
    }

    private func buildToolbar() -> NSView {
        let barH: CGFloat = 46
        let seg = NSSegmentedControl(images: [UI.symbol("pencil"), UI.symbol("rectangle")].compactMap { $0 },
                                     trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:)))
        seg.selectedSegment = 0
        seg.setToolTip("画笔", forSegment: 0); seg.setToolTip("矩形", forSegment: 1)
        seg.setWidth(44, forSegment: 0); seg.setWidth(44, forSegment: 1)
        seg.controlSize = .large
        if #available(macOS 26, *) { seg.borderShape = .capsule }
        let segBox = NSStackView(views: [seg]); segBox.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        let actBox = NSStackView(views: [iconButton("arrow.uturn.backward", tip: "撤销  ⌘Z", action: #selector(undo)),
                                         iconButton("trash", tip: "清除全部批注", action: #selector(clearAll))])
        actBox.spacing = 2; actBox.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        [segBox, actBox].forEach { $0.alignment = .centerY; $0.layoutSubtreeIfNeeded() }
        let wA = segBox.fittingSize.width, wB = actBox.fittingSize.width
        segBox.frame = NSRect(x: 0, y: 0, width: wA, height: barH)
        actBox.frame = NSRect(x: 0, y: 0, width: wB, height: barH)
        let pillA = UI.glass(segBox, radius: barH / 2), pillB = UI.glass(actBox, radius: barH / 2)
        let gap: CGFloat = 10
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: wA + gap + wB, height: barH))
        pillA.frame = NSRect(x: 0, y: 0, width: wA, height: barH)
        pillB.frame = NSRect(x: wA + gap, y: 0, width: wB, height: barH)
        holder.addSubview(pillA); holder.addSubview(pillB)
        let outer: NSView
        if #available(macOS 26, *) { let c = NSGlassEffectContainerView(); c.spacing = 24; c.contentView = holder; outer = c } else { outer = holder }
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.widthAnchor.constraint(equalToConstant: holder.frame.width).isActive = true
        outer.heightAnchor.constraint(equalToConstant: barH).isActive = true
        return outer
    }

    /// 底部面板。第一层只有三样东西：说明、一个「投递目标」胶囊、发送。目标的细节都收在胶囊后面（⌘K）。
    private func buildPanel(height: CGFloat) -> NSView {
        note.isRichText = false; note.font = .systemFont(ofSize: 14); note.isAutomaticQuoteSubstitutionEnabled = false
        note.drawsBackground = false; note.textColor = .labelColor
        note.textContainerInset = NSSize(width: 2, height: 2)
        note.isVerticallyResizable = true; note.isHorizontallyResizable = false
        note.autoresizingMask = [.width]; note.textContainer?.widthTracksTextView = true
        let sv = NSScrollView(); sv.documentView = note; sv.hasVerticalScroller = true; sv.autohidesScrollers = true
        sv.drawsBackground = false; sv.borderType = .noBorder
        sv.translatesAutoresizingMaskIntoConstraints = false
        let hair = NSBox(); hair.boxType = .separator; hair.translatesAutoresizingMaskIntoConstraints = false

        chip.target = self; chip.action = #selector(openPicker)
        chip.imagePosition = .imageLeading; chip.lineBreakMode = .byTruncatingTail
        chip.toolTip = "选择投递目标  ⌘K"
        if #available(macOS 26, *) { chip.bezelStyle = .glass; chip.borderShape = .capsule } else { chip.bezelStyle = .rounded }
        chip.controlSize = .large
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.setContentCompressionResistancePriority(.init(700), for: .horizontal)

        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail; status.maximumNumberOfLines = 1
        status.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        status.setContentHuggingPriority(.init(1), for: .horizontal)
        status.translatesAutoresizingMaskIntoConstraints = false

        openBtn.target = self; openBtn.action = #selector(openThread)
        openBtn.image = UI.symbol("arrow.up.forward.app", 13); openBtn.imagePosition = .imageLeading
        if #available(macOS 26, *) { openBtn.bezelStyle = .glass; openBtn.borderShape = .capsule } else { openBtn.bezelStyle = .rounded }
        openBtn.isHidden = true; openBtn.translatesAutoresizingMaskIntoConstraints = false

        sendBtn.target = self; sendBtn.action = #selector(send)
        sendBtn.keyEquivalent = "\r"; sendBtn.keyEquivalentModifierMask = .command
        sendBtn.image = UI.symbol("paperplane.fill"); sendBtn.imagePosition = .imageLeading
        sendBtn.toolTip = "发送  ⌘↵"
        if #available(macOS 26, *) {
            sendBtn.bezelStyle = .glass; sendBtn.borderShape = .capsule
            sendBtn.tintProminence = .primary; sendBtn.bezelColor = .controlAccentColor
        } else { sendBtn.bezelStyle = .rounded; sendBtn.bezelColor = .controlAccentColor }
        sendBtn.controlSize = .large
        sendBtn.translatesAutoresizingMaskIntoConstraints = false

        let pc = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: height))
        [sv, hair, chip, status, openBtn, sendBtn].forEach { pc.addSubview($0) }
        let pad: CGFloat = 18
        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: pc.topAnchor, constant: 12),
            sv.leadingAnchor.constraint(equalTo: pc.leadingAnchor, constant: pad),
            sv.trailingAnchor.constraint(equalTo: pc.trailingAnchor, constant: -pad),
            sv.heightAnchor.constraint(equalToConstant: 58),
            hair.topAnchor.constraint(equalTo: sv.bottomAnchor, constant: 8),
            hair.leadingAnchor.constraint(equalTo: pc.leadingAnchor, constant: pad),
            hair.trailingAnchor.constraint(equalTo: pc.trailingAnchor, constant: -pad),
            chip.leadingAnchor.constraint(equalTo: pc.leadingAnchor, constant: pad - 4),
            chip.bottomAnchor.constraint(equalTo: pc.bottomAnchor, constant: -12),
            chip.widthAnchor.constraint(lessThanOrEqualToConstant: 330),
            status.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: openBtn.leadingAnchor, constant: -10),
            status.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            openBtn.trailingAnchor.constraint(equalTo: sendBtn.leadingAnchor, constant: -8),
            openBtn.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            sendBtn.trailingAnchor.constraint(equalTo: pc.trailingAnchor, constant: -14),
            sendBtn.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
        ])
        return pc
    }

    private func build() {
        let panelH: CGFloat = 132, toolbarTop: CGFloat = 8, barH: CGFloat = 46, m: CGFloat = 16
        let topInset = toolbarTop + barH + 12, bottomInset = m + panelH + 12
        canvas.insets = NSEdgeInsets(top: topInset, left: 24, bottom: bottomInset, right: 24)
        let root = NSView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: root.topAnchor), canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        let toolbar = buildToolbar()
        root.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: toolbarTop),
        ])
        let panel = UI.glass(buildPanel(height: panelH), radius: 24)
        panel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(panel)
        let fillW = panel.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -2 * m); fillW.priority = .init(750)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            panel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -m),
            panel.heightAnchor.constraint(equalToConstant: panelH),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 820),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: m),
            fillW,
        ])
        // 窗口大小：按截图比例（最多 1.5 倍原尺寸），不小于 900x620，不超过屏幕可视区 90%
        let vis = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1400, height: 900)
        let px = NSScreen.main?.backingScaleFactor ?? 2
        let w = min(max(canvas.iw * 1.5 / px + 48, 900), vis.width * 0.9)
        let fitH = min((w - 48) * canvas.ih / canvas.iw, canvas.ih * 1.5 / px)
        let h = min(max(fitH + topInset + bottomInset, 620), vis.height * 0.9)
        window.setContentSize(NSSize(width: w, height: h))
        window.title = "T3Shot — 批注并投递"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.contentView = root
        window.isReleasedWhenClosed = false
        window.delegate = self
        switch ProcessInfo.processInfo.environment["T3SHOT_APPEARANCE"] {
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        case "light": window.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    func windowWillClose(_ n: Notification) { picker?.close(); onClose?() }

    // MARK: 目标

    private func directoryChanged() {
        defer { if !clefAsked, Directory.shared.loadedAt != nil { askClef() } }
        let all = Directory.shared.destinations
        if let d = destination, let fresh = all.first(where: { $0.key == d.key }) { setDestination(fresh, remember: false); return }
        if destination != nil, Directory.shared.loadedAt != nil, !all.contains(where: { $0.key == destination!.key }) { destination = nil }
        if destination == nil {
            let last = UserDefaults.standard.string(forKey: "lastDestination")
            if let d = all.first(where: { $0.key == last }) ?? all.first(where: { $0.isNew && !$0.needsSetup }) ?? all.first(where: { !$0.needsSetup }) ?? all.first { setDestination(d, remember: false); return }
        }
        if destination == nil { renderChip() }
    }

    func setDestination(_ d: Destination, remember: Bool = true) {
        destination = d
        if remember { UserDefaults.standard.set(d.key, forKey: "lastDestination") }
        renderChip()
    }

    /// 胶囊上只放「去哪」：类型图标 + 名字；投递语义（新建 / 排队跟进 / 立即开始）在选中后才出现在提示行和按钮上。
    private func renderChip() {
        guard let d = destination else {
            let loading = Directory.shared.loadedAt == nil
            chip.title = loading ? "正在读取 T3…" : "没有可投递的目标"
            chip.image = UI.symbol(loading ? "ellipsis" : "exclamationmark.triangle", 13)
            sendBtn.isEnabled = false
            if !loading { setStatus(Directory.shared.envs.isEmpty ? "未配对任何 T3 环境：T3Shot --pair <地址> <配对码>" : "各环境都没有 webhook 任务或未 settle 的线程", error: true) }
            return
        }
        sendBtn.isEnabled = !isSending
        let envShort = d.env.label.replacingOccurrences(of: "（本机）", with: "").replacingOccurrences(of: "（经链接）", with: "")
        if d.needsSetup {
            chip.image = UI.symbol("plus.circle.dashed", 13)
            chip.title = "新线程 · \(d.title)（首次）" + clefBadge(d)
            sendBtn.title = "启用并新建"
            hint("首次投递：先在 \(envShort) 的「\(d.project)」创建 scheduler webhook 入口，再新建线程")
        } else if d.isNew {
            chip.image = UI.symbol("plus.bubble", 13)
            chip.title = "新线程 · \(d.title)" + clefBadge(d)
            sendBtn.title = "新建线程"
            hint("经 \(envShort) 的 scheduler webhook 在「\(d.project)」新建线程")
        } else {
            chip.image = UI.symbol("circle.fill", 9, colors: [d.isActive ? .systemGreen : .tertiaryLabelColor])
            chip.title = "\(d.isActive ? "跟进" : "继续") · \(d.title)" + clefBadge(d)
            sendBtn.title = d.isActive ? "排队跟进" : "发送"
            hint(d.isActive ? "\(d.statusText)：作为下一轮 follow-up 排队，不打断当前任务" : "线程空闲：立即开始新一轮" + (d.env.direct ? "" : "（经链接，仅文字）"))
        }
        chip.toolTip = "\(d.isNew ? "新线程" : d.statusText) · \(d.env.label)\(d.project.isEmpty ? "" : " · \(d.project)")\n选择投递目标  ⌘K"
    }

    private func hint(_ s: String) { if !isSending && lastLink == nil { setStatus(clefLine.isEmpty ? s : clefLine + " · " + s) } }

    func setStatus(_ s: String, error: Bool = false, ok: Bool = false) {
        status.stringValue = s; status.toolTip = s
        status.textColor = error ? .systemRed : (ok ? .systemGreen : .secondaryLabelColor)
    }

    @objc func openPicker() {
        if let p = picker, p.isShown { p.close(); return }
        let p = PickerController(current: destination, suggestions: suggestions) { [weak self] d in
            self?.userPicked = true      // 人选了就不再被 Clef 的结果覆盖
            self?.setDestination(d); self?.window.makeFirstResponder(self?.note)
        }
        picker = p
        p.show(relativeTo: chip)
    }
    var pickerController: PickerController? { picker }

    // MARK: 动作

    @objc func toolChanged(_ s: NSSegmentedControl) { canvas.tool = s.selectedSegment }
    @objc func undo() { canvas.undo() }
    @objc func clearAll() { canvas.clear() }
    @objc func openThread() {
        guard let u = lastLink else { return }
        T3Open.open(u)
    }

    @objc func send() {
        guard let d = destination, !isSending else { return }
        guard let png = canvas.exportPNG() else { setStatus("导出图片失败", error: true); return }
        let dir = URL(fileURLWithPath: NSString(string: "~/.t3shot/shots").expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "shot-\(f.string(from: Date())).png"
        try? png.write(to: dir.appendingPathComponent(name))
        UserDefaults.standard.set(d.key, forKey: "lastDestination")
        isSending = true; sendBtn.isEnabled = false; chip.isEnabled = false
        lastLink = nil; openBtn.isHidden = true
        setStatus(d.needsSetup ? "创建 webhook 入口、上传截图…" : d.isNew ? "上传截图、触发 webhook…" : "上传截图、投递到线程…")
        let text = note.string
        if dismissOnSend { return sendInBackground(d, text: text, png: png, name: name) }
        Task { @MainActor in
            do {
                let r = try await Delivery.deliver(d, note: text, png: png, fileName: name)
                isSending = false; chip.isEnabled = true; sendBtn.isEnabled = true
                lastLink = r.link; openBtn.isHidden = r.link == nil
                setStatus("✓ " + r.message, ok: true)
                print("OK: \(r.message) \(r.link?.absoluteString ?? "")")
                onSent?(r)
                Task { await Directory.shared.refresh() }
            } catch {
                isSending = false; chip.isEnabled = true; sendBtn.isEnabled = true
                setStatus("投递失败：\(error.localizedDescription)", error: true)
                print("ERR: \(error.localizedDescription)")
            }
        }
    }
}

extension AnnotateController {
    /// 窗口立刻收起；投递、等线程创建都在后台，进度和结果走 Toast。失败时窗口原样回来，说明和批注都还在。
    func sendInBackground(_ d: Destination, text: String, png: Data, name: String) {
        window.orderOut(nil)
        let envShort = d.env.label.replacingOccurrences(of: "（本机）", with: "").replacingOccurrences(of: "（经链接）", with: "")
        let target = d.isNew ? "新线程 · \(d.project)" : "「\(d.title)」"
        Toast.shared.show(.working, d.needsSetup ? "正在创建入口并投递…" : "正在投递…", detail: "\(target) · \(envShort)")
        Task { @MainActor in
            do {
                let r = try await Delivery.deliver(d, note: text, png: png, fileName: name, waitForThread: false)
                print("OK: \(r.message) \(r.link?.absoluteString ?? "")")
                isSending = false
                onSent?(r)
                window.close()                    // 成功后才真正关掉窗口（之前只是隐藏）
                Task { await Directory.shared.refresh() }
                if let lookup = r.pendingLookup {
                    // 新线程：先告诉已投递，线程建好后再换成可点击的提示
                    Toast.shared.show(.ok, "已投递到「\(d.project)」", detail: "正在创建线程… · \(envShort)", hideAfter: 30)
                    if let found = await lookup() {
                        let link = found.0
                        Toast.shared.show(.ok, "已新建线程「\(found.1)」", detail: "\(d.project) · \(envShort)", actionTitle: "打开") { T3Open.open(link) }
                    } else {
                        Toast.shared.show(.ok, "已投递到「\(d.project)」", detail: "线程还在创建，稍后在 T3 里查看 · \(envShort)")
                    }
                } else {
                    let link = r.link
                    Toast.shared.show(.ok, d.isActive ? "已排队为下一轮 follow-up" : "已发送，线程开始新一轮",
                                      detail: "\(target) · \(envShort)", actionTitle: link == nil ? nil : "打开") { if let link { T3Open.open(link) } }
                }
            } catch {
                print("ERR: \(error.localizedDescription)")
                isSending = false; chip.isEnabled = true; sendBtn.isEnabled = true
                setStatus("投递失败：\(error.localizedDescription)", error: true)
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                Toast.shared.show(.error, "投递失败，窗口已恢复", detail: error.localizedDescription, hideAfter: 8)
            }
        }
    }
}

enum T3Open {
    /// 优先在 T3 Code 桌面端打开线程链接，没有装就交给默认浏览器。
    static func open(_ u: URL) {
        let ws = NSWorkspace.shared
        if let app = ws.urlForApplication(withBundleIdentifier: "com.t3tools.t3code") {
            ws.open([u], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else { ws.open(u) }
    }
}

// MARK: - Clef：看图给出候选排序（只预选，不自动发送）

extension AnnotateController {
    /// 胶囊上的 ✨ 概率标记：这个目标是 Clef 排出来的候选之一
    func clefBadge(_ d: Destination) -> String {
        guard let s = suggestions.first(where: { $0.dest.key == d.key }) else { return "" }
        return "  ✨\(Int((s.probability * 100).rounded()))%"
    }

    /// 说明改动后 1.5 秒再重新判断一次（说明往往决定了这张图是给哪个线程的）
    func noteChanged() {
        guard Clef.isConfigured, clefAsked else { return }
        clefDebounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.askClef() }
        clefDebounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    func askClef() {
        guard Clef.isConfigured, !isSending else { return }
        clefAsked = true
        let cands = Clef.candidates(from: Directory.shared.destinations)
        guard !cands.isEmpty, let png = canvas.exportPNG() else { return }
        let text = note.string
        clefTask?.cancel()
        clefLine = "✨ Clef 正在看图判断…"; renderChip()
        clefTask = Task { @MainActor in
            do {
                let r = try await Clef.rank(png: png, note: text, candidates: cands)
                if Task.isCancelled { return }
                applyClef(r)
            } catch {
                if Task.isCancelled { return }
                print("CLEF ERR: \(error.localizedDescription)")
                clefLine = "✨ Clef 不可用：\(error.localizedDescription)"; renderChip()
            }
        }
    }

    private func applyClef(_ r: ClefResult) {
        suggestions = r.ranked
        pickerController?.update(suggestions: r.ranked)
        print("CLEF: " + r.ranked.prefix(5).map { "\(Int($0.probability * 100))% \($0.dest.isNew ? "新·" : "")\($0.dest.title)" }.joined(separator: " | ") + " | none \(Int(r.noneProbability * 100))%")
        guard let top = r.top else { clefLine = "✨ Clef：没有合适的候选"; renderChip(); return }
        let pct = Int((top.probability * 100).rounded())
        let name = top.dest.isNew ? "新线程·\(top.dest.title)" : top.dest.title
        if top.probability < Clef.preselectThreshold {
            clefLine = "✨ Clef 拿不准（最高 \(pct)%），⌘K 看候选排序"
            renderChip()
        } else if userPicked {
            clefLine = top.dest.key == destination?.key ? "✨ Clef 也推荐这个 \(pct)%" : "✨ Clef 首选「\(name)」\(pct)%"
            renderChip()
        } else {
            clefLine = "✨ Clef 建议 \(pct)%，确认后发送"
            let fresh = Directory.shared.destinations.first { $0.key == top.dest.key } ?? top.dest
            setDestination(fresh, remember: false)     // 内部会 renderChip
        }
    }
}
