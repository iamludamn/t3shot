#!/bin/bash
# T3Shot 测试流程（在 Mac 上跑）。用法：tests/run.sh [--live] [--gui]
#   默认      编译 + 离线自检（--selftest，不连网）
#   --live    再加：用真实 Cloudflare 和真实 T3 线程跑 --rank（需要已配好 Clef 凭证、本机 T3 在线）
#   --gui     再加：起批注窗口（--image 一次、--fullscreen 一次），等 Clef 判断完，断言胶囊带 ✨ 概率，并把窗口和 ⌘K 选择器存成 PNG（需要 Aqua 会话和 --live 的前置条件）
# 全程不碰 ~/Applications/T3Shot.app，不重启正在跑的常驻进程，不投递任何东西。
set -uo pipefail
cd "$(dirname "$0")/.."
LIVE=0; GUI=0
for a in "$@"; do case "$a" in --live) LIVE=1;; --gui) GUI=1; LIVE=1;; *) echo "未知参数 $a"; exit 64;; esac; done

OUT=$(mktemp -d "${TMPDIR:-/tmp}/t3shot-test.XXXXXX"); trap 'rm -rf "$OUT/build"' EXIT
BIN="$OUT/build/T3Shot.app/Contents/MacOS/T3Shot"
FAIL=0; ok() { echo "  ✓ $*"; }; bad() { echo "  ✗ $*"; FAIL=1; }
IMG=docs/demo/1-annotate-new-thread.png

echo "== 1 编译"
if ./build.sh "$OUT/build" >"$OUT/build.log" 2>&1; then ok "编译通过"; else bad "编译失败"; tail -30 "$OUT/build.log"; exit 1; fi
grep -c "warning:" "$OUT/build.log" | xargs -I{} echo "  · 编译警告 {} 条"

echo "== 2 离线自检"
"$BIN" --selftest 2>&1 | tee "$OUT/selftest.log" | grep -E "^(  ✗|结果|[^ ])" 
grep -q "^结果：.*，0 失败$" "$OUT/selftest.log" && ok "离线自检全部通过" || bad "离线自检有失败（见上）"

if [ "$LIVE" = 1 ]; then
  echo "== 3 真实环境：--rank"
  NOTE="登录按钮在暗色模式下几乎看不清，对比度太低"
  START=$(date +%s)
  if "$BIN" --rank "$IMG" --note "$NOTE" >"$OUT/rank.log" 2>&1; then
    cat "$OUT/rank.log" | sed 's/^/  /'
    N=$(grep -c '%  ' "$OUT/rank.log"); T=$(( $(date +%s) - START ))
    [ "$N" -ge 1 ] && ok "返回了 $N 个候选概率" || bad "没有候选概率"
    [ "$T" -le 20 ] && ok "总耗时 ${T}s（含读取各环境目录）" || bad "总耗时 ${T}s 太慢"
    TOP=$(grep -m1 '%  ' "$OUT/rank.log" | sed -E 's/^ *([0-9]+)%.*/\1/')
    [ "${TOP:-0}" -ge 30 ] && ok "最高概率 ${TOP}%" || bad "最高概率只有 ${TOP:-0}%，模型拿不准"
  else
    bad "--rank 失败"; sed 's/^/  /' "$OUT/rank.log"
  fi
fi

if [ "$GUI" = 1 ]; then
  echo "== 4 界面：窗口 + 选择器"
  if [ "$(launchctl managername 2>/dev/null)" != "Aqua" ]; then
    echo "  - 跳过：当前不是 Aqua 图形会话（launchctl managername=$(launchctl managername 2>/dev/null)）"
  else
    SNAP="$OUT/snap"
    T3SHOT_SNAPSHOT="$SNAP" T3SHOT_SNAPSHOT_DELAY=45 T3SHOT_NOTE="登录按钮在暗色模式下几乎看不清，对比度太低" \
      "$BIN" --image "$IMG" >"$OUT/gui.log" 2>&1 &
    PID=$!; for _ in $(seq 1 90); do kill -0 $PID 2>/dev/null || break; sleep 1; done; kill $PID 2>/dev/null
    grep -E "^(CHIP|STATUS|SUGGESTIONS|RANK|CLEF)" "$OUT/gui.log" | sed 's/^/  /'
    grep -q "^SNAPSHOT_DONE" "$OUT/gui.log" && ok "窗口跑完了快照流程" || { bad "没有跑到快照（窗口没起来？）"; tail -10 "$OUT/gui.log" | sed 's/^/  /'; }
    grep -q "^CHIP=.*✨[0-9]*%" "$OUT/gui.log" && ok "胶囊上带 ✨ 概率" || bad "胶囊上没有 ✨ 概率"
    S=$(grep -m1 '^SUGGESTIONS=' "$OUT/gui.log" | cut -d= -f2); [ "${S:-0}" -ge 1 ] && ok "选择器有 $S 条 Clef 推荐" || bad "没有 Clef 推荐"
    for f in window picker; do [ -s "$SNAP/$f.png" ] && ok "$f.png 已生成" || bad "$f.png 没生成"; done
    mkdir -p docs/test && cp "$SNAP"/*.png docs/test/ 2>/dev/null && echo "  · 截图已存到 docs/test/"
  fi
fi

if [ "$GUI" = 1 ] && [ "$(launchctl managername 2>/dev/null)" = "Aqua" ]; then
  echo "== 5 整屏截图（--fullscreen：和左右 Shift 快捷键走同一个截屏函数）"
  SNAP2="$OUT/snap-full"
  T3SHOT_SNAPSHOT="$SNAP2" T3SHOT_SNAPSHOT_DELAY=45 T3SHOT_NOTE="（整屏截图测试）说明一下当前屏幕上的内容" \
    "$BIN" --fullscreen >"$OUT/full.log" 2>&1 &
  PID=$!; for _ in $(seq 1 80); do kill -0 $PID 2>/dev/null || break; sleep 1; done; kill $PID 2>/dev/null
  if grep -q "截屏失败" "$OUT/full.log"; then
    echo "  - 跳过：截屏失败，当前进程没有「屏幕录制」权限"; grep -E "^截屏失败" "$OUT/full.log" | sed 's/^/    /'
  else
    grep -E "^(IMAGE|CHIP|STATUS|SUGGESTIONS|RANK|CLEF_WAIT)" "$OUT/full.log" | sed 's/^/  /'
    grep -q "^SNAPSHOT_DONE" "$OUT/full.log" && ok "整屏截图后窗口正常打开并跑完" || { bad "整屏截图流程没跑完"; tail -10 "$OUT/full.log" | sed 's/^/  /'; }
    W=$(grep -m1 '^IMAGE=' "$OUT/full.log" | sed -E 's/IMAGE=([0-9]+)x([0-9]+)pt/\1/'); [ "${W:-0}" -ge 800 ] && ok "截下的是整块屏幕（宽 ${W}pt）" || bad "截图宽度只有 ${W:-0}pt，不像整屏"
    grep -q "^CHIP=" "$OUT/full.log" && ok "胶囊有内容" || bad "没有胶囊内容"
    [ -s "$SNAP2/window.png" ] && ok "整屏窗口快照已生成" || bad "整屏窗口快照没生成"
    # 整屏截图含桌面上正在显示的内容：只留在临时目录，不复制进仓库
    echo "  · 整屏窗口快照：$SNAP2/window.png（含桌面内容，未复制进仓库）"
  fi
fi

echo; [ "$FAIL" = 0 ] && echo "全部通过" || echo "有失败项"
exit $FAIL
