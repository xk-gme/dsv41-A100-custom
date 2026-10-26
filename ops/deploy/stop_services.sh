#!/bin/bash
# ===== 停止 vLLM 服务（按 PID 精确停止，无模式匹配风险）=====
# 授权依据：用户 2026-10-25 指示"停掉所有服务，部署 dsv4.1"
LOG="$HOME/dsv41_deploy/logs/stop_services.txt"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo "=== stop_services @ $(date '+%F %T') ==="

# 1. 抓取 vllm serve 主进程 PID（脚本自身 cmdline 不含该串，无自杀风险）
MASTERS=$(ps -ef | grep "vllm serve" | grep -v grep | awk '{print $2}')
if [ -z "$MASTERS" ]; then
  echo "无 vllm serve 主进程在跑"
else
  echo "主进程 PID: $(echo $MASTERS | tr '\n' ' ')"
  # 2. SIGTERM 优雅停止
  for p in $MASTERS; do kill "$p" 2>/dev/null && echo "  SIGTERM -> $p"; done
fi

# 3. 最多等 120 秒让 Worker/EngineCore 退出
for i in $(seq 1 24); do
  sleep 5
  LEFT=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader | wc -l)
  [ $((i % 4)) -eq 0 ] && echo "  t+$((i*5))s: GPU 计算进程残留 $LEFT"
  [ "$LEFT" -eq 0 ] && break
done

# 4. 残留进程按精确 PID 强制清理
LEFT=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader | tr -d ' ')
if [ -n "$LEFT" ]; then
  echo "SIGKILL 残留: $(echo $LEFT | tr '\n' ' ')"
  for p in $LEFT; do kill -9 "$p" 2>/dev/null; done
  sleep 10
fi

echo "--- 最终 GPU 状态 ---"
nvidia-smi --query-gpu=index,memory.used,memory.free --format=csv,noheader
GPU_LEFT=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader | wc -l)
echo "=== 结果: GPU 计算进程 $GPU_LEFT 个 ==="
[ "$GPU_LEFT" -eq 0 ] && echo ">>> 全部停止，GPU 已释放" || echo ">>> 仍有残留，需人工检查"
