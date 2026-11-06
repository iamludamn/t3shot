// Picker.swift — 投递目标选择器（⌘K）。渐进式暴露：
//   第 0 层：批注窗口里只有一个胶囊，显示当前目标（默认：上次用过的，否则第一个可新建线程的项目）。
//   第 1 层：打开选择器，两组各只露出最相关的几条——「新线程」（带 webhook 的项目）和「跟进」（活跃在前、空闲在后）。
//   第 2 层：「还有 N 条」或直接输入搜索，才展开全部线程和所有环境；环境的在线/配对状态收在底部一行。
import AppKit

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

private enum Row {
    case header(String, String)
    case dest(Destination)
    case more(section: Int, hidden: Int)
    case empty(String)
    var selectable: Bool { switch self { case .dest, .more: return true; default: return false } }
    var height: CGFloat { switch self { case .header: return 30; case .dest: return 46; case .more: return 30; case .empty: return 40 } }
}

private final class RowView: NSView {
    let row: Row
    var selected = false { didSet { needsDisplay = true } }
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    init(row: Row, current: Bool, width: CGFloat) {
        self.row = row
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: row.height))
        build(current: current)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func label(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight); l.textColor = color
        l.lineBreakMode = .byTruncatingTail; l.maximumNumberOfLines = 1
        l.translatesAutoresizingMaskIntoConstraints = false
        l.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        return l
    }

    private func build(current: Bool) {
        switch row {
        case .header(let t, let sub):
            let a = label(t, 11, .semibold, .secondaryLabelColor), b = label(sub, 11, .regular, .tertiaryLabelColor)
            addSubview(a); addSubview(b)
            NSLayoutConstraint.activate([
                a.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), a.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
                b.leadingAnchor.constraint(equalTo: a.trailingAnchor, constant: 8), b.firstBaselineAnchor.constraint(equalTo: a.firstBaselineAnchor),
                b.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            ])
        case .empty(let t):
            let a = label(t, 12, .regular, .secondaryLabelColor); addSubview(a)
            NSLayoutConstraint.activate([a.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), a.centerYAnchor.constraint(equalTo: centerYAnchor),
                                         a.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14)])
        case .more(_, let n):
            let a = label("还有 \(n) 条…", 12, .medium, .controlAccentColor); addSubview(a)
            NSLayoutConstraint.activate([a.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44), a.centerYAnchor.constraint(equalTo: centerYAnchor)])
        case .dest(let d):
            let icon = NSImageView()
            icon.image = d.needsSetup ? UI.symbol("plus.circle.dashed", 14, .regular, colors: [.secondaryLabelColor])
                       : d.isNew ? UI.symbol("plus.bubble", 14, .regular, colors: [.controlAccentColor])
                                 : UI.symbol("circle.fill", 8, colors: [d.isActive ? .systemGreen : .tertiaryLabelColor])
            icon.translatesAutoresizingMaskIntoConstraints = false
            let env = d.env.label
            let sub: String
            switch d.kind {
            case .newThread(_, let task): sub = "\(env) · webhook「\(task)」"
            case .setupProject: sub = "\(env) · 还没有入口，选中后自动创建 webhook"
            case .thread:
                let rel = d.updatedAt.map { Self.relative.localizedString(for: $0, relativeTo: Date()) } ?? ""
                sub = [env, d.project, rel].filter { !$0.isEmpty }.joined(separator: " · ")
            }
            let title = label(d.title, 13, .medium), subtitle = label(sub, 11, .regular, .secondaryLabelColor)
            let badgeText = d.needsSetup ? "启用" : d.isNew ? "新建" : (d.isActive ? "\(d.statusText) · 排队跟进" : "空闲")
            let badge = label(badgeText, 10, .semibold, d.isNew ? .controlAccentColor : (d.isActive ? .systemGreen : .tertiaryLabelColor))
            badge.setContentCompressionResistancePriority(.init(800), for: .horizontal)
            badge.setContentHuggingPriority(.init(800), for: .horizontal)
            let check = NSImageView(image: UI.symbol("checkmark", 11, .bold, colors: [.controlAccentColor]) ?? NSImage())
            check.translatesAutoresizingMaskIntoConstraints = false; check.isHidden = !current
            [icon, title, subtitle, badge, check].forEach { addSubview($0) }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), icon.centerYAnchor.constraint(equalTo: title.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44), title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
                subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor), subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
                subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
                check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), check.centerYAnchor.constraint(equalTo: title.centerYAnchor),
                badge.trailingAnchor.constraint(equalTo: check.leadingAnchor, constant: current ? -6 : 12), badge.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            ])
        }
        if row.selectable {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
    }
    static let relative: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: "zh_CN"); f.unitsStyle = .short; return f }()

    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 2), xRadius: 8, yRadius: 8).fill()
    }
    override func mouseEntered(with e: NSEvent) { onHover?() }
    override func mouseUp(with e: NSEvent) { if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?() } }
}

