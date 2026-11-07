// Clef.swift — 用 Cloudflare Workers AI 的 Clef（System One 决策模型）看截图，给出「投递到哪个线程」的候选排序。
//
// 做法：把批注后的截图和说明作为 state，把所有候选（已有线程 + 各项目的「新建线程」）作为一个 Choice 问题的选项，
// Clef 返回每个选项的概率。T3Shot 只用它排序和预选，不自动发送——始终由人确认。
//
// 凭证：环境变量 CLOUDFLARE_ACCOUNT_ID + CLOUDFLARE_AUTH_TOKEN（需要 Workers AI 权限），或 ~/.config/t3shot/cloudflare.json（0600）：
//   `T3Shot --cf-auth <账号 ID>` 从标准输入读 API token；`T3Shot --cf-wrangler <账号 ID>` 直接用 wrangler 的 OAuth 登录态并自动续期。
// 没有凭证时整个功能静默关闭。
// 模型：默认 clef（27B，上下文 65k）；T3SHOT_CLEF_MODEL=clef-flash 换成更快的 9B（上下文 24k）。
// 隐私：截图、说明、候选线程的标题和几十个字的消息摘录会发给 Cloudflare Workers AI（Clef 为零数据保留）。
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ClefSuggestion {
    let dest: Destination
    let probability: Double
}

struct ClefResult {
    /// 按概率从高到低，已去掉概率可以忽略的选项
    let ranked: [ClefSuggestion]
    /// 「都不合适」的概率
    let noneProbability: Double
    /// Clef 自己报的 confidence（概率分布的集中程度）
    let confidence: Double
    var top: ClefSuggestion? { ranked.first }
}

enum Clef {
    static var model: String {
        let m = getenv("T3SHOT_CLEF_MODEL").map { String(cString: $0) } ?? "clef"
        return m == "clef-flash" ? "clef-flash" : "clef"
    }
    static let credsPath = NSString(string: "~/.config/t3shot/cloudflare.json").expandingTildeInPath
    /// 预选规则：第一名至少 40%，并且领先第二名至少 10 个百分点。
    /// 真实数据里两个相近的候选常常是 49% / 37%，只看绝对值（50%）几乎永远预选不上；只看领先又会在 8% / 2% 时误选。
    static let preselectMinTop = 0.40
    static let preselectMinMargin = 0.10
    /// 选择器里「Clef 推荐」只列概率不低于它的候选
    static let minListedProbability = 0.05
    static func shouldPreselect(_ ranked: [ClefSuggestion]) -> Bool {
        guard let top = ranked.first, top.probability >= preselectMinTop else { return false }
        return top.probability - (ranked.dropFirst().first?.probability ?? 0) >= preselectMinMargin - 1e-9
    }
    static let timeout: TimeInterval = 15

