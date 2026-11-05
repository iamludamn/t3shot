// T3.swift — 与 T3 Code 服务端对话：MCP 客户端、配对（OAuth + 配对码）、环境登记、投递目标目录、投递。
//
// 跨环境的核心：T3Shot 只跟「T3 自己的 MCP 端点」说话，从不依赖 Tailscale / SSH。
//   · 本机环境（MacBook）：server-runtime.json 里的 origin，T3Shot 用本机 t3 CLI 自动签发配对码完成配对。
//   · 远端环境（omarchy 24/7）：它自己的 T3 Connect 地址（https://prod-…t3coderelay.com），用一次性配对码配对，
//     和手机配对是同一套机制。配对后图片能作为原生附件上传到线程所在的机器。
//   · 已链接但未配对的环境：经本机 T3 的 environment link 隧道转发（工具参数带 environmentId），只能发文字。
//   · 新线程：走该项目 scheduler 的 webhook（relay.t3.codes），目标机器离线时 relay 会暂存请求。
import Foundation

struct T3Error: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

let t3UserAgent = "t3shot/2.0"   // relay 在 Cloudflare 后面，默认 UA 会被拦成 403/1010

// MARK: - MCP 客户端（Streamable HTTP，JSON-RPC）

actor MCPClient {
    let base: URL
    let token: String
    /// 经本机 T3 的 environment link 转发到另一个环境时，给每个工具调用补上 environmentId。
    let routeEnvironmentId: String?
    private var sessionId: String?
    private var nextId = 1

    init(base: URL, token: String, routeEnvironmentId: String? = nil) {
        self.base = base; self.token = token; self.routeEnvironmentId = routeEnvironmentId
    }

    private func rpc(_ body: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any]? {
        var req = URLRequest(url: base.appendingPathComponent("mcp"), timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(t3UserAgent, forHTTPHeaderField: "User-Agent")
        if let sid = sessionId { req.setValue(sid, forHTTPHeaderField: "mcp-session-id"); req.setValue("2025-06-18", forHTTPHeaderField: "mcp-protocol-version") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        if let sid = http?.value(forHTTPHeaderField: "mcp-session-id") { sessionId = sid }
        let code = http?.statusCode ?? 0
        if code == 401 { throw T3Error("凭证失效（401），需要重新配对") }
        if code == 404, sessionId != nil { sessionId = nil; throw T3Error("session-expired") }
        guard (200..<300).contains(code) else { throw T3Error("MCP HTTP \(code)：\(String(data: data.prefix(160), encoding: .utf8) ?? "")") }
        var text = String(data: data, encoding: .utf8) ?? ""
        if (http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("event-stream") {
            text = text.split(separator: "\n").filter { $0.hasPrefix("data:") }.last.map { String($0.dropFirst(5)) } ?? ""
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    private func ensureSession() async throws {
        guard sessionId == nil else { return }
        _ = try await rpc(["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": [
            "protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "t3shot", "version": "2.0"]]])
        _ = try await rpc(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    /// 调用一个 T3 MCP 工具，返回 structuredContent。工具报错时抛出 T3 给出的 message。
    func call(_ tool: String, _ args: [String: Any] = [:], timeout: TimeInterval = 30) async throws -> [String: Any] {
        var args = args
        if let env = routeEnvironmentId, !tool.hasPrefix("t3_attachment"), tool != "t3_thread_send_attachments" { args["environmentId"] = env }
        for attempt in 0..<2 {
            try await ensureSession()
            nextId += 1
            do {
                guard let r = try await rpc(["jsonrpc": "2.0", "id": nextId, "method": "tools/call",
                                             "params": ["name": tool, "arguments": args]], timeout: timeout) else { throw T3Error("\(tool) 没有返回内容") }
                if let e = r["error"] as? [String: Any] { throw T3Error("\(tool)：\(e["message"] ?? "未知错误")") }
                let result = r["result"] as? [String: Any] ?? [:]
                let structured = result["structuredContent"] as? [String: Any]
                if result["isError"] as? Bool == true {
                    let msg = (structured?["message"] as? String) ?? ((result["content"] as? [[String: Any]])?.first?["text"] as? String)
                        .flatMap { t in (try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any])?["message"] as? String ?? t } ?? "失败"
                    throw T3Error(msg)
                }
                return structured ?? [:]
            } catch let e as T3Error where e.message == "session-expired" && attempt == 0 { continue }
        }
        throw T3Error("\(tool) 调用失败")
    }

    /// 把图片作为 T3 原生附件上传到这个端点所在的机器，返回 attachmentId。文件落在该机器的 ~/.t3/userdata/attachments/<id>.png。
    func uploadImage(_ png: Data, name: String) async throws -> String {
        let prep = try await call("t3_attachment_prepare_upload", ["upload": ["type": "image", "name": name, "mimeType": "image/png", "sizeBytes": png.count]])
        guard let id = prep["attachmentId"] as? String, let rel = prep["relativeUrl"] as? String,
              let url = URL(string: rel, relativeTo: base) else { throw T3Error("上传准备失败") }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"; req.httpBody = png
        req.setValue("image/png", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(t3UserAgent, forHTTPHeaderField: "User-Agent")
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw T3Error("图片上传返回 HTTP \(code)") }
        return id
    }
}

// MARK: - 环境登记（~/.config/t3shot/environments.json，0600）

struct EnvRecord: Codable {
    var id: String
    var label: String
    var url: String
    var token: String
    var expiresAt: Double      // epoch 秒
    var isLocal: Bool
}

enum EnvStore {
    static let path = NSString(string: "~/.config/t3shot/environments.json").expandingTildeInPath

    static func load() -> [EnvRecord] {
        guard let d = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([EnvRecord].self, from: d)) ?? []
    }
    static func save(_ envs: [EnvRecord]) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(envs) else { return }
        FileManager.default.createFile(atPath: path, contents: d, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    static func upsert(_ e: EnvRecord) {
        var all = load().filter { $0.id != e.id && !($0.isLocal && e.isLocal) }
        all.append(e); save(all)
    }

    // 本机 T3：runtime 文件给出 origin，t3 CLI 可以签发一次性配对码。
    static var localHome: String { ProcessInfo.processInfo.environment["T3CODE_HOME"] ?? NSString(string: "~/.t3").expandingTildeInPath }
    static func localOrigin() -> String? {
        guard let d = FileManager.default.contents(atPath: localHome + "/userdata/server-runtime.json"),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["origin"] as? String
    }
    static func localCLI() -> String? {
        [localHome + "/bin/t3", NSString(string: "~/.local/bin/t3").expandingTildeInPath, "/opt/homebrew/bin/t3", "/usr/local/bin/t3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 本机环境没配对或凭证 3 天内过期：用本机 t3 CLI 签发配对码，自动配对。
    static func ensureLocal() async throws -> EnvRecord? {
        if let e = load().first(where: { $0.isLocal }), e.expiresAt - Date().timeIntervalSince1970 > 3 * 86400 { return e }
        guard let origin = localOrigin(), let cli = localCLI() else { return nil }
        let out = try runProcess(cli, ["auth", "pairing", "create", "--ttl", "5m", "--label", "T3Shot", "--json"])
        guard let start = out.firstIndex(of: "{"),
              let j = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [String: Any],
              let code = j["credential"] as? String else { throw T3Error("本机 t3 CLI 没有签发出配对码") }
        var rec = try await Pairing.pair(baseURL: origin, code: code)
        rec.isLocal = true
        upsert(rec)
        return rec
    }
}

func runProcess(_ exe: String, _ args: [String]) throws -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw T3Error("\((exe as NSString).lastPathComponent) 退出码 \(p.terminationStatus)") }
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - 配对：T3 的 MCP OAuth（PKCE），用配对码代替浏览器审批，拿到 full-access 的 MCP 凭证（30 天）

enum Pairing {
    static func pair(baseURL: String, code: String) async throws -> EnvRecord {
        guard let base = URL(string: baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL) else { throw T3Error("地址无效") }
        let redirect = "http://127.0.0.1:47613/t3shot/callback"   // 只用来承载 code，不需要真的监听
        func send(_ path: String, json: [String: Any]? = nil, form: [String: String]? = nil) async throws -> [String: Any] {
            var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 30)
            req.setValue(t3UserAgent, forHTTPHeaderField: "User-Agent")
            if let json { req.httpMethod = "POST"; req.httpBody = try JSONSerialization.data(withJSONObject: json); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            if let form {
                var c = URLComponents(); c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
                req.httpMethod = "POST"; req.httpBody = Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
            let (d, r) = try await URLSession.shared.data(for: req)
            let obj = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            guard let h = r as? HTTPURLResponse, (200..<300).contains(h.statusCode) else {
                throw T3Error("\(path) → \((r as? HTTPURLResponse)?.statusCode ?? 0)：\(obj["error_description"] ?? obj["message"] ?? String(data: d.prefix(120), encoding: .utf8) ?? "")")
            }
            return obj
        }
        let meta = try await send(".well-known/oauth-protected-resource/mcp")
        guard let resource = meta["resource"] as? String else { throw T3Error("这个地址不是 T3 Code 服务") }
        let host = Host.current().localizedName ?? "Mac"
        let reg = try await send("oauth/mcp/register", json: ["client_name": "T3Shot · \(host)", "redirect_uris": [redirect], "token_endpoint_auth_method": "none"])
        guard let clientId = reg["client_id"] as? String else { throw T3Error("注册客户端失败") }
        let verifier = randomURLSafe(32)
        let challenge = sha256URLSafe(verifier)
        let auth: [String: Any] = ["response_type": "code", "client_id": clientId, "redirect_uri": redirect, "code_challenge": challenge,
                                   "code_challenge_method": "S256", "state": randomURLSafe(8), "resource": resource]
        let decision = try await send("oauth/mcp/decision", json: ["authorization": auth, "decision": ["_tag": "pairing-code", "access": "full-access", "code": code]])
        guard let to = decision["redirectTo"] as? String, let comps = URLComponents(string: to),
              let authCode = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw T3Error("配对码被拒绝：\(URLComponents(string: decision["redirectTo"] as? String ?? "")?.queryItems?.first { $0.name == "error_description" }?.value ?? "未知原因")")
        }
        let tok = try await send("oauth/mcp/token", form: ["grant_type": "authorization_code", "code": authCode, "redirect_uri": redirect,
                                                           "client_id": clientId, "code_verifier": verifier, "resource": resource])
        guard let token = tok["access_token"] as? String else { throw T3Error("没有拿到凭证") }
        let ttl = (tok["expires_in"] as? Double) ?? 30 * 86400
        let mcp = MCPClient(base: base, token: token)
        let info = try await mcp.call("t3_environment_read")
        return EnvRecord(id: info["environmentId"] as? String ?? UUID().uuidString, label: info["label"] as? String ?? base.host ?? "T3",
                         url: base.absoluteString, token: token, expiresAt: Date().timeIntervalSince1970 + ttl, isLocal: false)
    }
}

import CryptoKit
func randomURLSafe(_ n: Int) -> String {
    var b = [UInt8](repeating: 0, count: n); _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
    return Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
func sha256URLSafe(_ s: String) -> String {
    Data(SHA256.hash(data: Data(s.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

// MARK: - 投递目标目录

/// 一个能投递的 T3 环境。direct：T3Shot 自己持有这台机器的凭证（可传图）；否则经本机 link 转发（仅文字）。
final class EnvHandle: @unchecked Sendable {
    let id: String
    var label: String
    let client: MCPClient
    let direct: Bool
    let isLocal: Bool
    var online = false
    var error: String?
    init(id: String, label: String, client: MCPClient, direct: Bool, isLocal: Bool) {
        self.id = id; self.label = label; self.client = client; self.direct = direct; self.isLocal = isLocal
    }
}

struct Destination {
    enum Kind { case newThread(webhook: String, taskTitle: String), thread(id: String, status: String) }
    let env: EnvHandle
    let kind: Kind
    let title: String          // 新线程：项目名；跟进：线程标题
    let project: String
    let projectId: String
    let updatedAt: Date?
    var byAgent = false        // agent 派生出来的线程（委派、子任务）：默认收起，展开或搜索时才出现

    static let activeStatuses: Set<String> = ["preparing", "queued", "starting", "running", "waiting"]
    var key: String {
        switch kind { case .newThread: return "new|\(env.id)|\(projectId)"; case .thread(let id, _): return "thread|\(env.id)|\(id)" }
    }
    var isNew: Bool { if case .newThread = kind { return true }; return false }
    var isActive: Bool { if case .thread(_, let s) = kind { return Destination.activeStatuses.contains(s) }; return false }
    var threadId: String? { if case .thread(let id, _) = kind { return id }; return nil }
    var statusText: String {
        switch kind {
        case .newThread: return "新线程"
        case .thread(_, let s):
            switch s {
            case "running", "starting", "preparing": return "运行中"
            case "queued": return "排队中"
            case "waiting": return "等待回答"
            default: return "空闲"
            }
        }
    }
}

func parseISO(_ s: Any?) -> Date? {
    guard let s = s as? String else { return nil }
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}

func threadWebLink(env: String, thread: String) -> URL? {
    URL(string: "https://app.t3.codes/threads/\(env)/\(thread.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? thread)")
}

@MainActor
final class Directory {
    static let shared = Directory()
    private(set) var envs: [EnvHandle] = []
    private(set) var destinations: [Destination] = []
    private(set) var loadedAt: Date?
    private var inflight: Task<Void, Never>?
    var onChange: [() -> Void] = []

    /// 并发刷新所有环境：项目、带 webhook 的 scheduler 任务、未 settle 的线程。
    func refresh() async {
        if let t = inflight { return await t.value }
        let t = Task { @MainActor in
            var handles: [EnvHandle] = []
            let local = try? await EnvStore.ensureLocal()
            for r in EnvStore.load() where r.expiresAt > Date().timeIntervalSince1970 {
                guard let u = URL(string: r.url) else { continue }
                handles.append(EnvHandle(id: r.id, label: r.isLocal ? "\(r.label)（本机）" : r.label, client: MCPClient(base: u, token: r.token), direct: true, isLocal: r.isLocal))
            }
            // 已链接到本机、但 T3Shot 没有直接凭证的环境：经本机 T3 的 link 转发。
            if let local, let u = URL(string: local.url) {
                let localClient = MCPClient(base: u, token: local.token)
                if let links = try? await localClient.call("t3_environment_links")["links"] as? [[String: Any]] {
                    for l in links {
                        guard let id = l["environmentId"] as? String, !handles.contains(where: { $0.id == id }) else { continue }
                        let h = EnvHandle(id: id, label: l["label"] as? String ?? id, client: MCPClient(base: u, token: local.token, routeEnvironmentId: id), direct: false, isLocal: false)
                        if (l["status"] as? String) != "reachable" { h.error = "链接不可达" }
                        handles.append(h)
                    }
                }
            }
            struct Loaded: Sendable { let env: EnvHandle; let dests: [Destination]; let error: String? }
            let results = await withTaskGroup(of: Loaded.self) { group in
                for h in handles where h.error == nil {
                    group.addTask {
                        do { return Loaded(env: h, dests: try await Directory.load(h), error: nil) }
                        catch { return Loaded(env: h, dests: [], error: error.localizedDescription) }
                    }
                }
                var all: [Loaded] = []
                for await r in group { all.append(r) }
                return all
            }
            var dests: [Destination] = []
            for h in handles {
                guard let r = results.first(where: { $0.env === h }) else { continue }
                h.online = r.error == nil; h.error = r.error
                if ProcessInfo.processInfo.environment["T3SHOT_DEBUG"] == "1" { fputs("env \(h.label) dests=\(r.dests.count) err=\(r.error ?? "-")\n", stderr) }
                dests += r.dests
            }
            envs = handles; destinations = dests; loadedAt = Date()
            onChange.forEach { $0() }
        }
        inflight = t
        await t.value
        inflight = nil
    }

    nonisolated static func load(_ h: EnvHandle) async throws -> [Destination] {
        let c = h.client
        let info = try await c.call("t3_environment_read")
        if let l = info["label"] as? String, !h.isLocal { h.label = h.direct ? l : "\(l)（经链接）" }
        let projects = (try await c.call("t3_project_list", ["limit": 100])["projects"] as? [[String: Any]]) ?? []
        var names: [String: String] = [:]
        for p in projects { if let id = p["id"] as? String { names[id] = p["title"] as? String ?? id } }
        // 每个项目里「每次新建线程」的 webhook 任务 = 新线程入口
        let hooks: [Destination] = await withTaskGroup(of: [Destination].self) { g in
            for (pid, pname) in names {
                g.addTask {
                    guard let tasks = try? await c.call("list_scheduled_tasks", ["projectId": pid])["tasks"] as? [[String: Any]] else { return [] }
                    return tasks.compactMap { t in
                        guard (t["schedule"] as? [String: Any])?["type"] as? String == "webhook", t["enabled"] as? Bool != false,
                              t["boundThreadId"] is NSNull || t["boundThreadId"] == nil,
                              (t["webhookSignature"] as? String ?? "none") == "none",
                              let url = t["webhookUrl"] as? String else { return nil }
                        return Destination(env: h, kind: .newThread(webhook: url, taskTitle: t["title"] as? String ?? "webhook"),
                                           title: pname, project: pname, projectId: pid, updatedAt: nil)
                    }
                }
            }
            var out: [Destination] = []
            for await d in g { out += d }
            return out.sorted { $0.title < $1.title }
        }
        let threads = (try await c.call("t3_thread_list", ["allProjects": true, "settled": false, "snoozed": false, "includeSubagents": false, "limit": 60])["threads"] as? [[String: Any]]) ?? []
        let follow: [Destination] = threads.compactMap { t in
            guard let id = t["threadId"] as? String, t["parentThreadId"] is NSNull || t["parentThreadId"] == nil else { return nil }
            let pid = t["projectId"] as? String ?? ""
            var d = Destination(env: h, kind: .thread(id: id, status: t["status"] as? String ?? "idle"), title: t["title"] as? String ?? id,
                                project: names[pid] ?? "", projectId: pid, updatedAt: parseISO(t["updatedAt"]))
            d.byAgent = (t["createdBy"] as? String) == "agent"
            return d
        }
        return hooks + follow
    }
}

// MARK: - 投递

struct DeliveryResult { let message: String; let link: URL? }

enum Delivery {
    /// 新线程：先把图传到项目所在机器（能传的话），再 POST 项目的 scheduler webhook；之后在该项目里找到刚建出来的线程。
    /// 跟进：活跃线程用 queue（下一轮 follow-up，不打断当前轮）；空闲线程直接发起新一轮，能带原生附件就带。
    static func deliver(_ d: Destination, note: String, png: Data, fileName: String) async throws -> DeliveryResult {
        let host = Host.current().localizedName ?? "Mac"
        let started = Date()
        var attachmentId: String?
        var uploadError: String?
        if d.env.direct {
            do { attachmentId = try await d.env.client.uploadImage(png, name: fileName) } catch { uploadError = error.localizedDescription }
        } else { uploadError = "该环境未与 T3Shot 配对，只能经链接发文字" }
        let remotePath = attachmentId.map { "~/.t3/userdata/attachments/\($0).png" }

        switch d.kind {
        case .newThread(let webhook, _):
            let payload: [String: Any] = [
                "source": "t3shot", "note": note, "host": host,
                "created_at": ISO8601DateFormatter().string(from: started),
                "image_delivered": remotePath != nil, "image_remote_path": remotePath ?? "",
                "image_attachment_id": attachmentId ?? "", "image_path": fileName, "environment": d.env.label,
            ]
            var req = URLRequest(url: URL(string: webhook)!, timeoutInterval: 20)
            req.httpMethod = "POST"; req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(t3UserAgent, forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw T3Error("webhook 返回 \(code)：\(String(data: data.prefix(120), encoding: .utf8) ?? "")") }
            // webhook 只回 deliveryId；在项目里轮询刚创建的线程，拿到链接。
            var link: URL?; var title: String?
            for _ in 0..<16 {
                try? await Task.sleep(for: .seconds(1.5))
                if let ts = try? await d.env.client.call("t3_thread_list", ["projectId": d.projectId, "limit": 5])["threads"] as? [[String: Any]],
                   let t = ts.first(where: { (parseISO($0["createdAt"]) ?? .distantPast) >= started.addingTimeInterval(-3) }),
                   let tid = t["threadId"] as? String {
                    link = threadWebLink(env: d.env.id, thread: tid); title = t["title"] as? String; break
                }
            }
            let img = remotePath != nil ? "截图已作为附件送到 \(d.env.label)" : "图片未送达（\(uploadError ?? "")）"
            return DeliveryResult(message: title.map { "已新建线程「\($0)」· \(img)" } ?? "已投递到 webhook（HTTP \(code)），线程创建中 · \(img)", link: link)

        case .thread(let tid, let status):
            let active = Destination.activeStatuses.contains(status)
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            var text = "【T3Shot 截图批注 · 来自 \(host) · \(f.string(from: started))】\n\(note.isEmpty ? "（无文字说明）" : note)"
            if let p = remotePath, active { text += "\n\n截图（红色笔迹和红框是批注）：\(p)" }
            if remotePath == nil { text += "\n\n（截图未送达：\(uploadError ?? "未知原因")）" }
            let link = threadWebLink(env: d.env.id, thread: tid)
            if !active, let aid = attachmentId {
                // 空闲线程：原生附件 + 立即开始新一轮
                _ = try await d.env.client.call("t3_thread_send_attachments", ["threadId": tid, "message": text,
                    "attachments": [["type": "image", "id": aid, "name": fileName, "mimeType": "image/png", "sizeBytes": png.count]]])
                return DeliveryResult(message: "已发送，线程开始新一轮（截图为原生附件）", link: link)
            }
            // 活跃线程：follow-up 排队，不 steer、不打断
            let r = try await d.env.client.call("t3_thread_send", ["threadId": tid, "message": text, "mode": "queue",
                                                                   "clientRequestId": "t3shot-\(UUID().uuidString)"])
            let queued = (r["delivery"] as? String) == "queued"
            return DeliveryResult(message: queued ? "已排队为下一轮 follow-up，不打断当前任务" : "已发送，线程开始新一轮", link: link)
        }
    }
}