@MainActor
final class PickerController: NSObject, NSSearchFieldDelegate, NSPopoverDelegate {
    private let popover = NSPopover()
    private let vc = NSViewController()
    private let search = NSSearchField()
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let footer = NSTextField(labelWithString: "")
    private var rows: [Row] = []
    private var views: [RowView] = []
    private var selected: Int?
    private var expanded: Set<Int> = []
    private let current: Destination?
    private let onPick: (Destination) -> Void
    private let width: CGFloat = 420
    var isShown: Bool { popover.isShown }

    init(current: Destination?, onPick: @escaping (Destination) -> Void) {
        self.current = current; self.onPick = onPick
        super.init()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 300))
        search.placeholderString = "搜索项目或线程…"
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        footer.font = .systemFont(ofSize: 10.5); footer.textColor = .tertiaryLabelColor
        footer.lineBreakMode = .byTruncatingTail; footer.translatesAutoresizingMaskIntoConstraints = false
        let refresh = NSButton(image: UI.symbol("arrow.clockwise", 11) ?? NSImage(), target: self, action: #selector(refresh))
        refresh.isBordered = false; refresh.toolTip = "重新读取所有 T3 环境"; refresh.translatesAutoresizingMaskIntoConstraints = false
        let sep = NSBox(); sep.boxType = .separator; sep.translatesAutoresizingMaskIntoConstraints = false
        [search, scroll, sep, footer, refresh].forEach { root.addSubview($0) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sep.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 2),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), sep.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 6), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: refresh.leadingAnchor, constant: -6),
            refresh.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10), refresh.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        vc.view = root
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.delegate = self
        Directory.shared.onChange.append { [weak self] in self?.rebuild() }
        rebuild()
    }

    func show(relativeTo v: NSView) {
        popover.show(relativeTo: v.bounds, of: v, preferredEdge: .maxY)
        vc.view.window?.makeFirstResponder(search)
    }
    func close() { popover.close() }
    /// 父窗口被提到较高层级时，弹出层跟着提上去
    func raise() { vc.view.window?.level = .popUpMenu }

    @objc private func refresh() { Task { await Directory.shared.refresh() } }

    // MARK: 模型

    private func build() -> [Row] {
        guard Directory.shared.loadedAt != nil else { return [.empty("正在读取各环境的项目和线程…")] }
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let match: (Destination) -> Bool = { d in q.isEmpty || [d.title, d.project, d.env.label].contains { $0.lowercased().contains(q) } }
        let all = Directory.shared.destinations.filter(match)
        let news = all.filter { $0.isNew }.sorted { a, b in a.needsSetup != b.needsSetup ? !a.needsSetup : a.title < b.title }
        let threads = all.filter { !$0.isNew }.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
        }
        var out: [Row] = []
        func section(_ i: Int, _ title: String, _ sub: String, _ items: [Destination], limit: Int) {
            guard !items.isEmpty else { return }
            out.append(.header(title, sub))
            let open = !q.isEmpty || expanded.contains(i)
            // 收起时：agent 派生的线程不占名额（运行中的除外）
            // 收起时：agent 派生的线程、还没有入口的项目都不占名额（运行中的线程除外）
            var shown = open ? items : Array(items.filter { (!$0.byAgent || $0.isActive) && !$0.needsSetup }.prefix(limit))
            if !open, let c = current, !shown.contains(where: { $0.key == c.key }), let hit = items.first(where: { $0.key == c.key }) { shown.append(hit) }
            out += shown.map { .dest($0) }
            if items.count > shown.count { out.append(.more(section: i, hidden: items.count - shown.count)) }
        }
        section(0, "新线程", "经项目的 scheduler webhook", news, limit: 3)
        let active = threads.filter { $0.isActive }.count
        section(1, "跟进线程", active > 0 ? "\(active) 个运行中 · 其余空闲" : "未 settle 的空闲线程", threads, limit: 4)
        if out.isEmpty { out.append(.empty(q.isEmpty ? "没有可投递的目标" : "没有匹配「\(q)」的项目或线程")) }
        return out
    }

    private func rebuild() {
        let keepKey: String? = selected.flatMap { i in if case .dest(let d) = rows[i] { return d.key }; return nil }
        rows = build()
        views.forEach { $0.removeFromSuperview() }
        views = []
        var y: CGFloat = 4
        for (i, r) in rows.enumerated() {
            var isCurrent = false
            if case .dest(let d) = r, d.key == current?.key { isCurrent = true }
            let v = RowView(row: r, current: isCurrent, width: width)
            v.frame.origin = NSPoint(x: 0, y: y); y += r.height
            v.autoresizingMask = [.width]
            v.onHover = { [weak self] in self?.select(i, scroll: false) }
            v.onClick = { [weak self] in self?.select(i, scroll: false); self?.activate() }
            doc.addSubview(v); views.append(v)
        }
        doc.frame = NSRect(x: 0, y: 0, width: width, height: y + 4)
        let listH = min(y + 4, 400)
        scroll.removeConstraints(scroll.constraints.filter { $0.firstAttribute == .height })
        scroll.heightAnchor.constraint(equalToConstant: listH).isActive = true
        popover.contentSize = NSSize(width: width, height: 12 + 28 + 4 + listH + 34)
        // 选中：保持原来那一项；否则当前目标；否则第一项
        let idx = rows.firstIndex { if case .dest(let d) = $0 { return d.key == keepKey }; return false }
            ?? rows.firstIndex { if case .dest(let d) = $0 { return d.key == current?.key }; return false }
            ?? rows.firstIndex { $0.selectable }
        selected = nil
        if let idx { select(idx, scroll: true) }
        renderFooter()
    }

    private func renderFooter() {
        let envs = Directory.shared.envs
        guard !envs.isEmpty else { footer.stringValue = Directory.shared.loadedAt == nil ? "" : "未配对任何环境"; return }
        footer.stringValue = envs.map { e in
            let state = e.online ? (e.direct ? "●" : "◐") : "○"
            return "\(state) \(e.label)" + (e.online ? "" : " 离线")
        }.joined(separator: "   ") + (envs.contains { !$0.direct && $0.online } ? "   ◐ = 经链接，仅文字" : "")
        footer.toolTip = envs.map { "\($0.label)：\($0.online ? "在线" : ($0.error ?? "离线"))\($0.direct ? "，已配对（可传图）" : "，经本机 T3 链接转发（仅文字）")" }.joined(separator: "\n")
    }

    private func select(_ i: Int, scroll doScroll: Bool) {
        guard i >= 0, i < rows.count, rows[i].selectable else { return }
        if let s = selected, s < views.count { views[s].selected = false }
        selected = i; views[i].selected = true
        if doScroll { doc.scrollToVisible(views[i].frame.insetBy(dx: 0, dy: -8)) }
    }

    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        var i = selected ?? (delta > 0 ? -1 : rows.count)
        repeat { i += delta } while i >= 0 && i < rows.count && !rows[i].selectable
        if i >= 0 && i < rows.count { select(i, scroll: true) }
    }

    func activate() {
        guard let i = selected else { return }
        switch rows[i] {
        case .dest(let d): onPick(d); close()
        case .more(let s, _): expanded.insert(s); rebuild()
        default: break
        }
    }

    /// 演示脚本用：把高亮移到满足条件的那一行（逐行移动，看得见过程）。
    func stepToward(_ match: (Destination) -> Bool) -> Bool {
        guard let target = rows.firstIndex(where: { if case .dest(let d) = $0 { return match(d) }; return false }) else { return false }
        guard let s = selected, s != target else { return true }
        moveSelection(target > s ? 1 : -1)
        return selected == target
    }
    func typeQuery(_ s: String) { search.stringValue = s; rebuild() }

    // MARK: 键盘

    func controlTextDidChange(_ n: Notification) { rebuild() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)): activate(); return true
        case #selector(NSResponder.cancelOperation(_:)): if search.stringValue.isEmpty { close() } else { search.stringValue = ""; rebuild() }; return true
        default: return false
        }
    }
}