    /// cloudflare.json 有两种写法：
    ///   {"accountId":"…","token":"…"}         固定 token（API token 不会过期）
    ///   {"accountId":"…","source":"wrangler"} 用 wrangler 的 OAuth 登录态，access token 约 1 小时过期，T3Shot 自己用 refresh token 续期并写回
    struct Creds { let accountId: String; let token: String?; let useWrangler: Bool }
    static var creds: Creds? {
        func env(_ k: String) -> String? { getenv(k).map { String(cString: $0) } }
        if let a = env("CLOUDFLARE_ACCOUNT_ID"), let t = env("CLOUDFLARE_AUTH_TOKEN"), !a.isEmpty, !t.isEmpty { return Creds(accountId: a, token: t, useWrangler: false) }
        guard let d = FileManager.default.contents(atPath: credsPath),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: String], let a = j["accountId"], !a.isEmpty else { return nil }
        if j["source"] == "wrangler" { return Creds(accountId: a, token: nil, useWrangler: true) }
        guard let t = j["token"], !t.isEmpty else { return nil }
        return Creds(accountId: a, token: t, useWrangler: false)
    }
    static var isConfigured: Bool { creds != nil }

    static func saveCreds(accountId: String, token: String?) throws {
        let dir = (credsPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let obj: [String: String] = token.map { ["accountId": accountId, "token": $0] } ?? ["accountId": accountId, "source": "wrangler"]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        guard FileManager.default.createFile(atPath: credsPath, contents: data, attributes: [.posixPermissions: 0o600]) else { throw T3Error("写入凭证失败") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credsPath)
    }

    // MARK: wrangler 登录态续期

    /// wrangler 的配置文件位置：macOS 在 ~/Library/Preferences/.wrangler，Linux 在 ~/.config/.wrangler
    nonisolated(unsafe) static var wranglerPathOverride: String? = nil
    static var wranglerConfigPath: String {
        if let o = wranglerPathOverride { return o }
        let mac = NSString(string: "~/Library/Preferences/.wrangler/config/default.toml").expandingTildeInPath
        if FileManager.default.fileExists(atPath: mac) { return mac }
        return NSString(string: "~/.config/.wrangler/config/default.toml").expandingTildeInPath
    }

    static func tomlField(_ name: String, _ txt: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "^\(name) *= *\"([^\"]*)\"", options: .anchorsMatchLines),
              let m = re.firstMatch(in: txt, range: NSRange(txt.startIndex..., in: txt)), let r = Range(m.range(at: 1), in: txt) else { return nil }
        return String(txt[r])
    }
    static func setTomlField(_ name: String, _ value: String, _ txt: inout String) {
        guard let re = try? NSRegularExpression(pattern: "^\(name) *= *\"[^\"]*\"", options: .anchorsMatchLines) else { return }
        txt = re.stringByReplacingMatches(in: txt, range: NSRange(txt.startIndex..., in: txt),
                                          withTemplate: NSRegularExpression.escapedTemplate(for: "\(name) = \"\(value)\""))
    }

    /// 串行化：refresh token 每次刷新都会轮换，并发刷新会把对方的 refresh token 作废
    private actor WranglerToken {
        func current() async throws -> String {
            let path = Clef.wranglerConfigPath
            guard var txt = try? String(contentsOfFile: path, encoding: .utf8),
                  let access = Clef.tomlField("oauth_token", txt), let refresh = Clef.tomlField("refresh_token", txt) else {
                throw T3Error("找不到 wrangler 登录态（\(path)），先运行 wrangler login")
            }
            if let exp = parseISO(Clef.tomlField("expiration_time", txt)), exp.timeIntervalSinceNow > 120 { return access }
            // 过期了：用 wrangler 自己的 OAuth 客户端续期
            var req = URLRequest(url: URL(string: "https://dash.cloudflare.com/oauth2/token")!, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue(t3UserAgent, forHTTPHeaderField: "User-Agent")
            var c = URLComponents(); c.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token"), URLQueryItem(name: "refresh_token", value: refresh),
                                                      URLQueryItem(name: "client_id", value: "54d11594-84e4-41aa-b438-e81b8fa78ee7")]
            req.httpBody = Data((c.percentEncodedQuery ?? "").utf8)
            let (data, resp) = try await Clef.session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let newAccess = j["access_token"] as? String else {
                throw T3Error("wrangler 登录态续期失败，重新运行 wrangler login")
            }
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            Clef.setTomlField("oauth_token", newAccess, &txt)
            if let r = j["refresh_token"] as? String { Clef.setTomlField("refresh_token", r, &txt) }
            Clef.setTomlField("expiration_time", f.string(from: Date().addingTimeInterval((j["expires_in"] as? Double) ?? 3600)), &txt)
            try txt.write(toFile: path, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)   // 原子写入会换成默认权限
            return newAccess
        }
    }
    private static let wrangler = WranglerToken()

    static func accessToken(_ c: Creds) async throws -> String {
        if let t = c.token { return t }
        return try await wrangler.current()
    }

    // MARK: 候选

    /// 候选上限：Choice 最多 255 个选项。新线程入口全留，线程按最近更新取前 N 个；agent 派生的空闲线程不参与。
    static func candidates(from all: [Destination]) -> [Destination] {
        let news = all.filter { $0.isNew }.sorted { a, b in a.needsSetup != b.needsSetup ? !a.needsSetup : a.title < b.title }.prefix(40)
        let threads = all.filter { !$0.isNew && (!$0.byAgent || $0.isActive) }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }.prefix(100)
        return Array(news) + Array(threads)
    }

    // MARK: 线程摘要（标题之外，再给 Clef 一点这个线程在做什么）

    private actor Cache {
        var store: [String: String] = [:]
        func get(_ k: String) -> String? { store[k] }
        func set(_ k: String, _ v: String) { store[k] = v }
    }
    private static let cache = Cache()

    /// 发给第三方之前把像密钥的片段抹掉：常见的 API key 前缀、Bearer / token= 后面的值、长十六进制或 base64 串
    static func redact(_ s: String) -> String {
        let patterns = [
            #"(?i)\b(sk|pk|rk|ghp|gho|ghs|github_pat|xox[abprs]|glpat|npm|cfut|cfk)[-_][A-Za-z0-9_\-]{10,}"#,
            #"\bAKIA[0-9A-Z]{16}\b|\bAIza[0-9A-Za-z_\-]{30,}"#,
            #"(?i)\bbearer\s+[A-Za-z0-9._~+/\-]{8,}=*"#,
            #"(?i)(token|api[_-]?key|secret|password|passwd|authorization)["']?\s*[:=]\s*["']?[^\s"',;]{6,}"#,
            #"\b[A-Fa-f0-9]{32,}\b"#,
            #"\b(?=[A-Za-z0-9+_\-]*[A-Z])(?=[A-Za-z0-9+_\-]*[a-z])(?=[A-Za-z0-9+_\-]*\d)[A-Za-z0-9+_\-]{40,}={0,2}"#,
        ]
        var out = s
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[redacted]")
        }
        return out
    }

    private static func oneLine(_ s: Any?, _ n: Int) -> String {
        let t = redact((s as? String ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces))
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }

    /// 线程的第一条用户消息（起因）+ 最近的用户 / 助手消息。按线程更新时间缓存，线程没动就不重复读。
    static func digest(_ d: Destination) async -> String? {
        guard let tid = d.threadId else { return nil }
        let key = "\(d.env.id)|\(tid)|\(d.updatedAt?.timeIntervalSince1970 ?? 0)"
        if let hit = await cache.get(key) { return hit }
        let c = d.env.client
        guard let head = try? await c.call("t3_thread_read", ["threadId": tid, "limit": 1, "maxCharsPerItem": 240, "runLimit": 1], timeout: 8) else { return nil }
        let items = head["items"] as? [[String: Any]] ?? []
        let first = items.first { $0["type"] as? String == "user_message" }.map { oneLine($0["text"], 160) } ?? ""
        let count = (head["thread"] as? [String: Any])?["itemCount"] as? Int ?? 0
        var lastUser = "", lastAssistant = ""
        if count > 1, let tail = try? await c.call("t3_thread_read", ["threadId": tid, "afterPosition": max(0, count - 40), "limit": 20, "maxCharsPerItem": 240], timeout: 8) {
            for it in tail["items"] as? [[String: Any]] ?? [] {
                let text = oneLine(it["text"], 160)
                guard !text.isEmpty else { continue }
                if it["type"] as? String == "user_message" { lastUser = text } else if it["type"] as? String == "assistant_message" { lastAssistant = text }
            }
        }
        var parts: [String] = []
        if !first.isEmpty { parts.append("Started with: \(first)") }
        if !lastUser.isEmpty, lastUser != first { parts.append("Latest user message: \(lastUser)") }
        if !lastAssistant.isEmpty { parts.append("Latest assistant message: \(lastAssistant)") }
        let out = parts.joined(separator: " | ")
        await cache.set(key, out)
        return out
    }

    /// 给最近更新的几个线程预读摘要（刷新目录之后在后台做，按下快捷键时摘要已经是热的）
    static func prefetch(_ all: [Destination], limit: Int = 14) async {
        guard isConfigured else { return }
        let top = candidates(from: all).filter { !$0.isNew }.prefix(limit)
        await withTaskGroup(of: Void.self) { g in
            for d in top { g.addTask { _ = await digest(d) } }
        }
    }

    // MARK: 图片：Clef 接受 PNG / JPEG / WebP，单张 ≤ 4 MiB、≤ 16 百万像素；内部会缩到约 1 百万像素，所以先缩一下省上传

    static func prepareImage(_ png: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = Double(img.width), h = Double(img.height)
        let scale = min(1.0, 1568 / max(w, h))
        let nw = max(1, Int(w * scale)), nh = max(1, Int(h * scale))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let out = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, out, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return (data as Data).base64EncodedString()
    }

    // MARK: 请求

    static let instructions = """
    The user took a screenshot on their computer (the attached image) and drew on it (red strokes and boxes are their annotations); the typed note, if any, is in `user_note` of the state. \
    Decide where this feedback should go among the options: continue one of the existing agent threads, or start a NEW thread in one project. \
    Pick an existing thread when the screenshot or note clearly concerns what that thread is working on (same app, page, error, or topic). \
    Pick a "new thread" option when it clearly belongs to a project but no existing thread covers it. \
    Pick `none` when nothing fits or the screenshot gives too little to tell. \
    Thread descriptions are in whatever language the user wrote them in.
    """

    /// 网络层可替换：离线自检用 URLProtocol 桩替换成假的 Cloudflare
    nonisolated(unsafe) static var session: URLSession = .shared
    /// 候选线程摘要的来源可替换：自检时不连 T3
    nonisolated(unsafe) static var digestProvider: (@Sendable (Destination) async -> String?)? = nil

    static func rank(png: Data, note: String, candidates: [Destination]) async throws -> ClefResult {
        guard let creds else { throw T3Error("没有配置 Cloudflare 凭证") }
        guard let b64 = prepareImage(png) else { throw T3Error("截图无法转成 Clef 接受的格式") }
        guard !candidates.isEmpty else { throw T3Error("没有候选目标") }
        // 先把线程摘要凑齐（命中缓存很快；没命中的最多等几秒）
        var digests: [String: String] = [:]
        // 先挑线程再取前 30：candidates 里新线程入口排在前面（最多 40 个），直接 prefix 会把名额全占了，线程一条摘要都拿不到
        let threads = candidates.filter { !$0.isNew }.prefix(30)
        await withTaskGroup(of: (String, String?).self) { g in
            for d in threads {
                g.addTask {
                    // `??` 的右侧是 autoclosure，不能 await，所以拆开写
                    if let provider = digestProvider { return (d.key, await provider(d)) }
                    return (d.key, await digest(d))
                }
            }
            for await (k, v) in g { if let v, !v.isEmpty { digests[k] = v } }
        }
        var criteria: [String: Any] = [:]
        var byOption: [String: Destination] = [:]
        for (i, d) in candidates.enumerated() {
            let id = d.isNew ? String(format: "new%02d", i) : String(format: "thr%03d", i)
            byOption[id] = d
            var desc: String
            if d.isNew {
                desc = "Start a NEW thread in project \"\(d.project)\"" + (d.detail.isEmpty ? "" : " (directory \(d.detail))") + "."
            } else {
                desc = "Continue existing thread \"\(d.title)\" in project \"\(d.project)\" (\(d.statusText))."
                if let s = digests[d.key] { desc += " " + s }
            }
            criteria[id] = redact(desc)     // 出口统一脱敏：不依赖摘要来源（缓存 / 注入）是否已经处理过
        }
        criteria["none"] = "None of the above fits, or the screenshot does not give enough to tell."
        let body: [String: Any] = [
            "model": model,
            "images": [["content_type": "image/jpeg", "base64": b64]],
            "state": ["user_note": note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(no note)" : redact(note)],
            "questions": ["target": ["type": "choice", "instructions": instructions, "criteria": criteria]],
        ]
        let token = try await accessToken(creds)
        let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(creds.accountId)/ai/run/@cf/cloudflare/\(model)")!
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(t3UserAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let raw = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        // REST 接口把结果包在 result 里；Workers 绑定直接返回结果
        let json = (raw["result"] as? [String: Any]) ?? raw
        guard code == 200, raw["success"] as? Bool != false else {
            if code == 401 || code == 403 { throw T3Error("Cloudflare 凭证无效或没有 Workers AI 权限（HTTP \(code)）") }
            if code == 429 { throw T3Error("Clef 请求太频繁（429）") }
            let msg = ((raw["errors"] as? [[String: Any]])?.first?["message"] as? String) ?? String(data: data.prefix(160), encoding: .utf8) ?? ""
            throw T3Error("Clef HTTP \(code)：\(msg)")
        }
        guard let ans = (json["answers"] as? [String: Any])?["target"] as? [String: Any],
              let probs = ans["probabilities"] as? [String: Double] else { throw T3Error("Clef 返回的格式不认识") }
        let ranked = probs.compactMap { k, p -> ClefSuggestion? in
            guard p >= 0.02, let d = byOption[k] else { return nil }
            return ClefSuggestion(dest: d, probability: p)
        }.sorted { $0.probability > $1.probability }
        return ClefResult(ranked: ranked, noneProbability: probs["none"] ?? 0, confidence: ans["confidence"] as? Double ?? 0)
    }
}
