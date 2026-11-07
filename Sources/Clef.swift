// Clef.swift — 用 Cloudflare Workers AI 的 Clef（System One 决策模型）看截图，给出「投递到哪个线程」的候选排序。
//
// 做法：把批注后的截图和说明作为 state，把所有候选（已有线程 + 各项目的「新建线程」）作为一个 Choice 问题的选项，
// Clef 返回每个选项的概率。T3Shot 只用它排序和预选，不自动发送——始终由人确认。
//
// 凭证：环境变量 CLOUDFLARE_ACCOUNT_ID + CLOUDFLARE_AUTH_TOKEN（需要 Workers AI 权限），或 ~/.config/t3shot/cloudflare.json
// （0600，用 `T3Shot --cf-auth <账号 ID>` 从标准输入读 token 写入）。没有凭证时整个功能静默关闭。
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
        let m = ProcessInfo.processInfo.environment["T3SHOT_CLEF_MODEL"] ?? "clef"
        return m == "clef-flash" ? "clef-flash" : "clef"
    }
    static let credsPath = NSString(string: "~/.config/t3shot/cloudflare.json").expandingTildeInPath
    /// 最高概率达到它才自动预选到胶囊上；低于它只在选择器里排序展示，不改动当前目标
    static let preselectThreshold = 0.5
    static let timeout: TimeInterval = 15

    struct Creds { let accountId: String; let token: String }
    static var creds: Creds? {
        let env = ProcessInfo.processInfo.environment
        if let a = env["CLOUDFLARE_ACCOUNT_ID"], let t = env["CLOUDFLARE_AUTH_TOKEN"], !a.isEmpty, !t.isEmpty { return Creds(accountId: a, token: t) }
        guard let d = FileManager.default.contents(atPath: credsPath),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: String],
              let a = j["accountId"], let t = j["token"], !a.isEmpty, !t.isEmpty else { return nil }
        return Creds(accountId: a, token: t)
    }
    static var isConfigured: Bool { creds != nil }

    static func saveCreds(accountId: String, token: String) throws {
        let dir = (credsPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: ["accountId": accountId, "token": token], options: [.prettyPrinted, .sortedKeys])
        guard FileManager.default.createFile(atPath: credsPath, contents: data, attributes: [.posixPermissions: 0o600]) else { throw T3Error("写入凭证失败") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credsPath)
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

    private static func oneLine(_ s: Any?, _ n: Int) -> String {
        let t = (s as? String ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
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

    static func rank(png: Data, note: String, candidates: [Destination]) async throws -> ClefResult {
        guard let creds else { throw T3Error("没有配置 Cloudflare 凭证") }
        guard let b64 = prepareImage(png) else { throw T3Error("截图无法转成 Clef 接受的格式") }
        guard !candidates.isEmpty else { throw T3Error("没有候选目标") }
        // 先把线程摘要凑齐（命中缓存很快；没命中的最多等几秒）
        var digests: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { g in
            for d in candidates.prefix(30) where !d.isNew { g.addTask { (d.key, await digest(d)) } }
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
            criteria[id] = desc
        }
        criteria["none"] = "None of the above fits, or the screenshot does not give enough to tell."
        let body: [String: Any] = [
            "model": model,
            "images": [["content_type": "image/jpeg", "base64": b64]],
            "state": ["user_note": note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(no note)" : note],
            "questions": ["target": ["type": "choice", "instructions": instructions, "criteria": criteria]],
        ]
        let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(creds.accountId)/ai/run/@cf/cloudflare/\(model)")!
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(t3UserAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
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
