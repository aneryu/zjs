#!/usr/bin/env bash
# codex 任务编排器：launch / status / show / reap
#
# 为什么不用 pgrep：`pgrep -f <pattern>` 会匹配到脚本自身的命令行（自匹配），
# 2026-08-12 因此连续两次误判——等待器永不触发、状态永远显示「运行中」，
# 掩盖了任务其实早已完成。这里改为「启动时落 PID + 完成时落 marker」。
set -uo pipefail
ROOT=${CODEX_RUN_ROOT:-/tmp/codex-runs}
mkdir -p "$ROOT"

usage() { cat <<'U'
用法:
  codex_run.sh launch <名字> <CPU> <worktree 路径> <prompt 文件>
  codex_run.sh status
  codex_run.sh show <名字>          # 打印该任务的结论
  codex_run.sh reap                 # 清掉已完成任务的残留进程
U
}

launch() {
  local name=$1 cpu=$2 wt=$3 prompt=$4
  [ -d "$wt" ] || { echo "worktree 不存在: $wt" >&2; return 2; }
  [ -f "$prompt" ] || { echo "prompt 不存在: $prompt" >&2; return 2; }
  local d="$ROOT/$name"; rm -rf "$d"; mkdir -p "$d"
  cp "$prompt" "$d/prompt.md"
  { echo "name=$name"; echo "cpu=$cpu"; echo "worktree=$wt"; echo "start=$(date +%s)"; } > "$d/meta"
  # 包装子 shell：无论 codex 怎么退出，都落 exit / conclusion / DONE 三个 marker
  setsid bash -c '
    d="$1"; wt="$2"
    codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
      -C "$wt" -m gpt-5.6-sol -c model_reasoning_effort="xhigh" \
      < "$d/prompt.md" > "$d/log" 2>&1
    echo $? > "$d/exit"
    tail -c 8000 "$d/log" | tr -d "\000" > "$d/conclusion.txt"
    date +%s > "$d/end"
    touch "$d/DONE"
  ' _ "$d" "$wt" >/dev/null 2>&1 &
  echo $! > "$d/pid"
  echo "已启动 $name  CPU=$cpu  worktree=$wt  pid=$(cat "$d/pid")  rundir=$d"
}

status() {
  printf "%-16s %-10s %-9s %-8s %-9s %-6s %s\n" 任务 状态 已运行 日志行 静默 CPU 最近产物
  printf "%.0s─" {1..104}; printf "\n"
  local now; now=$(date +%s)
  for d in "$ROOT"/*/; do
    [ -f "$d/meta" ] || continue
    local name cpu wt start st el lines silent art
    name=$(basename "$d"); cpu=$(sed -n 's/^cpu=//p' "$d/meta"); wt=$(sed -n 's/^worktree=//p' "$d/meta")
    start=$(sed -n 's/^start=//p' "$d/meta")
    if [ -f "$d/DONE" ]; then
      st="完成($(cat "$d/exit" 2>/dev/null || echo ?))"
      el=$(( $(cat "$d/end" 2>/dev/null || echo "$now") - start ))
    elif kill -0 "$(cat "$d/pid" 2>/dev/null || echo 0)" 2>/dev/null; then
      st=运行中; el=$(( now - start ))
    else
      st=异常退出; el=$(( now - start ))
    fi
    lines=$( [ -f "$d/log" ] && wc -l < "$d/log" || echo 0)
    silent=$( [ -f "$d/log" ] && echo $(( now - $(stat -c %Y "$d/log") )) || echo -)
    art=$(ls -t "$wt"/reports/perf/qjs-align/*/ 2>/dev/null | grep -v '^$' | grep -v ':' | head -1)
    printf "%-16s %-10s %-9s %-8s %-9s %-6s %s\n" \
      "$name" "$st" "$(printf '%dm%02ds' $((el/60)) $((el%60)))" "$lines" "${silent}s" "$cpu" "${art:--}"
  done
  echo
  echo "看结论: bash tools/perf/codex_run.sh show <名字>"
}

show() { local d="$ROOT/$1"; [ -f "$d/conclusion.txt" ] && cat "$d/conclusion.txt" || tail -c 8000 "$d/log" 2>/dev/null | tr -d '\000'; }

reap() {
  for d in "$ROOT"/*/; do
    [ -f "$d/DONE" ] || continue
    local p; p=$(cat "$d/pid" 2>/dev/null || echo 0)
    kill -0 "$p" 2>/dev/null && { kill -- -"$p" 2>/dev/null; echo "已回收 $(basename "$d") 的残留进程组 $p"; }
  done
  echo "回收完成"
}

case "${1:-}" in
  launch) shift; launch "$@" ;;
  status) status ;;
  show) shift; show "$@" ;;
  reap) reap ;;
  *) usage; exit 2 ;;
esac
