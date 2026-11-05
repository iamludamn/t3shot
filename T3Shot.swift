// T3Shot — 原生 macOS 截图批注工具：截图 → 批注 → 发送到 T3 webhook。
// 编译：见 build.sh。配置：~/.config/t3shot/targets.json
import AppKit
import CryptoKit

// MARK: - 配置

struct Target {
    var name: String
    var url: String
    var sigHeader: String?, sigEncoding = "hex", sigPrefix = "", sigSecret: String?
    var scp: String?   // 例如 "user@omarchy:/home/user/.t3shot/"：发送前先把图片 scp 过去

    static func loadAll() -> [Target] {
        let path = NSString(string: "~/.config/t3shot/targets.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let name = d["name"] as? String, let url = d["url"] as? String else { return nil }
            var t = Target(name: name, url: url)
            if let s = d["signature"] as? [String: Any] {
                t.sigHeader = s["header"] as? String
                t.sigEncoding = (s["encoding"] as? String) ?? "hex"
                t.sigPrefix = (s["prefix"] as? String) ?? ""
                t.sigSecret = s["secret"] as? String
            }
            t.scp = d["scp"] as? String
            return t
        }
    }
}

// MARK: - 批注模型

enum Mark { case pen([CGPoint]), rect(CGRect) }

final class Canvas: NSView {
    let image: NSImage
    let iw: CGFloat, ih: CGFloat
    var marks: [Mark] = []
    var tool = 0                    // 0 画笔 1 矩形
    private var current: Mark?
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
    private var scale: CGFloat { min(fitRect.width / iw, fitRect.height / ih) }
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
        ctx.saveGState()   // 轻阴影
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

// MARK: - 窗口与发送

/// 带灰字占位提示的多行输入框（仍是 NSTextView）。占位用一个不拦截鼠标的灰字 label 实现。
final class PlaceholderTextView: NSTextView {
    private final class PassThroughLabel: NSTextField { override func hitTest(_ p: NSPoint) -> NSView? { nil } }
    private let hint = PassThroughLabel(labelWithString: "写点说明，会作为 prompt 发给 agent…")
    override var string: String { didSet { syncHint() } }
    override func didChangeText() { super.didChangeText(); syncHint() }
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

final class App: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var canvas: Canvas!
    let note = PlaceholderTextView()
    let status = NSTextField(labelWithString: "")
    let popup = NSPopUpButton()
    let sendBtn = NSButton(title: "发送  ⌘↵", target: nil, action: nil)
    var targets: [Target] = []
    let imageURL: URL
    var appActivity: NSObjectProtocol?
    let demo: Bool
    let shotOut: String?

    init(imageURL: URL, demo: Bool, shotOut: String?) { self.imageURL = imageURL; self.demo = demo; self.shotOut = shotOut }

    func applicationDidFinishLaunching(_ n: Notification) {
        targets = Target.loadAll()
        guard let img = NSImage(contentsOf: imageURL) else { fputs("无法读取图片\n", stderr); exit(1) }
        canvas = Canvas(image: img)
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        // 自动演示靠定时器驱动；窗口无人看时 App Nap 会把它压到几乎不动，所以演示期间禁用。
        if demo { appActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "T3Shot demo") }
        if ProcessInfo.processInfo.environment["T3SHOT_PRINT_WINDOW_ID"] == "1" { fputs("WINDOW_ID=\(window.windowNumber)\n", stderr) }
        if targets.isEmpty { setStatus("没有目标：请在 ~/.config/t3shot/targets.json 里配置 webhook", error: true) }
        if demo { runDemo() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "退出 T3Shot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        let u = edit.addItem(withTitle: "撤销批注", action: #selector(undo), keyEquivalent: "z"); u.target = self
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }

    /// 玻璃容器：macOS 26 用 NSGlassEffectView，否则降级为 NSVisualEffectView。
    func makeGlass(_ content: NSView, radius: CGFloat, tint: NSColor? = nil) -> NSView {
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = radius
            g.tintColor = tint
            g.contentView = content
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

    func symbolImage(_ name: String, _ desc: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: desc)?.withSymbolConfiguration(cfg)
    }

