// Agent.swift — 常驻菜单栏 + 全局快捷键 ⌃⇧4：框选截图 → 批注窗口。
import AppKit
import Carbon.HIToolbox

@MainActor
final class Agent: NSObject, NSApplicationDelegate {
    static var shared: Agent!
    var statusItem: NSStatusItem?
    var controllers: [AnnotateController] = []
    var hotKeyRef: EventHotKeyRef?
    let mode: Mode
    var demo: DemoScript?

    enum Mode { case resident, single(URL), demo }

    init(mode: Mode) { self.mode = mode; super.init(); Agent.shared = self }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        switch mode {
        case .resident:
            NSApp.setActivationPolicy(.accessory)
            buildStatusItem()
            registerHotKey()
            Task { await Directory.shared.refresh() }
            // 定时刷新，保证按下快捷键时目标列表已经是热的
            Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { _ in Task { @MainActor in await Directory.shared.refresh() } }
        case .single(let url):
            NSApp.setActivationPolicy(.regular)
            guard let img = NSImage(contentsOf: url) else { fputs("无法读取图片\n", stderr); exit(1) }
            let c = open(image: img)
            c.onClose = { NSApp.terminate(nil) }
            // 自检钩子：T3SHOT_SNAPSHOT=<目录>：等 Clef 判断完（T3SHOT_SNAPSHOT_DELAY 秒，默认 15）后，
            // 打印胶囊 / 提示行 / 候选数，把批注窗口和 ⌘K 选择器存成 PNG，然后退出。用 cacheDisplay 渲染，不需要屏幕录制权限。
            let env = ProcessInfo.processInfo.environment
            if let dir = env["T3SHOT_SNAPSHOT"] {
                if let n = env["T3SHOT_NOTE"] { c.note.string = n }
                let delay = Double(env["T3SHOT_SNAPSHOT_DELAY"] ?? "") ?? 15
                Task { @MainActor in
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    try? await Task.sleep(for: .seconds(delay))
                    print("CHIP=\(c.chip.title)\nSTATUS=\(c.status.stringValue)\nSUGGESTIONS=\(c.suggestions.count)")
                    for s in c.suggestions.prefix(5) { print(String(format: "RANK %3.0f%% %@", s.probability * 100, (s.dest.isNew ? "新线程·" : "") + s.dest.title)) }
                    func save(_ view: NSView?, _ name: String) {
                        guard let v = view, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/" + name))
                    }
                    save(c.window.contentView, "window.png")
                    c.openPicker()
                    try? await Task.sleep(for: .seconds(1.5))
                    if let png = c.pickerController?.snapshotPNG() { try? png.write(to: URL(fileURLWithPath: dir + "/picker.png")) }
                    print("SNAPSHOT_DONE")
                    NSApp.terminate(nil)
                }
            }
            // 自检钩子：按常驻模式的方式自动发送一次（窗口立刻收起、结果走提示），用于脚本验证
            if let key = ProcessInfo.processInfo.environment["T3SHOT_AUTOSEND_KEY"] {
                c.dismissOnSend = true
                c.onClose = { DispatchQueue.main.asyncAfter(deadline: .now() + 10) { NSApp.terminate(nil) } }
                Task { @MainActor in
                    await Directory.shared.refresh()
                    guard let d = Directory.shared.destinations.first(where: { $0.key == key }) else { fputs("找不到目标 \(key)\n", stderr); exit(3) }
                    c.userPicked = true
                    c.setDestination(d, remember: false)
                    c.note.string = ProcessInfo.processInfo.environment["T3SHOT_NOTE"] ?? "T3Shot 自检"
                    try? await Task.sleep(for: .seconds(1))
                    fputs("SEND_AT=\(Date().timeIntervalSince1970)\n", stderr)
                    c.send()
                    fputs("WINDOW_VISIBLE_AFTER_SEND=\(c.window.isVisible)\n", stderr)
                }
            }
        case .demo:
            NSApp.setActivationPolicy(.regular)
            demo = DemoScript()
            demo?.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    // MARK: 菜单 & 菜单栏

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "退出 T3Shot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        let u = edit.addItem(withTitle: "撤销批注", action: #selector(undoMark), keyEquivalent: "z"); u.target = self
        let k = edit.addItem(withTitle: "选择投递目标", action: #selector(pickTarget), keyEquivalent: "k"); k.target = self
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let w = edit.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"); _ = w
        NSApp.mainMenu = main
    }

    var keyController: AnnotateController? { controllers.first { $0.window.isKeyWindow } ?? controllers.last }
    @objc func undoMark() { keyController?.undo() }
    @objc func pickTarget() { keyController?.openPicker() }

    func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = UI.symbol("camera.viewfinder", 14)
        item.button?.toolTip = "T3Shot  ⌃⇧4"
        let m = NSMenu()
        let cap = m.addItem(withTitle: "截图并投递到 T3", action: #selector(capture), keyEquivalent: "4"); cap.keyEquivalentModifierMask = [.control, .shift]; cap.target = self
        let r = m.addItem(withTitle: "刷新投递目标", action: #selector(refresh), keyEquivalent: ""); r.target = self
        m.addItem(.separator())
        let envs = m.addItem(withTitle: "环境", action: nil, keyEquivalent: ""); envs.isEnabled = false
        m.addItem(.separator())
        m.addItem(withTitle: "退出 T3Shot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
        statusItem = item
        Directory.shared.onChange.append { [weak self] in self?.renderEnvs() }
    }

    func renderEnvs() {
        guard let m = statusItem?.menu, let idx = m.items.firstIndex(where: { $0.title == "环境" || $0.tag == 42 }) else { return }
        while m.items.count > idx + 1, m.items[idx + 1].tag == 43 { m.removeItem(at: idx + 1) }
        m.items[idx].tag = 42
        for (i, e) in Directory.shared.envs.enumerated() {
            let it = NSMenuItem(title: "\(e.online ? "●" : "○") \(e.label)\(e.direct ? "" : " · 经链接")", action: nil, keyEquivalent: "")
            it.tag = 43; it.isEnabled = false; it.toolTip = e.error
            m.insertItem(it, at: idx + 1 + i)
        }
    }

    @objc func refresh() { Task { await Directory.shared.refresh() } }

    // MARK: 全局快捷键（Carbon RegisterEventHotKey，不需要辅助功能权限）

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Agent.shared.capture() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5433_5348), id: 1)   // 'T3SH'
        let st = RegisterEventHotKey(UInt32(kVK_ANSI_4), UInt32(controlKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        fputs(st == noErr ? "快捷键 ⌃⇧4 已注册\n" : "快捷键注册失败：\(st)\n", stderr)
    }

    // MARK: 截图

    private var capturing = false
    @objc func capture() {
        guard !capturing else { return }
        capturing = true
        let tmp = NSTemporaryDirectory() + "t3shot-\(Int(Date().timeIntervalSince1970)).png"
        Task.detached {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", tmp]          // 系统原生十字线框选，Esc 取消
            try? p.run(); p.waitUntilExit()
            await MainActor.run {
                self.capturing = false
                guard let img = NSImage(contentsOfFile: tmp) else { return }   // 取消
                _ = self.open(image: img)
            }
        }
    }

    @discardableResult
    func open(image: NSImage) -> AnnotateController {
        let c = AnnotateController(image: image)
        controllers.append(c)
        c.onClose = { [weak self, weak c] in self?.controllers.removeAll { $0 === c } }
        if case .resident = mode { c.dismissOnSend = true }   // 发送即收起，结果走右上角提示
        c.show()
        return c
    }
}
