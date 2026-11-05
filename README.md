# T3Shot

macOS 原生截图批注工具：**框选截图 → 批注 → 通过 webhook 发给 T3 里的某个项目**。界面采用 macOS 26 的 Liquid Glass（`NSGlassEffectView`）。

```
框选截图 ──► 玻璃批注窗口（画笔 / 矩形 / 说明）──► scp 传图到远端 ──► POST webhook ──► T3 任务在项目里启动 agent
```

## 构建

需要 macOS 26+ 和 Xcode（SDK 含 `NSGlassEffectView`）。

```bash
./build.sh            # 生成 ~/Applications/T3Shot.app
open ~/Applications/T3Shot.app
```

首次框选截图时，系统会请求「屏幕与系统音频录制」权限，给 T3Shot 勾选即可。命令行：`T3Shot [--full] [--image 文件]`。

快捷键：⌘↵ 发送，⌘Z 撤销批注。

## 配置目标

`~/.config/t3shot/targets.json`（参考 `targets.example.json`，文件含带 token 的 URL，建议 `chmod 600`，不要提交）：

| 字段 | 说明 |
|---|---|
| `name` | 下拉框里显示的名字 |
| `url` | T3 任务的 Webhook URL |
| `scp` | 可选。`主机:远端目录/`，发送前先把截图传过去 |
| `signature` | 可选。`{header, encoding, prefix, secret}`，对请求体做 HMAC-SHA256 |

## 在 T3 里配套的任务

1. 在**包含代码的项目**里创建 webhook 任务（agent 在项目目录里工作，项目里没有代码它就找不到前端）。
2. prompt 里用占位符引用请求内容，只有写了才会进 prompt：`{{body.note}}`、`{{body.image_remote_path}}`、`{{body.image_delivered}}`、`{{body.host}}`、`{{body.created_at}}`、`{{body.image_path}}`。
3. 开启 T3 Connect 远程访问，任务才会有 Webhook URL。

发送的 JSON：`source`、`note`、`image_path`（本机路径）、`image_remote_path`（`scp` 后的远端路径）、`image_delivered`、`host`、`created_at`。

## 已知坑

- 中继在 Cloudflare 后面，默认的 `Python-urllib` User-Agent 会被拦成 403 / 1010，所以请求固定带 `User-Agent: t3shot/1.0`。
- webhook 只能带文本，图片走 `scp`，需要提前配好免密 ssh。
- 每次发送，T3 都会在目标项目里新建一个线程，需要定期归档。

## 自检（不发送）

```bash
T3Shot --image shot.png --demo --window-shot out.png
```

`T3SHOT_SLOW=1` 的慢速演示会在结尾真的发送，只用于录屏。
