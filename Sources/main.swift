// T3Shot — 原生 macOS 截图批注工具：⌃⇧4 框选 → 批注 → 投递到任意 T3 环境（新线程 / 跟进已有线程）。
//
// 用法：
//   T3Shot                        常驻菜单栏，左右 Shift 同时按 = 截整个屏幕并批注（⌃⇧4 框选区域）
//   T3Shot --fullscreen           截下鼠标所在的屏幕并打开批注窗口（单次运行，关掉就退出）
//   T3Shot --image 文件            直接批注一张图（投递后退出）
//   T3Shot --pair <T3 地址> <配对码>  配对一个 T3 环境（远端用它的 T3 Connect 地址；本机会自动配对）
//   T3Shot --list                 列出所有环境和投递目标
//   T3Shot --send <目标> --image 文件 [--note 说明]   无界面投递（<目标> 是 --list 里的 key 或标题片段）
//   T3Shot --cf-auth <账号 ID>     从标准输入读 Cloudflare API token，存到 ~/.config/t3shot/cloudflare.json（0600），启用 Clef 看图判断目标
//   T3Shot --cf-wrangler <账号 ID> 用 wrangler 的 OAuth 登录态（自动续期，免建 API token）
//   T3Shot --selftest             离线自检（桩掉 Cloudflare 和 T3），全部通过退出码 0
//   T3Shot --rank 图片 [--note 说明]   用 Clef 给图片判断目标，打印候选概率排序（不投递）
//   T3Shot --install-agent        安装登录启动项（LaunchAgent）
//   T3Shot --demo                 录屏用的自动演示（见 Demo.swift）
import AppKit

var args = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
func has(_ flag: String) -> Bool { if let i = args.firstIndex(of: flag) { args.remove(at: i); return true }; return false }

func runCLI(_ body: @escaping @MainActor () async throws -> Void) -> Never {
    Task { @MainActor in
        do { try await body(); exit(0) } catch { fputs("错误：\(error.localizedDescription)\n", stderr); exit(1) }
    }
    dispatchMain()
}

if has("--pair") {
    guard args.count >= 2 else { fputs("用法：T3Shot --pair <T3 地址> <配对码>\n", stderr); exit(64) }
    let url = args[0], code = args[1]
    runCLI {
        let rec = try await Pairing.pair(baseURL: url, code: code)
        EnvStore.upsert(rec)
        print("已配对：\(rec.label)（\(rec.id)），凭证有效期至 \(Date(timeIntervalSince1970: rec.expiresAt))")
    }
}

if has("--list") {
    runCLI {
        await Directory.shared.refresh()
        for e in Directory.shared.envs {
            print("[\(e.online ? "在线" : "离线")] \(e.label) \(e.id) \(e.direct ? "已配对" : "经链接")\(e.error.map { " · \($0)" } ?? "")")
        }
        for d in Directory.shared.destinations {
            let kind = d.needsSetup ? "可启用" : d.isNew ? "新线程" : d.statusText.padding(toLength: 4, withPad: "　", startingAt: 0)
            print("  \(kind)  \(d.env.label) · \(d.title)  [\(d.key)]")
        }
    }
}

if let target = take("--send") {
    let image = take("--image"), note = take("--note") ?? ""
    runCLI {
        guard let image, let png = FileManager.default.contents(atPath: image) else { throw T3Error("需要 --image <png>") }
        await Directory.shared.refresh()
        let all = Directory.shared.destinations
        guard let d = all.first(where: { $0.key == target }) ?? all.first(where: { $0.title.contains(target) }) else { throw T3Error("找不到目标：\(target)") }
        print("→ \(d.isNew ? "新线程" : d.statusText) · \(d.env.label) · \(d.title)")
        let r = try await Delivery.deliver(d, note: note, png: png, fileName: (image as NSString).lastPathComponent)
        print("OK: \(r.message)"); if let l = r.link { print("LINK: \(l.absoluteString)") }
    }
}

if has("--selftest") {
    Task { exit(await SelfTest.run()) }
    dispatchMain()
}

if let account = take("--cf-wrangler") {
    runCLI {
        try Clef.saveCreds(accountId: account, token: nil)
        let t = try await Clef.accessToken(Clef.Creds(accountId: account, token: nil, useWrangler: true))   // 顺便验证登录态可用、必要时续期
        print("已改用 wrangler 登录态（\(Clef.wranglerConfigPath)），自动续期；当前 token 长度 \(t.count)")
    }
}

if let account = take("--cf-auth") {
    let token = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { fputs("用法：echo $CLOUDFLARE_AUTH_TOKEN | T3Shot --cf-auth <账号 ID>\n", stderr); exit(64) }
    do { try Clef.saveCreds(accountId: account, token: token); print("已保存到 \(Clef.credsPath)（0600）") } catch { fputs("错误：\(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}

if let image = take("--rank") {
    let note = take("--note") ?? ""
    runCLI {
        guard let png = FileManager.default.contents(atPath: image) else { throw T3Error("读不到图片 \(image)") }
        guard Clef.isConfigured else { throw T3Error("没有 Cloudflare 凭证：echo $CLOUDFLARE_AUTH_TOKEN | T3Shot --cf-auth <账号 ID>") }
        await Directory.shared.refresh()
        let cands = Clef.candidates(from: Directory.shared.destinations)
        print("候选 \(cands.count) 个")
        let t0 = Date()
        let r = try await Clef.rank(png: png, note: note, candidates: cands)
        print(String(format: "用时 %.1fs · confidence %.2f · 都不合适 %.0f%%", Date().timeIntervalSince(t0), r.confidence, r.noneProbability * 100))
        for s in r.ranked.prefix(8) {
            print(String(format: "%3.0f%%  ", s.probability * 100) + (s.dest.isNew ? "新线程 · \(s.dest.title)" : "\(s.dest.statusText) · \(s.dest.title)（\(s.dest.project)）") + "  [\(s.dest.key)]")
        }
    }
}

if has("--install-agent") {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let plist = NSString(string: "~/Library/LaunchAgents/local.t3shot.plist").expandingTildeInPath
    let dict: [String: Any] = ["Label": "local.t3shot", "ProgramArguments": [exe], "RunAtLoad": true, "KeepAlive": false,
                               "ProcessType": "Interactive", "LimitLoadToSessionType": "Aqua"]
    try? FileManager.default.createDirectory(atPath: (plist as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    (dict as NSDictionary).write(toFile: plist, atomically: true)
    let uid = getuid()
    _ = try? runProcess("/bin/launchctl", ["bootout", "gui/\(uid)/local.t3shot"])
    _ = try? runProcess("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist])
    print("已安装登录启动项：\(plist)")
    exit(0)
}

let mode: Agent.Mode
if has("--demo") { mode = .demo }
else if has("--fullscreen") { mode = .fullscreen }
else if let image = take("--image") { mode = .single(URL(fileURLWithPath: image)) }
else if args.isEmpty { mode = .resident }
else { fputs("未知参数 \(args.joined(separator: " "))\n", stderr); exit(64) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let agent = Agent(mode: mode)
    app.delegate = agent
    app.run()
}
