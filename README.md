# T3Shot

macOS 原生截图批注工具：**⌃⇧4 框选 → 批注 → 投递到任意一台机器上的 T3**。两种投递方式：

- **新线程**：走项目 scheduler 的 webhook，在项目里新建线程。
- **跟进已有线程**：从所有环境里列出未 settle 的线程。运行中的线程用 `queue` 排进下一轮（follow-up，不 steer、不打断）；空闲线程直接开始新一轮。

界面采用 macOS 26 的 Liquid Glass（`NSGlassEffectView`）。

```
⌃⇧4 ─► 系统框选 ─► 批注窗口（画笔/矩形/说明 + 目标胶囊）
                         │  ⌘K 选择目标（渐进展开）
                         ▼
          截图作为 T3 原生附件上传到「目标线程所在的机器」
                         │
        ┌────────────────┴─────────────────┐
   新线程：POST 项目 webhook             跟进：t3_thread_send mode=queue
   (relay.t3.codes，离线时 relay 暂存)     / 空闲线程 t3_thread_send_attachments
```

## 跨环境：只跟 T3 自己的端点说话

T3Shot 不依赖 Tailscale 或 SSH。每个环境（运行 T3 的机器）都是一个 MCP 端点：

| 环境 | 端点 | 凭证 | 能力 |
|---|---|---|---|
| 本机（MacBook） | `~/.t3/userdata/server-runtime.json` 的 origin | 用本机 `t3 auth pairing create` 自动配对 | 读写 + 原生附件 |
| 远端（omarchy，24/7） | 它的 T3 Connect 地址 `https://prod-…t3coderelay.com` | 一次性配对码，和手机配对同一套机制 | 读写 + 原生附件 |
| 已链接、未配对 | 经本机 T3 的 environment link 转发（工具参数带 `environmentId`） | 复用本机凭证 | 读写，仅文字 |

配对走 T3 的 MCP OAuth（PKCE），用配对码代替浏览器审批，拿到 30 天 full-access 的 MCP 凭证，存在 `~/.config/t3shot/environments.json`（0600）。

```bash
# 在 omarchy 上签发配对码（10 分钟有效）
t3 auth pairing create --ttl 10m --label "T3Shot@MacBook"
# 在 Mac 上配对（远端地址见 Mac 上 `~/.t3/bin/t3 environment list`）
T3Shot --pair https://prod-xxxx.t3coderelay.com <配对码>
```

手机不运行 T3，只作为客户端经 T3 Connect 看到同样的线程，所以投递结果会出现在手机上。

## 构建与安装

需要 macOS 26+ 和 Xcode。

```bash
./build.sh --install    # 生成 ~/Applications/T3Shot.app，安装登录启动项并启动；⌃⇧4 生效
```

首次框选时系统会请求「屏幕与系统音频录制」权限。有 Apple Development 证书时 `build.sh` 会用它签名，重新编译后授权不会失效。

## 交互：渐进式暴露

1. **第 0 层**：批注窗口只有说明、一个目标胶囊、发送按钮。胶囊默认是上次用过的目标，否则是第一个可新建线程的项目，写完直接 ⌘↵。
2. **第 1 层**：点胶囊或 ⌘K，打开选择器。分两组，每组只露出最相关的几条：「新线程」（有 webhook 的项目）和「跟进线程」（运行中的在前）。agent 派生的线程默认不占名额。
3. **第 2 层**：点「还有 N 条…」或直接输入搜索，才显示全部线程、全部环境。环境在线和配对状态收在底部一行。

投递语义只在选中目标后才出现：按钮变成「新建线程」「排队跟进」或「发送」，提示行写明会发生什么。

快捷键：⌃⇧4 截图，⌘K 选目标（↑↓ 选择，↩ 确认），⌘↵ 发送，⌘Z 撤销批注。

## 项目的 webhook 入口：自动创建

T3Shot 把每个项目里**启用的、每次新建线程（不绑定线程）、不要求签名**的 webhook 定时任务当作「新线程」入口。

还没有入口的项目收在选择器第 2 层，标「启用」。选中后第一次投递时，T3Shot 会自动完成：

1. **补默认模型**：`schedule_task` 只认项目记录里的默认模型，所以先按 T3 界面新建线程时的顺序找：
   - 项目记录里的默认模型；
   - T3 界面里给这个项目设的默认模型（`settings.json` 的 `projectSettingsOverrides`）；
   - 环境默认模型（`settings.json` 的 `defaultModelSelection`）。

   后两层 MCP 读不到。本机直接读文件；远端退一步用该项目、再到该环境最近线程实际用的模型。找到后用 `t3_project_update` 写回项目记录，项目的实际行为不变。
2. **建任务**：用 `schedule_task` 建一个名为「T3Shot 截图批注」的 webhook 任务，使用统一的 prompt 模板。项目里已有同名任务就复用，不重复创建。
3. **投递**：照常投递，之后这个项目就是普通的「新线程」目标。

手动建的任务也可以，prompt 里能用这些占位符：

`{{body.note}}`、`{{body.image_delivered}}`、`{{body.image_remote_path}}`（目标机器上的截图路径，`~/.t3/userdata/attachments/<id>.png`）、`{{body.image_attachment_id}}`、`{{body.host}}`、`{{body.created_at}}`、`{{body.environment}}`。

webhook 只能带文本，所以截图会先作为 T3 附件上传到项目所在机器，再把路径写进请求体。附件 24 小时后会被 T3 清理。

## 命令行

```bash
T3Shot --list                                   # 列出环境和全部投递目标（带 key）
T3Shot --send <key 或标题片段> --image a.png --note "说明"   # 无界面投递，用于 e2e
T3Shot --image a.png                            # 直接批注一张图
T3Shot --demo                                   # 录屏用的自动演示，见 Sources/Demo.swift
```

## 已知限制

- 未配对、只经链接转发的环境不能传图，只发文字。
- 要求签名的 webhook 任务不会出现在列表里，因为 T3Shot 拿不到它的密钥。
- relay 在 Cloudflare 后面，请求固定带 `User-Agent: t3shot/2.0`，默认 UA 会被拦成 403/1010。
