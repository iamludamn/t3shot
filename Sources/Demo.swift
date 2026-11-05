// Demo.swift — 录屏用的自动演示。所有投递都是真实的（真的打 webhook、真的往线程里排队），
// 只有「按键」和「拖拽框选」是脚本模拟的：按键用屏幕上的键帽提示表示，框选在一张全屏「舞台」图上进行并直接裁剪。
//
// 环境变量：
//   T3SHOT_DEMO_BG      舞台背景（被调试的页面截图，建议和屏幕同尺寸）
//   T3SHOT_DEMO_SHOTS   两次框选，"x,y,w,h;x,y,w,h"（背景图像素，左上原点）
//   T3SHOT_DEMO_BOXES   两次的红框，"x,y,w,h;x,y,w,h"（相对各自截图，左上原点）
//   T3SHOT_DEMO_NOTES   两段说明，用 "||" 分隔
//   T3SHOT_DEMO_PROJECT 新线程目标项目名（默认 acme-login-demo）
//   T3SHOT_DEMO_DONE    结束时写入的标记文件（录屏脚本据此停止）
import AppKit

@MainActor
final class HUD {
    let panel: NSPanel
    let label = NSTextField(labelWithString: "")
    init(size: CGFloat, weight: NSFont.Weight = .semibold) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .statusBar; panel.hasShadow = true
        panel.ignoresMouseEvents = true; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        label.font = .systemFont(ofSize: size, weight: weight); label.textColor = .labelColor; label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView(); box.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: box.centerXAnchor), label.centerYAnchor.constraint(equalTo: box.centerYAnchor)])
        panel.contentView = UI.glass(box, radius: 22)
        panel.appearance = NSAppearance(named: .darkAqua)
    }
    func show(_ text: String, y: CGFloat) {
        label.stringValue = text
        let w = label.fittingSize.width + 56, h = label.fittingSize.height + 26
        let s = DemoScript.screen.frame
        panel.setFrame(NSRect(x: s.midX - w / 2, y: s.minY + y, width: w, height: h), display: true)
        panel.alphaValue = 0; panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
    }
    func hide() { NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) { self.panel.orderOut(nil) } }
}

/// 全屏舞台：显示被调试的页面；框选时盖一层暗色并画出十字线选框。
final class StageView: NSView {
    var image: NSImage?
    var selection: CGRect?          // 屏幕坐标（视图坐标，左下原点）
    var dim: CGFloat = 0
    var pixelSize = CGSize(width: 1920, height: 1080)
    /// 等比铺满（aspect fill），居中裁掉多余部分
    var imageRect: CGRect {
        let k = max(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
        let w = pixelSize.width * k, h = pixelSize.height * k
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }
    override func draw(_ r: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        image?.draw(in: imageRect)
        guard dim > 0 else { return }
        let path = NSBezierPath(rect: bounds)
        if let s = selection { path.append(NSBezierPath(rect: s)); path.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(dim).setFill(); path.fill()
        if let s = selection {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let b = NSBezierPath(rect: s.insetBy(dx: -0.5, dy: -0.5)); b.lineWidth = 1; b.setLineDash([5, 3], count: 2, phase: 0); b.stroke()
            let tag = "\(Int(s.width)) × \(Int(s.height))" as NSString
            tag.draw(at: NSPoint(x: s.maxX + 8, y: s.minY - 18), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white])
        }
    }
}

@MainActor
final class DemoScript {
    /// 录屏的是主显示器（带菜单栏的那块），舞台和窗口都放在这里
    static var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }
    let env = ProcessInfo.processInfo.environment
    var stage: NSWindow!
    let stageView = StageView()
    let keycap = HUD(size: 46, weight: .bold)
    let caption = HUD(size: 24, weight: .medium)
    var bg: NSImage!
    var bgCG: CGImage!              // 原始像素（Retina 上 NSImage.cgImage 会给出 2 倍图，不能用来裁剪）
    var firstLink: URL?
    var firstThreadTitle: String?

