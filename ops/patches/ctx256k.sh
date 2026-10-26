#!/bin/bash
# ===== 上下文扩容：65K → 256K =====
set -u
BASE="$HOME/dsv41_deploy"; U="$HOME/.config/systemd/user"
LOG="$BASE/logs/ctx256k.txt"
exec > >(tee -a "$LOG") 2>&1
echo "=== ctx256k @ $(date '+%F %T') ==="

# 1) 改单元参数
if grep -q -- '--max-seq-len 65536' "$U/dsv41-r1.service"; then
  sed -i 's/--max-seq-len 65536/--max-seq-len 262144/' "$U/dsv41-r1.service"
  echo "  [OK] max-seq-len 65536 -> 262144"
else
  echo "  [INFO] 未找到 65536（可能已改过），当前值："
  grep -o -- '--max-seq-len [0-9]*' "$U/dsv41-r1.service"
fi
systemctl --user daemon-reload

# 2) 干净重启（先停、等显存释放、再启——避免放置器竞态崩溃循环）
systemctl --user stop dsv41-r1
for i in $(seq 1 24); do
  sleep 5
  M=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0,1,2,3 | sort -rn | head -1)
  [ "$M" -lt 1000 ] && break
done
echo "  [INFO] GPU0-3 残留: ${M}MiB"
systemctl --user start dsv41-r1

# 3) 等就绪
READY=0
for i in $(seq 1 40); do
  sleep 15
  if curl -s --max-time 5 http://127.0.0.1:8011/v1/models >/dev/null 2>&1; then READY=1; break; fi
  systemctl --user is-active dsv41-r1 >/dev/null 2>&1 || true
done
echo "  [INFO] r1 就绪: $READY（$((i*15))s）"
[ "$READY" -ne 1 ] && { echo "VERDICT: FAIL_READY"; exit 1; }

# 4) 短请求冒烟
S=$(curl -s --max-time 120 http://127.0.0.1:8011/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"ping"}],"max_tokens":8}')
echo "$S" | grep -q '"content"' && echo "  [OK] 短请求正常" || { echo "  [FAIL] 短请求异常: $S"; echo "VERDICT: FAIL_SMOKE"; exit 1; }

# 5) 越过旧上限的长上下文实测（~70K token 提示词；旧 65K 配置下会被拒）
python3 - <<'PYEOF'
import random
random.seed(7)
words = ["alpha","beta","gamma","delta","epsilon","zeta","eta","theta","iota","kappa",
         "lambda","mu","nu","xi","omicron","pi","rho","sigma","tau","upsilon"]
with open("/tmp/ctx70k.json","w") as f:
    body = "Summarize in one word. Reply with just: OK\n\n" + " ".join(random.choice(words) for _ in range(70000))
    import json
    json.dump({"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":body}],"max_tokens":16}, f)
print("  [OK] 70K-token 请求体已生成")
PYEOF
echo "  [RUN] 发送 ~70K token 请求（长预填充，最长等 10 分钟）..."
T0=$(date +%s)
R=$(curl -s --max-time 600 http://127.0.0.1:8011/v1/chat/completions -H 'Content-Type: application/json' -d @/tmp/ctx70k.json)
T1=$(date +%s)
echo "$R" | head -c 220; echo
echo "  [INFO] 耗时 $((T1-T0))s"
echo "$R" | grep -q '"content"' && echo "  [PASS] 70K 上下文请求成功（超过旧 65K 上限）" || echo "  [WARN] 长请求未成功（看上方响应）"

nvidia-smi --query-gpu=index,memory.used --format=csv,noheader
echo "VERDICT: DONE"
