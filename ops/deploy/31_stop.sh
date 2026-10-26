#!/bin/bash
# ===== 31_stop.sh — 停止正式服务（tmux 会话名精确匹配，无 pkill 模式）=====
if tmux has-session -t dsv41 2>/dev/null; then
  tmux kill-session -t dsv41
  echo "tmux 会话 [dsv41] 已停止"
else
  echo "无 dsv41 会话在运行"
fi
sleep 3
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader
echo "（若显存未释放，稍等数秒后复查；仍有残留请告知，勿手工 kill）"