    func iconButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton(image: symbolImage(symbol, tip) ?? NSImage(), target: self, action: action)
        b.isBordered = false; b.imagePosition = .imageOnly; b.toolTip = tip
        b.contentTintColor = .labelColor
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 34).isActive = true
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return b
    }

    /// 顶部浮动工具条：[画笔|矩形] 与 [撤销 清除] 两粒胶囊，放进玻璃容器里靠近时可融合。
    func buildToolbar() -> NSView {
        let barH: CGFloat = 46
        let seg = NSSegmentedControl(images: [symbolImage("pencil", "画笔"), symbolImage("rectangle", "矩形")].compactMap { $0 },
                                     trackingMode: .selectOne, target: self, action: #selector(toolChanged(_:)))
        seg.selectedSegment = 0
        seg.setToolTip("画笔", forSegment: 0); seg.setToolTip("矩形", forSegment: 1)
        seg.setWidth(44, forSegment: 0); seg.setWidth(44, forSegment: 1)
        seg.controlSize = .large
        if #available(macOS 26, *) { seg.borderShape = .capsule }
        let segBox = NSStackView(views: [seg]); segBox.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        let undoB = iconButton("arrow.uturn.backward", tip: "撤销  ⌘Z", action: #selector(undo))
        let clearB = iconButton("trash", tip: "清除全部批注", action: #selector(clearAll))
        let actBox = NSStackView(views: [undoB, clearB]); actBox.spacing = 2
        actBox.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        [segBox, actBox].forEach { $0.alignment = .centerY; $0.layoutSubtreeIfNeeded() }
        let wA = segBox.fittingSize.width, wB = actBox.fittingSize.width
        segBox.frame = NSRect(x: 0, y: 0, width: wA, height: barH)
        actBox.frame = NSRect(x: 0, y: 0, width: wB, height: barH)
        let pillA = makeGlass(segBox, radius: barH / 2), pillB = makeGlass(actBox, radius: barH / 2)
        let gap: CGFloat = 10
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: wA + gap + wB, height: barH))
        pillA.frame = NSRect(x: 0, y: 0, width: wA, height: barH)
        pillB.frame = NSRect(x: wA + gap, y: 0, width: wB, height: barH)
        holder.addSubview(pillA); holder.addSubview(pillB)
        let outer: NSView
        if #available(macOS 26, *) {
            let c = NSGlassEffectContainerView(); c.spacing = 24; c.contentView = holder; outer = c
        } else { outer = holder }
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.widthAnchor.constraint(equalToConstant: holder.frame.width).isActive = true
        outer.heightAnchor.constraint(equalToConstant: barH).isActive = true
        return outer
    }

    /// 底部浮动面板：说明输入 / 目标选择 / 状态 / 发送。
    func buildPanel(height: CGFloat) -> NSView {
        note.isRichText = false; note.font = .systemFont(ofSize: 14); note.isAutomaticQuoteSubstitutionEnabled = false
        note.drawsBackground = false; note.textColor = .labelColor
        note.textContainerInset = NSSize(width: 2, height: 2)
        note.isVerticallyResizable = true; note.isHorizontallyResizable = false
        note.autoresizingMask = [.width]; note.textContainer?.widthTracksTextView = true
        let sv = NSScrollView(); sv.documentView = note; sv.hasVerticalScroller = true; sv.autohidesScrollers = true
        sv.drawsBackground = false; sv.borderType = .noBorder
        sv.translatesAutoresizingMaskIntoConstraints = false

        let hair = NSBox(); hair.boxType = .separator; hair.translatesAutoresizingMaskIntoConstraints = false

        targets.forEach { popup.addItem(withTitle: $0.name) }
        if let last = UserDefaults.standard.string(forKey: "lastTarget") { popup.selectItem(withTitle: last) }
        popup.toolTip = "发送到哪个目标"
        if #available(macOS 26, *) { popup.borderShape = .capsule }
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.setContentHuggingPriority(.init(900), for: .horizontal)

        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle; status.maximumNumberOfLines = 1
        status.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        status.setContentHuggingPriority(.init(1), for: .horizontal)
        status.translatesAutoresizingMaskIntoConstraints = false

        sendBtn.target = self; sendBtn.action = #selector(send)
        sendBtn.keyEquivalent = "\r"; sendBtn.keyEquivalentModifierMask = .command
        sendBtn.image = symbolImage("paperplane.fill", "发送"); sendBtn.imagePosition = .imageLeading
        sendBtn.toolTip = "发送  ⌘↵"
        if #available(macOS 26, *) {
            sendBtn.bezelStyle = .glass; sendBtn.borderShape = .capsule
            sendBtn.tintProminence = .primary; sendBtn.bezelColor = .controlAccentColor
        } else { sendBtn.bezelStyle = .rounded; sendBtn.bezelColor = .controlAccentColor }
        sendBtn.controlSize = .large
        sendBtn.translatesAutoresizingMaskIntoConstraints = false

        let pc = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: height))
        [sv, hair, popup, status, sendBtn].forEach { pc.addSubview($0) }
        let pad: CGFloat = 18
        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: pc.topAnchor, constant: 12),
            sv.leadingAnchor.constraint(equalTo: pc.leadingAnchor, constant: pad),
            sv.trailingAnchor.constraint(equalTo: pc.trailingAnchor, constant: -pad),
            sv.heightAnchor.constraint(equalToConstant: 58),
            hair.topAnchor.constraint(equalTo: sv.bottomAnchor, constant: 8),
            hair.leadingAnchor.constraint(equalTo: pc.leadingAnchor, constant: pad),
            hair.trailingAnchor.constraint(equalTo: pc.trailingAnchor, constant: -pad),
            popup.leadingAnchor.constraint(equalTo: pc.leadingAnchor, constant: pad - 4),
            popup.bottomAnchor.constraint(equalTo: pc.bottomAnchor, constant: -12),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            popup.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            status.leadingAnchor.constraint(equalTo: popup.trailingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: sendBtn.leadingAnchor, constant: -12),
            status.centerYAnchor.constraint(equalTo: popup.centerYAnchor),
            sendBtn.trailingAnchor.constraint(equalTo: pc.trailingAnchor, constant: -14),
            sendBtn.centerYAnchor.constraint(equalTo: popup.centerYAnchor),
        ])
        return pc
    }

    func buildWindow() {
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

        let panel = makeGlass(buildPanel(height: panelH), radius: 24)
        panel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(panel)
        let fillW = panel.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -2 * m); fillW.priority = .init(750)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            panel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -m),
            panel.heightAnchor.constraint(equalToConstant: panelH),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 780),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: m),
            fillW,
        ])

        // 窗口大小：按截图比例，不小于 880x620，不超过屏幕可视区 90%
        let vis = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1400, height: 900)
        let w = min(max(canvas.iw / 2 + 48, 880), vis.width * 0.9)
        let fitH = (w - 48) * canvas.ih / canvas.iw
        let h = min(max(fitH + topInset + bottomInset, 620), vis.height * 0.9)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "T3Shot — 批注并发送"
        switch ProcessInfo.processInfo.environment["T3SHOT_APPEARANCE"] {   // 仅自检用：强制深色/浅色
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        case "light": window.appearance = NSAppearance(named: .aqua)
        default: break
        }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.contentView = root
        window.center(); window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(note)
        window.isReleasedWhenClosed = false
    }

    @objc func toolChanged(_ s: NSSegmentedControl) { canvas.tool = s.selectedSegment }
    @objc func undo() { canvas.undo() }
    @objc func clearAll() { canvas.clear() }

    func setStatus(_ s: String, error: Bool = false) {
        status.stringValue = s; status.toolTip = s
        status.textColor = error ? .systemRed : (s.hasPrefix("已发送") ? .systemGreen : .secondaryLabelColor)
    }

    @objc func send() {
        guard popup.indexOfSelectedItem >= 0, popup.indexOfSelectedItem < targets.count else { setStatus("请先选择发送目标", error: true); return }
        let target = targets[popup.indexOfSelectedItem]
        guard let png = canvas.exportPNG() else { setStatus("导出图片失败", error: true); return }
        UserDefaults.standard.set(target.name, forKey: "lastTarget")
        let dir = URL(fileURLWithPath: NSString(string: "~/.t3shot/shots").expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let file = dir.appendingPathComponent("shot-\(f.string(from: Date())).png")
        do { try png.write(to: file) } catch { setStatus("保存失败：\(error.localizedDescription)", error: true); return }
        let text = note.string
        sendBtn.isEnabled = false; setStatus("发送中…")
        DispatchQueue.global().async { [self] in
            var remote: String?
            if let scp = target.scp {
                let r = run("/usr/bin/scp", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", file.path, scp])
                if r.code != 0 { return finish("scp 失败：\(r.err.trimmingCharacters(in: .whitespacesAndNewlines))", ok: false) }
                if let colon = scp.firstIndex(of: ":") {
                    var dirPath = String(scp[scp.index(after: colon)...])
                    if !dirPath.hasSuffix("/") { dirPath += "/" }
                    remote = dirPath + file.lastPathComponent
                }
            }
            var payload: [String: Any] = [
                "source": "t3shot", "note": text, "image_path": file.path,
                "image_remote_path": remote ?? "", "host": Host.current().localizedName ?? "mac",
                "created_at": ISO8601DateFormatter().string(from: Date()),
            ]
            payload["image_delivered"] = remote != nil
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return finish("编码失败", ok: false) }
            var req = URLRequest(url: URL(string: target.url)!, timeoutInterval: 20)
            req.httpMethod = "POST"; req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("t3shot/1.0", forHTTPHeaderField: "User-Agent")   // 默认 UA 会被 Cloudflare 拦截
            if let h = target.sigHeader, let secret = target.sigSecret {
                let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
                let value = target.sigEncoding == "base64" ? Data(mac).base64EncodedString() : mac.map { String(format: "%02x", $0) }.joined()
                req.setValue(target.sigPrefix + value, forHTTPHeaderField: h)
            }
            URLSession.shared.dataTask(with: req) { data, resp, err in
                if let err = err { return self.finish("发送失败：\(err.localizedDescription)", ok: false) }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) {
                    self.finish("已发送（HTTP \(code)）" + (remote == nil ? "；注意：图片未传到远端，只发了文字说明" : "；图片 → \(remote!)"), ok: true)
                } else {
                    self.finish("webhook 返回 \(code)：\(String(data: (data ?? Data()).prefix(160), encoding: .utf8) ?? "")", ok: false)
                }
            }.resume()
        }
    }

    func finish(_ msg: String, ok: Bool) {
        DispatchQueue.main.async {
            self.setStatus(msg, error: !ok)
            self.sendBtn.isEnabled = true
            print(ok ? "OK: \(msg)" : "ERR: \(msg)")
            if ok { DispatchQueue.main.asyncAfter(deadline: .now() + (self.demo ? (ProcessInfo.processInfo.environment["T3SHOT_SLOW"] == "1" ? 4.0 : 0.5) : 1.2)) { NSApp.terminate(nil) } }
            else if self.demo { exit(2) }
        }
    }

    func run(_ exe: String, _ args: [String]) -> (code: Int32, err: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let e = Pipe(); p.standardError = e; p.standardOutput = Pipe()
        do { try p.run() } catch { return (127, error.localizedDescription) }
        p.waitUntilExit()
        return (p.terminationStatus, String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    /// 无人值守自检：自动画框 + 写说明 + 导出窗口截图（+ 可选发送）。
    func runDemo() {
        if ProcessInfo.processInfo.environment["T3SHOT_SLOW"] == "1" { return runSlowDemo() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            let w = canvas.iw, h = canvas.ih
            let b = (ProcessInfo.processInfo.environment["T3SHOT_BOX"] ?? "0.34,0.50,0.32,0.07").split(separator: ",").compactMap { Double($0) }
            canvas.marks = [.rect(CGRect(x: w * b[0], y: h * b[1], width: w * b[2], height: h * b[3]))]
            canvas.needsDisplay = true
            note.string = ProcessInfo.processInfo.environment["T3SHOT_NOTE"] ?? "自检：红框处的按钮在暗色模式下看不清。"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let out = self.shotOut {
                    // NSGlassEffectView 的玻璃用 cacheDisplay 截不到：优先用系统 screencapture 按窗口截，失败再回退 cacheDisplay。
                    let r = self.run("/usr/sbin/screencapture", ["-x", "-o", "-l\(self.window.windowNumber)", out])
                    let size = (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? nil
                    let ok = r.code == 0 && (size ?? 0) > 0
                    if !ok, let v = self.window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    }
                }
                if ProcessInfo.processInfo.environment["T3SHOT_AUTOSEND"] == "1" { self.send() } else { NSApp.terminate(nil) }
            }
        }
    }
}

