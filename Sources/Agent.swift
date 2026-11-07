// Agent.swift — 常驻菜单栏 + 全局快捷键：左右 Shift 同时按 → 直接截下整个屏幕 → 批注窗口（红框圈出要说的内容）。
// 没有「输入监控」权限时退回 ⌃⇧4（框选区域）。
import AppKit
import Carbon.HIToolbox

@MainActor
final class Agent: NSObject, NSApplicationDelegate {
    static var shared: Agent!
    var statusItem: NSStatusItem?
    var controllers: [AnnotateController] = []
    var hotKeyRef: EventHotKeyRef?
    var chordTap: ShiftChordTap?
    let mode: Mode
    var demo: DemoScript?

    enum Mode { case resident, single(URL), fullscreen, benchOpen(Int), demo }

    init(mode: Mode) { self.mode = mode; super.init(); Agent.shared = self }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        switch mode {
        case .resident:
            NSApp.setActivationPolicy(.accessory)
            buildStatusItem()
            registerShortcuts()
            Task { await Directory.shared.refresh() }
            // 预热：显示器列表（ScreenCaptureKit 第一次取很慢），屏幕配置变化时作废
            Task { await ScreenGrabber.prewarm() }
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                ScreenGrabber.screenConfigurationChanged()
            }
            // 定时刷新，保证按下快捷键时目标列表已经是热的
            Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { _ in Task { @MainActor in await Directory.shared.refresh() } }
        case .single(let url):
            NSApp.setActivationPolicy(.regular)
            guard let img = NSImage(contentsOf: url) else { fputs("无法读取图片\n", stderr); exit(1) }
            startSingle(img, screen: nil)
        case .fullscreen:
            NSApp.setActivationPolicy(.regular)
            Task { @MainActor in
                guard let shot = await Agent.grabScreen() else { fputs("截屏失败：需要「屏幕录制」权限\n", stderr); exit(2) }
                startSingle(shot.image, screen: shot.screen)
            }
        case .benchOpen(let n):
            NSApp.setActivationPolicy(.accessory)          // 和常驻一致
            Task { @MainActor in await runBenchOpen(n) }
        case .demo:
            NSApp.setActivationPolicy(.regular)
            demo = DemoScript()
            demo?.start()
        }
    }


    /// 单次运行（--image / --fullscreen）：开一个批注窗口，关掉就退出；带测试用的快照和自动发送钩子。
    func startSingle(_ img: NSImage, screen: NSScreen?) {
        let c = open(image: img, screen: screen)
        c.onClose = { NSApp.terminate(nil) }
        // 自检钩子：T3SHOT_SNAPSHOT=<目录>：等 Clef 判断完（每 0.5 秒看一次，最长 T3SHOT_SNAPSHOT_DELAY 秒，默认 45）后，
        // 打印胶囊 / 提示行 / 候选数，把批注窗口和 ⌘K 选择器存成 PNG，然后退出。用 cacheDisplay 渲染，不需要屏幕录制权限。
        let env = ProcessInfo.processInfo.environment
        if let dir = env["T3SHOT_SNAPSHOT"] {
            if let n = env["T3SHOT_NOTE"] { c.note.string = n }
            let maxWait = Double(env["T3SHOT_SNAPSHOT_DELAY"] ?? "") ?? 45
            Task { @MainActor in
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                // 目录刷新 + 线程摘要 + Clef 请求的总时长不固定，固定睡眠会误判；轮询到提示行出现 Clef 的结论（含「不可用」）为止
                let t0 = Date()
                while Date().timeIntervalSince(t0) < maxWait {
                    try? await Task.sleep(for: .milliseconds(500))
                    let s = c.status.stringValue
                    if s.contains("✨ Clef") && !s.contains("正在看图判断") { break }
                }
                print(String(format: "CLEF_WAIT=%.1fs", Date().timeIntervalSince(t0)))
                print("IMAGE=\(Int(img.size.width))x\(Int(img.size.height))pt")
                print("CHIP=\(c.chip.title)\nSTATUS=\(c.status.stringValue)\nSUGGESTIONS=\(c.suggestions.count)")
                for s in c.suggestions.prefix(5) { print(String(format: "RANK %3.0f%% %@", s.probability * 100, (s.dest.isNew ? "新线程·" : "") + s.dest.title)) }
                @MainActor func save(_ view: NSView?, _ name: String) {
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
        // 自检钩子：T3SHOT_ESC_TEST=1：合成一个 Esc 按键送进事件循环，窗口应当关闭（打印 ESC_CLOSED=true），否则 2 秒后打印 false 并退出码 1
        if env["T3SHOT_ESC_TEST"] != nil {
            c.onClose = { print("ESC_CLOSED=true"); fflush(stdout); NSApp.terminate(nil) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: c.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                             isARepeat: false, keyCode: 53) { NSApp.sendEvent(ev) }
                try? await Task.sleep(for: .seconds(2))
                print("ESC_CLOSED=false"); fflush(stdout); exit(1)
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
    }

    /// --bench-open N：模拟按 N 次快捷键（目录已预热、和常驻一样），每次打印 触发→截屏→建窗口→窗口显示→首帧 的时间线。
    /// 不投递、不发送；T3SHOT_NO_CLEF=1 可以关掉 Clef 对比。
    func runBenchOpen(_ n: Int) async {
        await Directory.shared.refresh()
        await ScreenGrabber.prewarm()
        var rows: [[String: Double]] = []
        for i in 1...n {
            guard let c = await openFullScreen() else { fputs("截屏失败\n", stderr); exit(2) }
            for _ in 0..<60 where Perf.ms("first-frame") == nil { try? await Task.sleep(for: .milliseconds(50)) }
            let marks = Perf.marks
            print("— 第 \(i) 次" + (i == 1 ? "（含首次预热）" : ""))
            for m in marks { print(String(format: "  %6.0f ms  %@", m.ms, m.name)) }
            rows.append(Dictionary(marks.map { ($0.name, $0.ms) }, uniquingKeysWith: { a, _ in a }))
            if i == 1 {      // 对照：旧做法在 AnnotateController.init 里同步导出整屏 PNG 给 Clef，窗口要等它
                let t = Date(); let png = c.canvas.exportPNG()
                print(String(format: "  对照：旧做法同步 exportPNG = %.0f ms（%d KiB）", Date().timeIntervalSince(t) * 1000, (png?.count ?? 0) / 1024))
            }
            try? await Task.sleep(for: .seconds(1.5))      // 让 Clef 请求别和下一轮重叠；也看看有没有拖慢主线程
            c.window.close()
            try? await Task.sleep(for: .milliseconds(500))
        }
        func median(_ k: String) -> String {
            let v = rows.dropFirst().compactMap { $0[k] }.sorted()          // 去掉第 1 次（预热）
            return v.isEmpty ? "-" : String(format: "%.0f ms", v[v.count / 2])
        }
        print("\n中位数（第 2 次起）：截屏完成 \(median("captured"))，窗口创建 \(median("controller-created"))，窗口显示 \(median("window-shown"))，首帧 \(median("first-frame"))")
        NSApp.terminate(nil)
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
        item.button?.toolTip = "T3Shot  左右 Shift 同时按 = 截整个屏幕"
        let m = NSMenu()
        let full = m.addItem(withTitle: "截取整个屏幕并批注  ⇧⇧", action: #selector(captureFullScreen), keyEquivalent: ""); full.target = self
        let cap = m.addItem(withTitle: "框选区域并批注  ⌃⇧4", action: #selector(capture), keyEquivalent: "4"); cap.keyEquivalentModifierMask = [.control, .shift]; cap.target = self
        let r = m.addItem(withTitle: "刷新投递目标", action: #selector(refresh), keyEquivalent: ""); r.target = self
        m.addItem(.separator())
        let envs = m.addItem(withTitle: "环境", action: nil, keyEquivalent: ""); envs.isEnabled = false
        m.addItem(.separator())
        m.addItem(withTitle: "退出 T3Shot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
        statusItem = item
        _ = Directory.shared.observe { [weak self] in self?.renderEnvs() }      // 菜单栏常驻，不需要移除
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

    // MARK: 全局快捷键

    /// 主快捷键：左右 Shift 同时按（需要「输入监控」权限）。没权限时先注册 ⌃⇧4 兜底（Carbon，不需要权限），
    /// 并每 5 秒重试；授权之后 ⇧⇧ 自动生效，⌃⇧4 保留（框选区域）。
    func registerShortcuts() {
        let tap = ShiftChordTap { Task { @MainActor in Agent.shared.captureFullScreen() } }
        chordTap = tap
        if tap.install(promptForPermission: true) {
            fputs("快捷键 左右 Shift 同时按 已注册\n", stderr)
        } else {
            fputs("没有「输入监控」权限，左右 Shift 暂不可用：先用 ⌃⇧4；授权后自动生效（系统设置 → 隐私与安全性 → 输入监控）\n", stderr)
            tap.installWithRetry { fputs("左右 Shift 快捷键已生效\n", stderr) }
        }
        registerHotKey()      // ⌃⇧4：框选区域
    }

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

    /// 直接截下鼠标所在的那块屏幕（不弹十字线）。窗口随后出现在同一块屏幕上，用红框圈要说的内容。
    @objc func captureFullScreen() {
        guard !capturing else { return }
        capturing = true
        Task { @MainActor in
            defer { capturing = false }
            _ = await openFullScreen()
        }
    }

    /// 整条链路：截屏 → 建窗口 → 显示。每一步打点（T3SHOT_TIMING=1 或 --bench-open 能看到）。失败时右上角提示。
    func openFullScreen() async -> AnnotateController? {
        Perf.start()
        guard let shot = await Agent.grabScreen() else {
            Toast.shared.show(.error, "截屏失败", detail: "需要「屏幕录制」权限（系统设置 → 隐私与安全性）", hideAfter: 6)
            return nil
        }
        Perf.mark("captured")
        let c = open(image: shot.image, screen: shot.screen)
        return c
    }

    /// 鼠标所在的屏幕。
    static func grabScreen() async -> (image: NSImage, screen: NSScreen)? {
        guard let screen = ScreenGrabber.screenUnderMouse(), let cg = await ScreenGrabber.grab(screen) else { return nil }
        return (ScreenGrabber.nsImage(cg, screen: screen), screen)
    }

    @discardableResult
    func open(image: NSImage, screen: NSScreen? = nil) -> AnnotateController {
        let c = AnnotateController(image: image, screen: screen)
        Perf.mark("controller-created")
        controllers.append(c)
        c.onClose = { [weak self, weak c] in self?.controllers.removeAll { $0 === c } }
        if case .resident = mode { c.dismissOnSend = true }   // 发送即收起，结果走右上角提示
        c.show()
        return c
    }
}
