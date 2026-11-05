#!/bin/bash
# 在 Mac 上一键录制演示：起 ffmpeg 录主显示器 → 运行 T3Shot --demo → 等结束标记 → 停止录屏 → 出一张缩略拼图。
# 必须由有「屏幕录制」授权的进程启动（例如 T3 Code 派出的子 agent / 终端）。
# 用法：rundemo.sh <输出.mov> [DRYRUN=0|1]；环境变量 TAIL=演示结尾停留秒数
set -u
OUT=${1:-/tmp/t3rec/demo.mov}; DRY=${2:-0}; D=/tmp/t3rec; APP=${APP:-/tmp/t3shot-build/T3Shot.app}
mkdir -p "$D"; rm -f "$D/done" "$D/ready" "$OUT"
start_rec() {
/opt/homebrew/bin/ffmpeg -y -f avfoundation -framerate 30 -capture_cursor 0 -i "Capture screen 0" -t 300 \
  -c:v h264_videotoolbox -b:v 10M -pix_fmt yuv420p "$OUT" > "$D/ff.log" 2>&1 < /dev/null &
FF=$!
}
open -n "$APP" \
  --env T3SHOT_DEMO_BG="$D/stage.png" \
  --env "T3SHOT_DEMO_SHOTS=670,425,580,205;670,530,580,150" \
  --env "T3SHOT_DEMO_BOXES=27,115,526,75;25,94,103,41" \
  --env "T3SHOT_DEMO_NOTES=登录按钮在暗色模式下几乎看不清，按 AGENTS.md 修一下对比度||补充：下面的「忘记密码？」链接也几乎看不见，一起按 token 修" \
  --env T3SHOT_DEMO_PROJECT=acme-login-demo --env T3SHOT_DEMO_DONE="$D/done" --env T3SHOT_DEMO_READY="$D/ready" \
  --env T3SHOT_DEMO_DRYRUN="$DRY" --env T3SHOT_DEMO_TAIL="${TAIL:-16}" \
  --stdout "$D/app.log" --stderr "$D/app.err" --args --demo
# 等舞台铺满屏幕再开始录
for i in $(seq 1 60); do [ -f "$D/ready" ] && break; sleep 0.5; done
start_rec
for i in $(seq 1 280); do [ -f "$D/done" ] && break; sleep 1; done
sleep 1; kill -INT $FF; wait $FF 2>/dev/null
ls -la "$OUT"; echo "--- app.err"; tail -5 "$D/app.err"; echo "--- app.log"; tail -5 "$D/app.log"
rm -rf "$D/f"; mkdir -p "$D/f"
/opt/homebrew/bin/ffmpeg -loglevel error -i "$OUT" -vf "fps=1/3,scale=640:-1,tile=4x6:padding=4" -frames:v 1 "${OUT%.mov}-sheet.png"
ls -la "${OUT%.mov}-sheet.png"