extension App {
    /// 录屏演示：窗口出现 → 逐步画框 → 逐字输入说明 → 发送 → 停留几秒。比例由环境变量 T3SHOT_BOX 指定 "x,y,w,h"（0~1，原点在左下）。
    func runSlowDemo() {
        let env = ProcessInfo.processInfo.environment
        let box = (env["T3SHOT_BOX"] ?? "0.34,0.50,0.32,0.07").split(separator: ",").compactMap { Double($0) }
        let text = Array(env["T3SHOT_NOTE"] ?? "自检：红框处的按钮在暗色模式下看不清。")
        let w = canvas.iw, h = canvas.ih
        let full = CGRect(x: w * box[0], y: h * box[1], width: w * box[2], height: h * box[3])
        window.makeFirstResponder(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
            let steps = 24; var i = 0
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
                i += 1
                let f = CGFloat(i) / CGFloat(steps)
                self.canvas.marks = [.rect(CGRect(x: full.minX, y: full.maxY - full.height * f, width: full.width * f, height: full.height * f))]
                self.canvas.needsDisplay = true
                if i >= steps {
                    t.invalidate()
                    self.window.makeFirstResponder(self.note)
                    var n = 0
                    Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { t2 in
                        n += 1; self.note.string = String(text.prefix(n))
                        if n >= text.count {
                            t2.invalidate()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.send() }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 入口

var imagePath: String?, demo = false, full = false, shotOut: String?
var argv = Array(CommandLine.arguments.dropFirst())
while let a = argv.first {
    argv.removeFirst()
    switch a {
    case "--image": imagePath = argv.first; argv.removeFirst()
    case "--demo": demo = true
    case "--window-shot": shotOut = argv.first; argv.removeFirst()
    case "--full": full = true
    default: fputs("未知参数 \(a)\n用法：T3Shot [--full] [--image 文件]\n", stderr); exit(64)
    }
}
if imagePath == nil {
    let tmp = NSTemporaryDirectory() + "t3shot-\(Int(Date().timeIntervalSince1970)).png"
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = (full ? ["-x"] : ["-i", "-x"]) + [tmp]       // -i：系统原生十字线框选，Esc 取消
    try? p.run(); p.waitUntilExit()
    guard let sz = try? FileManager.default.attributesOfItem(atPath: tmp)[.size] as? Int, sz > 0 else { exit(0) }   // 取消
    imagePath = tmp
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = App(imageURL: URL(fileURLWithPath: imagePath!), demo: demo, shotOut: shotOut)
app.delegate = delegate
app.run()
