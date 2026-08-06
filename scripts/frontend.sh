#!/usr/bin/env bash
# 前端开发服务启停脚本：pnpm run dev
# 用法: scripts/frontend.sh {start|stop|restart|status}
set -euo pipefail
set -m # 让后台任务拥有独立进程组，stop 时能一并杀掉 pnpm 派生出的 vite 子进程

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRONTEND_DIR="$ROOT_DIR/frontend"
RUN_DIR="$ROOT_DIR/scripts/.run"
PID_FILE="$RUN_DIR/frontend.pid"
LOG_FILE="$RUN_DIR/frontend.log"

mkdir -p "$RUN_DIR"

is_running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

frontend_port() {
  local port
  port="$( { cat "$FRONTEND_DIR/.env.local" "$FRONTEND_DIR/.env"; } 2>/dev/null \
    | grep '^VITE_DEV_PORT=' | head -1 | cut -d= -f2 || true )"
  echo "${port:-3000(默认，未设置 VITE_DEV_PORT)}"
}

start() {
  if is_running; then
    echo "前端已在运行 (PID $(cat "$PID_FILE"))"
    exit 0
  fi
  if [ ! -d "$FRONTEND_DIR/node_modules" ]; then
    echo "未检测到 node_modules，先执行 pnpm install..."
    ( cd "$FRONTEND_DIR" && pnpm install )
  fi
  echo "启动前端 (pnpm run dev)..."
  ( cd "$FRONTEND_DIR" && exec pnpm run dev ) >"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  disown
  sleep 1
  if is_running; then
    echo "已启动，PID $(cat "$PID_FILE")，端口 $(frontend_port)"
    echo "日志: $LOG_FILE"
  else
    echo "启动失败，请查看日志: $LOG_FILE" >&2
    rm -f "$PID_FILE"
    exit 1
  fi
}

stop() {
  if ! is_running; then
    echo "前端未在运行"
    rm -f "$PID_FILE"
    exit 0
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  echo "停止前端 (PID $pid)..."
  kill -TERM -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 10); do
    is_running || break
    sleep 0.5
  done
  if is_running; then
    kill -KILL -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
  echo "已停止"
}

status() {
  if is_running; then
    echo "前端运行中 (PID $(cat "$PID_FILE")，端口 $(frontend_port))"
  else
    echo "前端未运行"
  fi
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  *)
    echo "用法: $0 {start|stop|restart|status}" >&2
    exit 1
    ;;
esac