    func sleep(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    func start() { Task { await run() } }

    private func rects(_ key: String) -> [CGRect] {
        (env[key] ?? "").split(separator: ";").map { part in
            let v = part.split(separator: ",").compactMap { Double($0) }
            return v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : .zero
        }
    }

    private func say(_ s: String) async { caption.show(s, y: 36); await sleep(0.05) }
    private func keys(_ s: String, hold: Double = 1.1) async { keycap.show(s, y: DemoScript.screen.frame.height * 0.2); await sleep(hold); keycap.hide() }

    /// 背景图像素（左上原点）→ 舞台视图坐标（左下原点）
    private func toView(_ r: CGRect) -> CGRect {
        let ir = stageView.imageRect
        let k = ir.width / CGFloat(bgCG.width)
        return CGRect(x: ir.minX + r.minX * k, y: ir.maxY - r.maxY * k, width: r.width * k, height: r.height * k)
    }

    private func place(_ c: AnnotateController) {
        // 演示里窗口放大到屏幕的 62% 宽，录出来的视频里看得清
        c.window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)   // 浮在舞台之上
        let s = DemoScript.screen.frame
        let w = s.width * 0.62, h = min(w * 0.62, s.height * 0.72)
        c.window.setFrame(NSRect(x: s.midX - w / 2, y: s.midY - h / 2 + s.height * 0.04, width: w, height: h), display: true)
    }

    private func crop(_ r: CGRect) -> NSImage {
        // 用 NSBitmapImageRep 包一层：NSImage(cgImage:) 在 Retina 上会报告 2 倍像素，批注坐标就错了
        let rep = NSBitmapImageRep(cgImage: bgCG.cropping(to: r)!)
        let img = NSImage(size: NSSize(width: r.width, height: r.height)); img.addRepresentation(rep)
        return img
    }

    /// 模拟拖拽框选：选框从左上角拉到右下角
    private func drag(_ r: CGRect) async {
        let v = toView(r)
        stageView.dim = 0.35; stageView.selection = nil; stageView.needsDisplay = true
        NSCursor.crosshair.set()
        await sleep(0.45)
        let steps = 26
        for i in 1...steps {
            let f = CGFloat(i) / CGFloat(steps), e = 1 - pow(1 - f, 3)
            stageView.selection = CGRect(x: v.minX, y: v.maxY - v.height * e, width: v.width * e, height: v.height * e)
            stageView.needsDisplay = true
            await sleep(0.028)
        }
        await sleep(0.35)
        stageView.dim = 0; stageView.selection = nil; stageView.needsDisplay = true
    }

    private func annotate(_ c: AnnotateController, box: CGRect, note: String) async {
        let h = c.canvas.ih
        let full = CGRect(x: box.minX, y: h - box.maxY, width: box.width, height: box.height)
        c.window.makeFirstResponder(nil)
        await sleep(0.5)
        let steps = 22
        for i in 1...steps {
            let f = CGFloat(i) / CGFloat(steps)
            c.canvas.current = .rect(CGRect(x: full.minX, y: full.maxY - full.height * f, width: full.width * f, height: full.height * f))
            c.canvas.needsDisplay = true
            await sleep(0.03)
        }
        c.canvas.current = nil; c.canvas.marks = [.rect(full)]; c.canvas.needsDisplay = true
        await sleep(0.3)
        c.window.makeFirstResponder(c.note)
        let chars = Array(note)
        for n in 1...max(chars.count, 1) where !chars.isEmpty { c.note.string = String(chars.prefix(n)); await sleep(0.045) }
    }

    private func waitSent(_ c: AnnotateController) async -> DeliveryResult? {
        if env["T3SHOT_DEMO_DRYRUN"] == "1" {   // 彩排：不真正投递
            c.setStatus("（彩排）跳过投递"); await sleep(1.5)
            return DeliveryResult(message: "彩排", link: nil)
        }
        var result: DeliveryResult?
        c.onSent = { result = $0 }
        c.send()
        for _ in 0..<160 { if result != nil || !c.isSending { break }; await sleep(0.25) }
        return result
    }

