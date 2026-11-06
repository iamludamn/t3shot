#!/bin/bash
# T3Shot 演示录屏守护（只为本次录屏临时使用，3 小时后自动退出）。
# 由 T3 子进程启动，从而继承 T3 Code 的「屏幕录制」授权；之后通过文件控制：
#   echo "start /tmp/t3rec/x.mov" > /tmp/t3rec/cmd   开始录制主显示器
#   echo stop > /tmp/t3rec/cmd                        停止（ffmpeg 正常收尾）
#   echo quit > /tmp/t3rec/cmd                        退出守护
D=/tmp/t3rec; mkdir -p "$D"; FF=/opt/homebrew/bin/ffmpeg
echo $$ > "$D/pid"; echo idle > "$D/state"
end=$(( $(date +%s) + 10800 ))
while [ "$(date +%s)" -lt "$end" ]; do
  if [ -f "$D/cmd" ]; then
    c=$(cat "$D/cmd"); rm -f "$D/cmd"
    case "$c" in
      start\ /tmp/t3rec/*.mov)
        out="${c#start }"
        "$FF" -y -f avfoundation -framerate 30 -capture_cursor 0 -i "Capture screen 0" -t 300 \
              -c:v h264_videotoolbox -b:v 10M -pix_fmt yuv420p "$out" > "$D/ff.log" 2>&1 < /dev/null &
        echo $! > "$D/ffpid"; echo recording > "$D/state" ;;
      rec\ /tmp/t3rec/*.mov)
        out="${c#rec }"; rm -f "$D/stop-rec"
        "$D/t3rec" "$out" 300 local.t3shot com.t3tools.t3code > "$D/rec.log" 2>&1 < /dev/null &
        echo $! > "$D/ffpid"; echo recording > "$D/state" ;;
      stop)
        if [ -f "$D/ffpid" ]; then kill -INT "$(cat "$D/ffpid")" 2>/dev/null; wait "$(cat "$D/ffpid")" 2>/dev/null; rm -f "$D/ffpid"; fi
        echo idle > "$D/state" ;;
      quit) exit 0 ;;
    esac
  fi
  sleep 0.3
done
