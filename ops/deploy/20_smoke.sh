#!/bin/bash
# ===== 20_smoke.sh — 冒烟验证（后台自治，约 40-70 分钟，日志 logs/smoke/）=====
# 逐级 go/no-go：S1 速测 → S2 全量加载 → S3 serve 联通 → S4 显存核查
set -u
BASE="$HOME/dsv41_deploy"; LOGS="$BASE/logs"; SM="$LOGS/smoke"
RT="$BASE/dsv41_runtime"; CKPT=/data/models/DeepSeek-V4.1-Flash
DEV="0,1,2,3,4,5,6,7"
mkdir -p "$SM"
exec > >(tee -a "$SM/smoke_main.txt") 2>&1
cd "$RT"
PY="$HOME/miniconda3/envs/dsv41/bin/python"
[ -f "$BASE/env_dsv41.sh" ] && source "$BASE/env_dsv41.sh"
echo "===== smoke @ $(date '+%F %T') ====="
GPUS=8

# 显存采样器（后台，写 csv；用完 kill $SAMPLER_PID，无模式匹配）
nvidia-smi --query-gpu=timestamp,index,memory.used --format=csv,noheader -l 10 > "$SM/vram_curve.csv" 2>&1 &
SAMPLER_PID=$!

echo "--- S1: 2 层速测（含 Engram 路径）---"
S1_START=$(date +%s)
timeout 900 "$PY" -m dsv41.run --ckpt "$CKPT" --devices 0 --n-layers 2 \
  --prompt "1+1=" --chat --max-new-tokens 8 --max-seq-len 512 > "$SM/s1_plumbing.txt" 2>&1
if [ $? -eq 0 ] && grep -qiE "2|two" "$SM/s1_plumbing.txt"; then
  echo "  [PASS] S1 速测通过（$(( $(date +%s) - S1_START ))s，含编译）"
else
  echo "  [FAIL] S1 速测异常 —— 查 $SM/s1_plumbing.txt"; kill $SAMPLER_PID 2>/dev/null; exit 1
fi

echo "--- S2: 8 卡全量加载 + 单条生成（冷加载预期 ~4 分钟）---"
S2_START=$(date +%s)
timeout 2400 "$PY" -m dsv41.chat --ckpt "$CKPT" --devices "$DEV" --max-seq-len 8192 <<'EOF' > "$SM/s2_full_load.txt" 2>&1
用一句话介绍你自己，然后计算 17*23。
/exit
EOF
S2_RC=$?
S2_ELAPSED=$(( $(date +%s) - S2_START ))
if [ $S2_RC -eq 0 ] && grep -q "391" "$SM/s2_full_load.txt"; then
  echo "  [PASS] S2 全量加载+生成通过（总耗时 ${S2_ELAPSED}s，17*23=391 正确）"
elif [ $S2_RC -eq 0 ]; then
  echo "  [WARN] S2 完成但答案校验未命中 391 —— 人工看 $SM/s2_full_load.txt"
else
  echo "  [FAIL] S2 失败（rc=$S2_RC，${S2_ELAPSED}s）—— 查 $SM/s2_full_load.txt（OOM 则考虑 --budgets 降预算）"
  kill $SAMPLER_PID 2>/dev/null; exit 1
fi
nvidia-smi --query-gpu=index,memory.used --format=csv > "$SM/s2_vram_after.txt"

echo "--- S3: serve 启动 + OpenAI 接口联通 ---"
PORT=8010
S3_START=$(date +%s)
timeout 3600 "$PY" -m dsv41.serve --ckpt "$CKPT" --devices "$DEV" --port $PORT --max-seq-len 32768 \
  > "$SM/s3_serve.log" 2>&1 &
SERVE_PID=$!
# 服务器端自旋等待就绪（最长 30 分钟，不依赖本地重连）
READY=0
for i in $(seq 1 180); do
  sleep 10
  if curl -s --max-time 5 "http://127.0.0.1:$PORT/v1/models" > "$SM/s3_models.json" 2>/dev/null; then
    READY=1; break
  fi
  kill -0 $SERVE_PID 2>/dev/null || break   # serve 进程没了就提前退出循环
done
if [ $READY -eq 1 ]; then
  echo "  [PASS] S3 serve 就绪（$(( $(date +%s) - S3_START ))s）—— /v1/models 响应："
  head -c 300 "$SM/s3_models.json"; echo
  echo "--- S3b: 一条 chat completion（记录首 token 延迟与吞吐）---"
  curl -s --max-time 600 http://127.0.0.1:$PORT/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"写一个 Python 函数判断素数，一句话解释。"}],"max_tokens":200,"stream":false}' \
    > "$SM/s3_completion.json" 2>&1
  if python3 -c "import json,sys; d=json.load(open('$SM/s3_completion.json')); c=d['choices'][0]['message']['content']; print('  [回复]', c[:120].replace(chr(10),' '))" 2>/dev/null; then
    echo "  [PASS] S3b chat completion 通过"
  else
    echo "  [WARN] S3b 响应异常 —— 查 $SM/s3_completion.json"
  fi
else
  echo "  [FAIL] S3 serve 30 分钟内未就绪 —— 查 $SM/s3_serve.log 尾部："
  tail -20 "$SM/s3_serve.log"
fi
kill $SERVE_PID 2>/dev/null; wait $SERVE_PID 2>/dev/null
sleep 5

echo "--- S4: 显存核查 ---"
MAX_USED=$(awk -F', ' 'NR>1{gsub(/ MiB/,"",$2); if($2>m)m=$2} END{print m}' "$SM/s2_vram_after.txt" 2>/dev/null || echo 0)
echo "  [INFO] S2 后单卡峰值显存: ${MAX_USED}MiB（预期 ~36000-40000MiB，若 >75000 则配置过紧）"

kill $SAMPLER_PID 2>/dev/null
echo
echo "===== smoke 完成 @ $(date '+%F %T') ====="
echo ">>> 全部产物在 $SM/。S1-S3 均通过即可执行 30_serve.sh 上线"
