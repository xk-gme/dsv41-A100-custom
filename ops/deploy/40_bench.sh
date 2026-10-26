#!/bin/bash
# ===== 40_bench.sh — 基准测试（后台自治，约 30-60 分钟，日志 logs/bench/）=====
# 内容：单流吞吐 / 批量+MTP A/B / 上下文阶梯显存 / EP 对比
# 前提：20_smoke 已通过。运行期间不要同时起 serve。
set -u
BASE="$HOME/dsv41_deploy"; LOGS="$BASE/logs"; BM="$LOGS/bench"
RT="$BASE/dsv41_runtime"; CKPT=/data/models/DeepSeek-V4.1-Flash
DEV="0,1,2,3,4,5,6,7"
mkdir -p "$BM"
exec > >(tee -a "$BM/bench_main.txt") 2>&1
cd "$RT"
PY="$HOME/miniconda3/envs/dsv41/bin/python"
[ -f "$BASE/env_dsv41.sh" ] && source "$BASE/env_dsv41.sh"
echo "===== bench @ $(date '+%F %T') ====="

echo "--- B1: 单流吞吐（pipeline 模式，对照 README 基线 ~52 tok/s）---"
timeout 1800 "$PY" -m dsv41.run --ckpt "$CKPT" --devices "$DEV" --chat \
  --prompt "Write a detailed essay about the history of computing." \
  --max-new-tokens 256 --max-seq-len 8192 > "$BM/b1_single.txt" 2>&1
grep -iE "tok/s|tokens/s|t/s" "$BM/b1_single.txt" | tail -3 || echo "  [INFO] 速率行见 $BM/b1_single.txt（手工摘录）"

echo "--- B2: 批量 + MTP A/B（seqs=16，drafts=5 vs 关闭）---"
timeout 3600 "$PY" -m dsv41.mtp_run --ckpt "$CKPT" --devices "$DEV" --seqs 16 --drafts 5 \
  --max-new-tokens 128 > "$BM/b2_mtp_on.txt" 2>&1 \
  && echo "  [OK] MTP 开启组完成" || echo "  [FAIL] 查 $BM/b2_mtp_on.txt"
timeout 3600 "$PY" -m dsv41.mtp_run --ckpt "$CKPT" --devices "$DEV" --seqs 16 --no-mtp \
  --max-new-tokens 128 > "$BM/b2_mtp_off.txt" 2>&1 \
  && echo "  [OK] MTP 关闭组完成" || echo "  [FAIL] 查 $BM/b2_mtp_off.txt"

echo "--- B3: 上下文阶梯（32K/128K/256K 的显存与吞吐）---"
for CTX in 32768 131072 262144; do
  LONGP="$BM/ctx_prompt_${CTX}.txt"
  python3 - "$CTX" "$LONGP" <<'PYEOF'
import sys, random
ctx, path = int(sys.argv[1]), sys.argv[2]
random.seed(42)
words = ["alpha","beta","gamma","delta","epsilon","zeta","eta","theta","iota","kappa"]
# ~1 token/word：生成 ctx*0.75 个词的长提示（留 25% 生成空间）
n = int(ctx * 0.75)
with open(path, "w") as f:
    f.write("Summarize the following text in one sentence.\n\n")
    f.write(" ".join(random.choice(words) for _ in range(n)))
PYEOF
  timeout 3000 "$PY" -m dsv41.run --ckpt "$CKPT" --devices "$DEV" --chat \
    --prompt "Read the context and reply with the single word: OK" \
    --max-new-tokens 16 --max-seq-len "$CTX" > "$BM/b3_ctx${CTX}.txt" 2>&1 \
    && echo "  [OK] ctx=${CTX} 完成（结果见 b3_ctx${CTX}.txt）" \
    || echo "  [FAIL/OOM] ctx=${CTX} —— 记录为实际上限"
  nvidia-smi --query-gpu=index,memory.used --format=csv,noheader > "$BM/b3_vram_ctx${CTX}.txt"
done

echo "--- B4: EP 专家并行对比（注意：本机无 NVLink，跨插槽慢，结果可能不如 pipeline）---"
timeout 1800 "$PY" -m dsv41.run --ckpt "$CKPT" --devices "$DEV" --ep \
  --prompt "Write a detailed essay about the history of computing." \
  --max-new-tokens 256 --max-seq-len 8192 > "$BM/b4_ep.txt" 2>&1 \
  && echo "  [OK] EP 组完成（与 B1 对比 tok/s）" || echo "  [FAIL] EP 模式失败（P2P 不可用则放弃此路线）"

echo
echo "===== bench 完成 @ $(date '+%F %T') ====="
echo ">>> 汇总请人工摘录到 logs/bench_summary.txt 并回填部署研究报告"