    func run() async {
        guard let path = env["T3SHOT_DEMO_BG"], let img = NSImage(contentsOfFile: path) else { fputs("需要 T3SHOT_DEMO_BG\n", stderr); exit(2) }
        bg = img
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { exit(2) }
        bgCG = cg
        stageView.pixelSize = CGSize(width: cg.width, height: cg.height)
        let shots = rects("T3SHOT_DEMO_SHOTS"), boxes = rects("T3SHOT_DEMO_BOXES")
        let notes = (env["T3SHOT_DEMO_NOTES"] ?? "登录按钮在暗色模式下几乎看不清||补充：输入框边框也看不清").components(separatedBy: "||")
        let project = env["T3SHOT_DEMO_PROJECT"] ?? "acme-login-demo"
        guard shots.count >= 2, boxes.count >= 2, notes.count >= 2 else { fputs("演示参数不全\n", stderr); exit(2) }

        // 预热目标列表（真实读取所有环境）
        await Directory.shared.refresh()
        guard let newDest = Directory.shared.destinations.first(where: { $0.isNew && $0.project == project }) else {
            fputs("没有找到项目 \(project) 的 webhook 任务\n", stderr); exit(3)
        }
        UserDefaults.standard.set(newDest.key, forKey: "lastDestination")

        let screen = DemoScript.screen.frame
        stage = NSWindow(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
        stage.level = .floating; stage.isOpaque = true   // 演示期间盖住其他 App，避免被切到前台的窗口挡住
        stageView.image = bg; stage.contentView = stageView
        stage.setFrame(screen, display: true)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        stage.makeKeyAndOrderFront(nil)
        // 舞台就绪后才让录屏开始，避免拍到桌面上的其他窗口
        if let ready = env["T3SHOT_DEMO_READY"] { FileManager.default.createFile(atPath: ready, contents: Data("ready".utf8)) }
        await sleep(Double(env["T3SHOT_DEMO_LEAD"] ?? "3") ?? 3)

        await say("T3Shot：把截图批注投递进 T3，跨 MacBook / omarchy 两台机器")
        await sleep(2.6)

        // ① 新线程
        await say("① 全局快捷键 ⌃⇧4 唤起框选")
        await keys("⌃  ⇧  4")
        await drag(shots[0])
        let c1 = Agent.shared.open(image: crop(shots[0])); place(c1)
        await sleep(0.8)
        await say("画框、写一句说明；目标胶囊默认是「新线程 · \(project)」")
        await annotate(c1, box: boxes[0], note: notes[0])
        await sleep(1.4)
        await say("⌘↵ 发送：截图作为附件传到 omarchy，再触发项目 scheduler 的 webhook")
        await keys("⌘  ↵", hold: 0.8)
        let r1 = await waitSent(c1)
        firstLink = r1?.link
        await say(r1 != nil ? "webhook 建出了新线程，agent 已经在 omarchy 上开始处理" : "投递失败：见状态栏")
        await sleep(3.2)
        c1.window.performClose(nil)
        await sleep(0.6)

        // ② 跟进运行中的线程
        await Directory.shared.refresh()
        await say("② 再截一张，这次补充给刚才那个正在运行的线程")
        await keys("⌃  ⇧  4")
        await drag(shots[1])
        let c2 = Agent.shared.open(image: crop(shots[1])); place(c2)
        await sleep(0.8)
        await annotate(c2, box: boxes[1], note: notes[1])
        await sleep(0.6)
        await say("⌘K 打开目标选择器：每组只露出最相关的几条")
        await keys("⌘  K", hold: 0.8)
        c2.openPicker()
        await sleep(0.2)
        c2.pickerController?.raise()
        await sleep(2.2)
        guard let picker = c2.pickerController else { return finish() }
        let tid = firstLink.flatMap { $0.path.split(separator: "/").last.map(String.init)?.removingPercentEncoding }
        await say("运行中的线程排在前面，标着「排队跟进」")
        let match: (Destination) -> Bool = { d in
            if let tid { return d.threadId == tid }
            return !d.isNew && d.isActive && d.project == project
        }
        for _ in 0..<12 { if picker.stepToward(match) { break }; await sleep(0.32) }
        await sleep(1.0)
        await keys("↵", hold: 0.5)
        picker.activate()
        await say("选中后才出现投递语义：运行中 → 下一轮 follow-up 排队，不打断当前任务")
        await sleep(3.0)
        await keys("⌘  ↵", hold: 0.8)
        let r2 = await waitSent(c2)
        await say(r2 != nil ? "已排队为下一轮 follow-up" : "投递失败：见状态栏")
        await sleep(2.6)

        // ③ 回到 T3 看结果
        await say("点「打开线程」，在 T3 里看：新线程带着截图，follow-up 在队列里")
        await sleep(1.6)
        caption.hide()
        c2.window.orderOut(nil)
        stage.level = .normal; NSApp.presentationOptions = []
        // 舞台留在后面当底，只让 T3 Code 的窗口浮上来
        if let l = r2?.link ?? firstLink { T3Open.open(l) }
        await sleep(Double(env["T3SHOT_DEMO_TAIL"] ?? "16") ?? 16)
        finish()
    }

    func finish() {
        if let done = env["T3SHOT_DEMO_DONE"] { FileManager.default.createFile(atPath: done, contents: Data("done".utf8)) }
        NSApp.terminate(nil)
    }
}
