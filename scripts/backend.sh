#!/usr/bin/env bash
# 后端开发服务启停脚本：go run ./cmd/server
# 用法: scripts/backend.sh {start|stop|restart|status}
set -euo pipefail
set -m # 让后台任务拥有独立进程组，stop 时能一并杀掉 go run 派生出的编译产物子进程

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$ROOT_DIR/backend"
RUN_DIR="$ROOT_DIR/scripts/.run"
PID_FILE="$RUN_DIR/backend.pid"
LOG_FILE="$RUN_DIR/backend.log"

mkdir -p "$RUN_DIR"

is_running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

backend_port() {
  awk '/^server:/{f=1;next} f&&/port:/{print $2;exit}' "$BACKEND_DIR/config.yaml" 2>/dev/null || echo "8080(默认，config.yaml 尚未生成)"
}

start() {
  if is_running; then
    echo "后端已在运行 (PID $(cat "$PID_FILE"))"
    exit 0
  fi
  echo "启动后端 (go run ./cmd/server)..."
  ( cd "$BACKEND_DIR" && exec go run ./cmd/server ) >"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  disown
  sleep 1
  if is_running; then
    echo "已启动，PID $(cat "$PID_FILE")，端口 $(backend_port)"
    echo "日志: $LOG_FILE"
  else
    echo "启动失败，请查看日志: $LOG_FILE" >&2
    rm -f "$PID_FILE"
    exit 1
  fi
}

stop() {
  if ! is_running; then
    echo "后端未在运行"
    rm -f "$PID_FILE"
    exit 0
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  echo "停止后端 (PID $pid)..."
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
    echo "后端运行中 (PID $(cat "$PID_FILE")，端口 $(backend_port))"
  else
    echo "后端未运行"
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
