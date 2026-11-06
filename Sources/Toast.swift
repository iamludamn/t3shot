// Toast.swift — 发送后的轻提示：窗口立刻收起，投递在后台进行，结果显示在屏幕右上角。
// 不抢焦点（non-activating），几秒后自动消失；鼠标停在上面时不消失；有线程链接时可点「打开」。
import AppKit

@MainActor
final class Toast {
    static let shared = Toast()

    private let panel: NSPanel
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let action = NSButton(title: "打开", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var link: URL?
    private var hideWork: DispatchWorkItem?
    private var onAction: (() -> Void)?

    private final class HoverView: NSView {
        var onHover: ((Bool) -> Void)?
        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
        }
        override func mouseEntered(with e: NSEvent) { onHover?(true) }
        override func mouseExited(with e: NSEvent) { onHover?(false) }
    }

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = false

        let box = HoverView()
        box.onHover = { [weak self] inside in self?.hovering(inside) }
        title.font = .systemFont(ofSize: 13, weight: .semibold); title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11.5); detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail; detail.maximumNumberOfLines = 2
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        action.target = self; action.action = #selector(tapAction)
        if #available(macOS 26, *) { action.bezelStyle = .glass; action.borderShape = .capsule } else { action.bezelStyle = .rounded }
        action.controlSize = .small
        [icon, spinner, title, detail, action].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; box.addSubview($0) }
        [title, detail].forEach { $0.setContentCompressionResistancePriority(.init(200), for: .horizontal) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16), icon.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 44), title.topAnchor.constraint(equalTo: box.topAnchor, constant: 13),
            title.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor), detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -8),
            action.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14), action.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        panel.contentView = UI.glass(box, radius: 18)
    }

    enum Kind { case working, ok, error }

    /// 显示或更新提示。working 状态不自动消失；ok/error 默认 6 秒后消失。
    func show(_ kind: Kind, _ text: String, detail sub: String = "", actionTitle: String? = nil, onAction: (() -> Void)? = nil, hideAfter: Double? = nil) {
        title.stringValue = text
        detail.stringValue = sub; detail.isHidden = sub.isEmpty
        self.onAction = onAction
        action.isHidden = actionTitle == nil
        if let actionTitle { action.title = actionTitle }
        switch kind {
        case .working: icon.image = nil; spinner.startAnimation(nil)
        case .ok: spinner.stopAnimation(nil); icon.image = UI.symbol("checkmark.circle.fill", 17, colors: [.systemGreen])
        case .error: spinner.stopAnimation(nil); icon.image = UI.symbol("exclamationmark.triangle.fill", 16, colors: [.systemOrange])
        }
        let h: CGFloat = sub.isEmpty ? 48 : 64
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame
        let frame = NSRect(x: vis.maxX - 360 - 16, y: vis.maxY - h - 12, width: 360, height: h)
        if !panel.isVisible {
            panel.setFrame(frame.offsetBy(dx: 0, dy: 8), display: true)
            panel.alphaValue = 0; panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1; panel.animator().setFrame(frame, display: true) }
        } else {
            panel.setFrame(frame, display: true, animate: true)
        }
        scheduleHide(kind == .working ? nil : (hideAfter ?? 6))
    }

    func hide() {
        hideWork?.cancel(); hideWork = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) { [panel] in panel.orderOut(nil) }
    }

    private var pendingDelay: Double?
    private var isHovering = false
    private func scheduleHide(_ delay: Double?) {
        hideWork?.cancel(); hideWork = nil; pendingDelay = delay
        guard let delay, !isHovering else { return }
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
    private func hovering(_ inside: Bool) {
        isHovering = inside
        if inside { hideWork?.cancel(); hideWork = nil } else if let d = pendingDelay { scheduleHide(min(d, 3)) }
    }
    @objc private func tapAction() { onAction?(); hide() }
}
