// SelfTest.swift — `T3Shot --selftest`：不连网、不碰真实 T3 和 Cloudflare 的离线自检。
// 覆盖 Clef 这条链路里不依赖界面的全部逻辑：脱敏、图片预处理、候选筛选、请求体、响应解析与错误、wrangler 续期。
// 网络层用 URLProtocol 桩替换成假的 Cloudflare。全部通过退出码 0，否则 1。
import AppKit

private final class Stub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, Data))?
    nonisolated(unsafe) static var seen: [(request: URLRequest, body: Data)] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {       // URLSession 会把 httpBody 换成流
            s.open(); defer { s.close() }
            var buf = [UInt8](repeating: 0, count: 65536)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
        }
        Stub.seen.append((request, body))
        let (code, data) = Stub.handler?(request, body) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum SelfTest {
    nonisolated(unsafe) static var passed = 0, failed = 0

    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("  ✓ \(name)") } else { failed += 1; print("  ✗ \(name)\(detail().isEmpty ? "" : " — " + detail())") }
    }
    static func group(_ t: String) { print("\n\(t)") }

    // MARK: 造数据

    static func png(_ w: Int, _ h: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: h)).fill()
        NSColor.red.setStroke(); NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: w / 2, height: h / 2)).stroke()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static let env = EnvHandle(id: "env1", label: "测试环境", client: MCPClient(base: URL(string: "http://127.0.0.1:1")!, token: ""), direct: true, isLocal: true)

    static func project(_ name: String, setup: Bool = false) -> Destination {
        var d = Destination(env: env, kind: setup ? .setupProject(projectModel: nil) : .newThread(webhook: "http://x/\(name)", taskTitle: "t"),
                            title: name, project: name, projectId: "p-\(name)", updatedAt: nil)
        d.detail = "/work/\(name)"
        return d
    }
    static func thread(_ id: String, _ title: String, project: String = "demo", status: String = "idle", age: TimeInterval = 0, byAgent: Bool = false) -> Destination {
        var d = Destination(env: env, kind: .thread(id: id, status: status), title: title, project: project, projectId: "p-\(project)",
                            updatedAt: Date().addingTimeInterval(-age))
        d.byAgent = byAgent
        return d
    }

    static func stubSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [Stub.self]
        return URLSession(configuration: c)
    }

    // MARK: 入口

    static func run() async -> Int32 {
        Clef.session = stubSession()
        redaction()
        images()
        candidates()
        toml()
        preselect()
        shiftChord()
        await rankRequestAndParsing()
        await rankErrors()
        await wranglerRefresh()
        print("\n结果：\(passed) 通过，\(failed) 失败")
        return failed == 0 ? 0 : 1
    }

    // MARK: 1 脱敏

    static func redaction() {
        group("脱敏（发给第三方之前）")
        let cases: [(String, String)] = [
            ("sk-abcdefghijklmnop123456", "OpenAI 风格 key"),
            ("ghp_abcdefghijklmnopqrstuvwxyz0123456789", "GitHub token"),
            ("Authorization: Bearer abcdef0123456789", "Bearer 头"),
            ("请用 token=abc123456789xyz 访问", "token= 赋值"),
            ("API_KEY: \"s3cr3t-value-123\"", "api_key 赋值"),
            ("password=hunter2hunter2", "password= 赋值"),
            ("AKIAIOSFODNN7EXAMPLE", "AWS access key id"),
            ("hash 0123456789abcdef0123456789abcdef01234567", "40 位十六进制"),
            ("AbCdEfGhIjKlMnOpQrStUvWxYz0123456789AbCdEf", "40+ 位混合大小写数字串"),
        ]
        for (text, name) in cases {
            let r = Clef.redact(text)
            check(r.contains("[redacted]"), "抹掉：\(name)", r)
        }
        let keep = [
            "登录页按钮在暗色模式下几乎看不清，对比度太低",
            "Continue the Dockerize POC Mail Client for IMAP thread",
            "/Users/a1234/AACS/PiStack/Sources/Controllers/MainViewController.swift",
            "thread 89cdc366-b82c-4e61-a45b-e63de1b2afce 还在跑",
            "PR #17 https://github.com/iamludamn/rav/pull/17",
            "修复 token 过期后的刷新逻辑，and the secret sauce of ranking",
        ]
        for t in keep { check(Clef.redact(t) == t, "不误伤：\(t.prefix(28))…", Clef.redact(t)) }
    }

    // MARK: 2 图片预处理

    static func images() {
        group("图片预处理（Clef：PNG/JPEG/WebP，≤4 MiB，≤16 MP）")
        for (w, h) in [(100, 40), (1, 1), (800, 600), (3000, 2000), (5120, 2880), (6000, 300)] {
            guard let b64 = Clef.prepareImage(png(w, h)), let data = Data(base64Encoded: b64),
                  let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                check(false, "\(w)×\(h) 能转成 JPEG"); continue
            }
            let longSide = max(img.width, img.height)
            let ratioKept = abs(Double(img.width) / Double(img.height) / (Double(w) / Double(h)) - 1) < 0.02 + 1.0 / Double(min(img.width, img.height))
            check(data.starts(with: [0xFF, 0xD8]) && longSide <= 1568 && data.count < 4 * 1024 * 1024 && (w > 1568 || h > 1568 || (img.width == w && img.height == h)) && ratioKept,
                  "\(w)×\(h) → \(img.width)×\(img.height)，\(data.count / 1024) KiB", "ratioKept=\(ratioKept)")
        }
        check(Clef.prepareImage(Data([1, 2, 3])) == nil, "损坏的图片返回 nil 而不是崩溃")
    }

    // MARK: 3 候选筛选

    static func candidates() {
        group("候选筛选")
        var all: [Destination] = (0..<70).map { project("proj\($0)") }
        all.append(project("needs-setup", setup: true))
        all += (0..<150).map { thread("t\($0)", "线程\($0)", age: Double($0) * 60) }
        all.append(thread("agent-idle", "agent 派生的空闲线程", age: 1, byAgent: true))
        all.append(thread("agent-run", "agent 派生但在运行", status: "running", age: 2, byAgent: true))
        let c = Clef.candidates(from: all)
        check(c.count <= 254, "不超过 Choice 的 255 个选项上限", "\(c.count)")
        check(c.filter { $0.isNew }.count == 40, "新线程入口最多 40 个", "\(c.filter { $0.isNew }.count)")
        check(c.filter { !$0.isNew }.count == 100, "线程最多 100 个", "\(c.filter { !$0.isNew }.count)")
        check(!c.contains { $0.threadId == "agent-idle" }, "agent 派生的空闲线程不参与")
        check(c.contains { $0.threadId == "agent-run" }, "agent 派生但在运行的线程参与")
        let threads = c.filter { !$0.isNew }
        check(zip(threads, threads.dropFirst()).allSatisfy { ($0.updatedAt ?? .distantPast) >= ($1.updatedAt ?? .distantPast) }, "线程按最近更新排序")
        check(c.prefix(40).allSatisfy { $0.isNew }, "新线程入口排在前面")
        check(!c.prefix(40).contains { $0.needsSetup } || all.filter { $0.isNew }.count <= 40, "还没入口的项目排在已有入口之后")
    }

    // MARK: 3b 预选规则

    static func preselect() {
        group("预选规则（第一名 ≥ 40% 且领先第二名 ≥ 10 个百分点）")
        func r(_ ps: [Double]) -> [ClefSuggestion] { ps.enumerated().map { ClefSuggestion(dest: thread("t\($0.offset)", "线程\($0.offset)"), probability: $0.element) } }
        check(Clef.shouldPreselect(r([0.49, 0.37])), "真实数据 49% / 37%：预选")
        check(Clef.shouldPreselect(r([0.80, 0.15])), "80% / 15%：预选")
        check(Clef.shouldPreselect(r([0.40])), "只有一个候选 40%：预选")
        check(!Clef.shouldPreselect(r([0.45, 0.44])), "45% / 44%：太接近，不预选")
        check(!Clef.shouldPreselect(r([0.30, 0.10])), "30% / 10%：第一名太低，不预选")
        check(!Clef.shouldPreselect(r([0.39, 0.05])), "39% 刚好不到 40%：不预选")
        check(!Clef.shouldPreselect([]), "没有候选：不预选")
    }

    // MARK: 3c 左右 Shift 同时按

    static func shiftChord() {
        group("左右 Shift 同时按（状态机）")
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func at(_ dt: TimeInterval) -> Date { t0.addingTimeInterval(dt) }

        var c = ShiftChord()
        check(!c.flagsChanged(left: true, right: false, otherModifiers: false, now: at(0)), "先按左 Shift：不触发")
        check(c.flagsChanged(left: true, right: true, otherModifiers: false, now: at(0.1)), "0.1 秒内再按右 Shift：触发")
        check(!c.flagsChanged(left: true, right: true, otherModifiers: false, now: at(0.2)), "同一次按住不重复触发")

        c = ShiftChord()
        _ = c.flagsChanged(left: false, right: true, otherModifiers: false, now: at(0))
        check(c.flagsChanged(left: true, right: true, otherModifiers: false, now: at(0.15)), "先按右后按左也触发（顺序无关）")

        c = ShiftChord()
        check(c.flagsChanged(left: true, right: true, otherModifiers: false, now: at(0)), "两个 Shift 在同一个事件里一起按下：触发")

        c = ShiftChord()
        _ = c.flagsChanged(left: true, right: false, otherModifiers: false, now: at(0))
        check(!c.flagsChanged(left: true, right: true, otherModifiers: false, now: at(0.6)), "间隔 0.6 秒：算先按住一个再按另一个，不触发")

        c = ShiftChord()
        _ = c.flagsChanged(left: true, right: false, otherModifiers: false, now: at(0))
        c.keyDown()
        check(!c.flagsChanged(left: true, right: true, otherModifiers: false, now: at(0.1)), "两个 Shift 之间按了别的键（打大写）：不触发")

        c = ShiftChord()
        _ = c.flagsChanged(left: true, right: false, otherModifiers: false, now: at(0))
        check(!c.flagsChanged(left: true, right: true, otherModifiers: true, now: at(0.1)), "同时按着 ⌘/⌃/⌥：不触发，避免和别的快捷键冲突")

        c = ShiftChord()
        check(!c.flagsChanged(left: true, right: false, otherModifiers: false, now: at(0)) && !c.flagsChanged(left: false, right: false, otherModifiers: false, now: at(0.1)),
              "只按一个 Shift 再松开：不触发")

        c = ShiftChord()
        _ = c.flagsChanged(left: true, right: false, otherModifiers: false, now: at(0))
        _ = c.flagsChanged(left: true, right: true, otherModifiers: false, now: at(0.1))            // 触发
        _ = c.flagsChanged(left: true, right: false, otherModifiers: false, now: at(0.3))           // 松开右
        check(!c.flagsChanged(left: true, right: true, otherModifiers: false, now: at(0.4)), "按住左不放、松紧右：不重复触发")
        _ = c.flagsChanged(left: false, right: false, otherModifiers: false, now: at(0.5))          // 全松开
        _ = c.flagsChanged(left: true, right: false, otherModifiers: false, now: at(0.6))
        check(!c.flagsChanged(left: true, right: true, otherModifiers: false, now: at(0.7)), "触发后 1 秒内再来一次：冷却中，不触发")
        _ = c.flagsChanged(left: false, right: false, otherModifiers: false, now: at(0.8))
        _ = c.flagsChanged(left: true, right: false, otherModifiers: false, now: at(2.0))
        check(c.flagsChanged(left: true, right: true, otherModifiers: false, now: at(2.1)), "过了冷却再按：触发")
    }

    // MARK: 4 toml

    static func toml() {
        group("wrangler toml 读写")
        var t = """
        oauth_token = "aaa"
        expiration_time = "2026-11-04T06:39:00.000Z"
        refresh_token = "rrr"
        scopes = [ "account:read", "ai:write" ]

        """
        check(Clef.tomlField("oauth_token", t) == "aaa" && Clef.tomlField("refresh_token", t) == "rrr", "读取字段")
        check(Clef.tomlField("missing", t) == nil, "缺失字段返回 nil")
        Clef.setTomlField("oauth_token", "n$ew\\tok", &t)
        check(Clef.tomlField("oauth_token", t) == "n$ew\\tok", "写入含 $ 和 \\ 的值不被当作模板", t)
        check(t.contains("scopes = [ \"account:read\", \"ai:write\" ]") && t.contains("refresh_token = \"rrr\""), "其他行原样保留")
    }

    // MARK: 5 请求体与响应解析

    static func rankRequestAndParsing() async {
        group("请求体与响应解析（桩 Cloudflare）")
        setenv("CLOUDFLARE_ACCOUNT_ID", "acct123", 1); setenv("CLOUDFLARE_AUTH_TOKEN", "tok-for-test", 1); setenv("T3SHOT_CLEF_MODEL", "clef", 1)
        Clef.digestProvider = { d in d.isNew ? nil : "Started with: 修登录页 sk-abcdefghijklmnop123456" }
        let cands = [project("alpha"), thread("b", "修登录按钮对比度"), thread("c", "无关线程")]
        Stub.seen = []
        Stub.handler = { _, _ in
            let body: [String: Any] = ["result": ["model": "clef", "answers": ["target": [
                "type": "choice", "choice": "thr001", "confidence": 0.42,
                "probabilities": ["thr001": 0.6, "new00": 0.3, "thr002": 0.01, "none": 0.09]]]], "success": true]
            return (200, try! JSONSerialization.data(withJSONObject: body))
        }
        do {
            let r = try await Clef.rank(png: png(640, 400), note: "按钮看不清 token=abc123456789", candidates: cands)
            check(r.ranked.map { $0.dest.key } == [cands[1].key, cands[0].key], "按概率排序，低于 2% 的丢掉", r.ranked.map { $0.dest.title }.joined(separator: ","))
            check(abs(r.ranked[0].probability - 0.6) < 1e-9 && abs(r.noneProbability - 0.09) < 1e-9 && abs(r.confidence - 0.42) < 1e-9, "概率、都不合适、confidence 解析正确")
            check(r.top?.dest.threadId == "b", "top 是线程 b")
        } catch { check(false, "rank 正常返回", error.localizedDescription) }

        guard let seen = Stub.seen.first else { check(false, "发出了一次请求"); return }
        let u = seen.request.url?.absoluteString ?? ""
        check(u == "https://api.cloudflare.com/client/v4/accounts/acct123/ai/run/@cf/cloudflare/clef", "地址包含账号和模型", u)
        check(seen.request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-for-test", "带 Bearer 凭证")
        let json = (try? JSONSerialization.jsonObject(with: seen.body) as? [String: Any]) ?? [:]
        check(json["model"] as? String == "clef", "model 字段")
        let images = json["images"] as? [[String: String]] ?? []
        check(images.count == 1 && images[0]["content_type"] == "image/jpeg" && (images[0]["base64"]?.count ?? 0) > 100, "images 里带一张 JPEG")
        let q = (json["questions"] as? [String: Any])?["target"] as? [String: Any]
        let criteria = q?["criteria"] as? [String: String] ?? [:]
        check(q?["type"] as? String == "choice", "只有一个 Choice 问题")
        check(Set(criteria.keys) == ["new00", "thr001", "thr002", "none"], "选项 = 每个候选 + none", criteria.keys.sorted().joined(separator: ","))
        check(criteria["new00"]?.contains("NEW thread") == true && criteria["new00"]?.contains("/work/alpha") == true, "新线程选项带项目目录")
        check(criteria["thr001"]?.contains("修登录按钮对比度") == true && criteria["thr001"]?.contains("修登录页") == true, "线程选项带标题和摘要")
        check(!(String(data: seen.body, encoding: .utf8) ?? "").contains("sk-abcdefghijklmnop123456") && !(String(data: seen.body, encoding: .utf8) ?? "").contains("abc123456789"),
              "摘要和说明里的密钥已脱敏，不在请求体里")
        let state = json["state"] as? [String: String]
        check(state?["user_note"]?.contains("按钮看不清") == true, "说明原文保留（除密钥外）")
        check((q?["instructions"] as? String)?.contains("attached image") == true, "指令里提到附带的图片")

        // 没写说明
        Stub.seen = []
        _ = try? await Clef.rank(png: png(400, 300), note: "   ", candidates: cands)
        let j2 = (try? JSONSerialization.jsonObject(with: Stub.seen.first?.body ?? Data()) as? [String: Any]) ?? [:]
        check((j2["state"] as? [String: String])?["user_note"] == "(no note)", "没写说明时明确告诉模型")

        // 换成 clef-flash
        setenv("T3SHOT_CLEF_MODEL", "clef-flash", 1); Stub.seen = []
        _ = try? await Clef.rank(png: png(400, 300), note: "x", candidates: cands)
        check(Stub.seen.first?.request.url?.absoluteString.hasSuffix("/clef-flash") == true, "T3SHOT_CLEF_MODEL=clef-flash 切换模型")
        setenv("T3SHOT_CLEF_MODEL", "clef", 1)

        // 新线程入口很多（候选里排在线程前面）时，线程的摘要仍然要带上
        let many = (0..<40).map { project("p\($0)") } + [thread("b", "修登录按钮对比度")]
        Stub.seen = []
        _ = try? await Clef.rank(png: png(400, 300), note: "x", candidates: Clef.candidates(from: many))
        let j3 = (try? JSONSerialization.jsonObject(with: Stub.seen.first?.body ?? Data()) as? [String: Any]) ?? [:]
        let c3 = ((j3["questions"] as? [String: Any])?["target"] as? [String: Any])?["criteria"] as? [String: String] ?? [:]
        check(c3.values.contains { $0.contains("Started with") }, "40 个新线程入口时，线程摘要不会被挤掉")

        // Workers 绑定风格的响应（没有 result 外壳）
        Stub.handler = { _, _ in
            (200, try! JSONSerialization.data(withJSONObject: ["answers": ["target": ["choice": "new00", "confidence": 1.0, "probabilities": ["new00": 1.0]]]]))
        }
        if let r = try? await Clef.rank(png: png(400, 300), note: "x", candidates: cands) { check(r.top?.dest.isNew == true && r.ranked.count == 1, "也能解析没有 result 外壳的响应") }
        else { check(false, "也能解析没有 result 外壳的响应") }
    }

    // MARK: 6 错误处理

    static func rankErrors() async {
        group("错误处理")
        let cands = [project("alpha")]
        func expectError(_ name: String, _ code: Int, _ body: [String: Any], contains: String) async {
            Stub.handler = { _, _ in (code, try! JSONSerialization.data(withJSONObject: body)) }
            do { _ = try await Clef.rank(png: png(300, 300), note: "", candidates: cands); check(false, name, "没有抛错") }
            catch { check(error.localizedDescription.contains(contains), name, error.localizedDescription) }
        }
        await expectError("401 → 提示凭证无效", 401, ["success": false, "errors": [["message": "bad"]]], contains: "凭证")
        await expectError("403 → 提示没有 Workers AI 权限", 403, ["success": false], contains: "Workers AI")
        await expectError("429 → 提示太频繁", 429, [:], contains: "429")
        await expectError("500 带 Cloudflare 错误信息", 500, ["success": false, "errors": [["message": "model overloaded"]]], contains: "model overloaded")
        await expectError("200 但 success=false", 200, ["success": false, "errors": [["message": "quota"]]], contains: "quota")
        await expectError("200 但格式不对", 200, ["result": ["answers": [:]], "success": true], contains: "格式")
        do { _ = try await Clef.rank(png: Data([0]), note: "", candidates: cands); check(false, "坏图片抛错") } catch { check(true, "坏图片抛错：\(error.localizedDescription)") }
        do { _ = try await Clef.rank(png: png(300, 300), note: "", candidates: []); check(false, "空候选抛错") } catch { check(true, "空候选抛错") }
    }

    // MARK: 7 wrangler 续期

    static func wranglerRefresh() async {
        group("wrangler 登录态续期（桩 OAuth）")
        let dir = NSTemporaryDirectory() + "t3shot-selftest-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/default.toml"
        defer { try? FileManager.default.removeItem(atPath: dir); Clef.wranglerPathOverride = nil }
        Clef.wranglerPathOverride = path
        let creds = Clef.Creds(accountId: "acct", token: nil, useWrangler: true)
        func write(expiry: String) {
            let t = "oauth_token = \"old-access\"\nexpiration_time = \"\(expiry)\"\nrefresh_token = \"old-refresh\"\nscopes = [ \"ai:write\" ]\n"
            FileManager.default.createFile(atPath: path, contents: Data(t.utf8), attributes: [.posixPermissions: 0o600])
        }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        write(expiry: f.string(from: Date().addingTimeInterval(3600)))
        Stub.seen = []
        Stub.handler = { _, _ in (500, Data()) }
        let t1 = try? await Clef.accessToken(creds)
        check(t1 == "old-access" && Stub.seen.isEmpty, "未过期：直接用现有 token，不发请求")

        write(expiry: "2026-01-01T00:00:00.000Z")
        Stub.seen = []
        Stub.handler = { _, _ in (200, try! JSONSerialization.data(withJSONObject: ["access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600])) }
        let t2 = try? await Clef.accessToken(creds)
        check(t2 == "new-access", "已过期：续期并返回新 token", t2 ?? "nil")
        let reqBody = String(data: Stub.seen.first?.body ?? Data(), encoding: .utf8) ?? ""
        check(Stub.seen.count == 1 && Stub.seen[0].request.url?.host == "dash.cloudflare.com" && reqBody.contains("grant_type=refresh_token")
              && reqBody.contains("refresh_token=old-refresh") && reqBody.contains("client_id=54d11594-84e4-41aa-b438-e81b8fa78ee7"), "续期请求：地址、grant_type、旧 refresh token、客户端 ID", reqBody)
        let after = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        check(Clef.tomlField("oauth_token", after) == "new-access" && Clef.tomlField("refresh_token", after) == "new-refresh", "新 token 和轮换后的 refresh token 写回文件")
        check(parseISO(Clef.tomlField("expiration_time", after)).map { $0.timeIntervalSinceNow > 3000 } == true, "过期时间更新为约一小时后")
        check(after.contains("scopes = [ \"ai:write\" ]"), "其他行原样保留")
        let perm = ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        check(perm == 0o600, "文件权限仍是 0600", String(perm, radix: 8))

        let t3 = try? await Clef.accessToken(creds)
        check(t3 == "new-access" && Stub.seen.count == 1, "再取一次不重复续期")

        write(expiry: "2026-01-01T00:00:00.000Z")
        Stub.handler = { _, _ in (400, Data("{}".utf8)) }
        do { _ = try await Clef.accessToken(creds); check(false, "续期被拒时抛错") }
        catch { check(error.localizedDescription.contains("wrangler login"), "续期被拒：提示重新 wrangler login", error.localizedDescription) }
        check(Clef.tomlField("refresh_token", (try? String(contentsOfFile: path, encoding: .utf8)) ?? "") == "old-refresh", "续期失败时不改动文件")

        try? FileManager.default.removeItem(atPath: path)
        do { _ = try await Clef.accessToken(creds); check(false, "没有 wrangler 配置时抛错") } catch { check(true, "没有 wrangler 配置时抛错：\(error.localizedDescription.prefix(30))") }
    }
}
