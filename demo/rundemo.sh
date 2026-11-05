#!/bin/bash
# 在 Mac 上：开始录屏 → 运行演示 → 等结束标记 → 停止录屏
OUT=${1:-/tmp/t3rec/demo.mov}; DRY=${2:-0}
rm -f /tmp/t3rec/done "$OUT"
echo "start $OUT" > /tmp/t3rec/cmd; sleep 1.5
open -n /tmp/t3shot-build/T3Shot.app \
  --env T3SHOT_DEMO_BG=/tmp/t3rec/stage.png \
  --env "T3SHOT_DEMO_SHOTS=670,425,580,205;670,530,580,150" \
  --env "T3SHOT_DEMO_BOXES=27,115,526,75;25,94,103,41" \
  --env "T3SHOT_DEMO_NOTES=登录按钮在暗色模式下几乎看不清，按 AGENTS.md 修一下对比度||补充：下面的「忘记密码？」链接也几乎看不见，一起按 token 修" \
  --env T3SHOT_DEMO_PROJECT=acme-login-demo \
  --env T3SHOT_DEMO_DONE=/tmp/t3rec/done \
  --env T3SHOT_DEMO_DRYRUN=$DRY --env T3SHOT_DEMO_TAIL=${TAIL:-16} \
  --stdout /tmp/t3rec/app.log --stderr /tmp/t3rec/app.err \
  --args --demo
for i in $(seq 1 300); do [ -f /tmp/t3rec/done ] && break; sleep 1; done
sleep 1; echo stop > /tmp/t3rec/cmd; sleep 4
ls -la "$OUT"; tail -5 /tmp/t3rec/app.err; tail -5 /tmp/t3rec/app.log
